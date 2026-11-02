//! `gf-transfer send`: resumable report download from an immutable,
//! private snapshot.
//!
//! Layout of `root/<transfer_id>/`: `lock`, `snapshot` (the private copy)
//! and `snapshot.json` (bound key + length + sha256, written after the copy
//! is durable). A reopen with a matching key always serves the existing
//! snapshot and never re-resolves the source path.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::{Digest, Sha256 as Hasher};

use crate::fsutil::{self, private_transfer_dir, write_atomic, IO_BUF};
use crate::protocol::{
    Direction, Frame, FrameSource, FrameWriter, Limits, Open, Ready, TransferKey, TransferMeta,
};
use crate::{fail_point, Error, ErrorCode, FailPoint, FailPoints, Result};

pub const SNAPSHOT: &str = "snapshot";
pub const SNAPSHOT_META: &str = "snapshot.json";

/// How many directories directly above `--source` must not be symlinks
/// (`/tmp/gf-exec-<id>/reports/<name>`: the exec dir and `reports/`).
pub const SOURCE_NOFOLLOW_PARENTS: usize = 2;

/// Options for [`Snapshot::open_or_create_with`].
#[derive(Clone)]
pub struct SnapshotOptions {
    /// How long to wait for the transfer lock before `busy`. Defaults to the
    /// protocol's default idle timeout (60 s), the documented bound on how
    /// long a replacement waits for a stale helper to let go of the lock.
    pub lock_wait: std::time::Duration,
    pub deadline: Option<std::time::SystemTime>,
    /// Test-only failure injection / source mutation.
    pub hooks: Option<Arc<dyn FailPoints>>,
}

impl Default for SnapshotOptions {
    fn default() -> Self {
        SnapshotOptions {
            lock_wait: Limits::default().idle_timeout,
            deadline: None,
            hooks: None,
        }
    }
}

/// An immutable private snapshot; holds the transfer lock.
pub struct Snapshot {
    dir: PathBuf,
    meta: TransferMeta,
    file: File,
    _lock: File,
}

impl std::fmt::Debug for Snapshot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Snapshot")
            .field("dir", &self.dir)
            .field("meta", &self.meta)
            .finish()
    }
}

fn rejected(msg: &str) -> Error {
    Error::new(ErrorCode::SourceRejected, msg)
}

fn read_meta(dir: &Path) -> Result<Option<TransferMeta>> {
    match fsutil::open_read_nofollow(&dir.join(SNAPSHOT_META)) {
        Ok(f) => {
            let mut buf = Vec::new();
            f.take(64 * 1024)
                .read_to_end(&mut buf)
                .map_err(|e| Error::io("read snapshot meta", e))?;
            serde_json::from_slice(&buf)
                .map(Some)
                .map_err(|_| Error::new(ErrorCode::Internal, "corrupt snapshot meta"))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::io("open snapshot meta", e)),
    }
}

impl Snapshot {
    /// Reuse the snapshot for `key` or create it from `source` (see
    /// [`Snapshot::open_or_create_with`]) with default options: waits up to
    /// the default idle timeout for the transfer lock before `busy`.
    pub fn open_or_create(
        root: &Path,
        key: &TransferKey,
        source: &Path,
        max_bytes: u64,
    ) -> Result<Snapshot> {
        Snapshot::open_or_create_with(root, key, source, max_bytes, &SnapshotOptions::default())
    }

    /// - Existing snapshot with the same key: reuse (source is not touched).
    /// - Existing snapshot with a different key: `metadata_mismatch`.
    /// - Otherwise: open `source` with `O_NOFOLLOW`, require a regular file
    ///   of at most `max_bytes` (`too_large`), copy it while hashing, and
    ///   refuse (`source_rejected`) if its size or mtime changed meanwhile.
    pub fn open_or_create_with(
        root: &Path,
        key: &TransferKey,
        source: &Path,
        max_bytes: u64,
        opts: &SnapshotOptions,
    ) -> Result<Snapshot> {
        key.validate()?;
        if key.direction != Direction::Download {
            return Err(Error::new(
                ErrorCode::Protocol,
                "snapshot requires a download key",
            ));
        }
        let dir = private_transfer_dir(root, &key.transfer_id)?;
        let lock = fsutil::lock_transfer(&dir, opts.lock_wait, opts.deadline)?;
        let snap_path = dir.join(SNAPSHOT);

        if let Some(meta) = read_meta(&dir)? {
            if meta.key() != *key {
                return Err(Error::new(
                    ErrorCode::MetadataMismatch,
                    "transfer id reused with different metadata",
                ));
            }
            let file = fsutil::open_read_nofollow(&snap_path)
                .map_err(|e| Error::io("open snapshot", e))?;
            let len = file
                .metadata()
                .map_err(|e| Error::io("stat snapshot", e))?
                .len();
            if len != meta.length {
                return Err(Error::new(
                    ErrorCode::RestartRequired,
                    "snapshot is damaged",
                ));
            }
            return Ok(Snapshot {
                dir,
                meta,
                file,
                _lock: lock,
            });
        }

        let _ = fs::remove_file(&snap_path);
        let tmp = dir.join(format!("{SNAPSHOT}.tmp"));
        let _ = fs::remove_file(&tmp);
        let created = create_snapshot(source, &tmp, max_bytes, &opts.hooks);
        let (length, sha256) = match created {
            Ok(v) => v,
            Err(e) => {
                let _ = fs::remove_file(&tmp);
                return Err(e);
            }
        };
        fs::rename(&tmp, &snap_path).map_err(|e| Error::io("publish snapshot", e))?;
        fsutil::fsync_dir(&dir).map_err(|e| Error::io("sync snapshot dir", e))?;
        let meta = key.with_content(length, sha256);
        write_atomic(
            &dir,
            SNAPSHOT_META,
            &serde_json::to_vec(&meta).expect("json"),
            &None,
        )
        .map_err(|e| Error::io("write snapshot meta", e.into()))?;
        let file =
            fsutil::open_read_nofollow(&snap_path).map_err(|e| Error::io("open snapshot", e))?;
        Ok(Snapshot {
            dir,
            meta,
            file,
            _lock: lock,
        })
    }

    pub fn meta(&self) -> &TransferMeta {
        &self.meta
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(SNAPSHOT)
    }

    fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; len];
        self.file
            .read_exact_at(&mut buf, offset)
            .map_err(|e| Error::io("read snapshot", e))?;
        Ok(buf)
    }
}

fn create_snapshot(
    source: &Path,
    tmp: &Path,
    max_bytes: u64,
    hooks: &Option<Arc<dyn FailPoints>>,
) -> Result<(u64, [u8; 32])> {
    // O_NONBLOCK keeps a FIFO from blocking the open; it has no effect on
    // regular files.
    // The source and the two directories above it (the exec dir and its
    // `reports/`) are opened without following symlinks.
    let mut src =
        fsutil::open_read_beneath_nofollow(source, SOURCE_NOFOLLOW_PARENTS, libc::O_NONBLOCK)
            .map_err(|e| match e.raw_os_error() {
                Some(libc::ELOOP) => rejected("source path contains a symlink"),
                Some(libc::ENOTDIR) => rejected("source parent is not a directory"),
                Some(libc::EINVAL) => rejected("source path is not a plain path"),
                Some(libc::ENOENT) => rejected("source is missing"),
                _ => Error::io_as(ErrorCode::SourceRejected, "open source", e),
            })?;
    let before = src.metadata().map_err(|e| Error::io("stat source", e))?;
    if !before.file_type().is_file() {
        return Err(rejected("source is not a regular file"));
    }
    if before.len() > max_bytes {
        return Err(Error::new(ErrorCode::TooLarge, "source exceeds max bytes"));
    }
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(tmp)
        .map_err(|e| Error::io("create snapshot", e))?;
    let mut hasher = Hasher::new();
    let mut buf = vec![0u8; IO_BUF];
    let mut total: u64 = 0;
    loop {
        let n = match src.read(&mut buf) {
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(Error::io("read source", e)),
        };
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > before.len() || total > max_bytes {
            return Err(rejected("source changed during snapshot"));
        }
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n])
            .map_err(|e| Error::io("write snapshot", e))?;
    }
    fail_point(hooks, FailPoint::SnapshotAfterCopy).map_err(|e| Error::io("snapshot", e))?;
    let after = src.metadata().map_err(|e| Error::io("stat source", e))?;
    if total != before.len()
        || after.len() != before.len()
        || after.mtime() != before.mtime()
        || after.mtime_nsec() != before.mtime_nsec()
        || after.ino() != before.ino()
    {
        return Err(rejected("source changed during snapshot"));
    }
    out.sync_all().map_err(|e| Error::io("sync snapshot", e))?;
    Ok((total, hasher.finalize().into()))
}

#[derive(Clone)]
pub struct SendConfig {
    pub state_dir: PathBuf,
    /// Server-authorized source file; the open's `artifact` must equal its
    /// basename.
    pub source: PathBuf,
    /// `max_bytes` is the report cap (33,554,432 for reports).
    pub limits: Limits,
    pub hooks: Option<Arc<dyn FailPoints>>,
}

fn unexpected(frame: &Frame) -> Error {
    Error::new(
        ErrorCode::Protocol,
        format!("unexpected {} frame", frame.type_name()),
    )
}

fn finish_with_error<W: Write>(writer: &mut FrameWriter<W>, result: Result<()>) -> Result<()> {
    if let Err(e) = &result {
        if e.reply {
            let _ = writer.write_frame(&Frame::error(e));
        }
    }
    result
}

fn recv_open(source: &mut FrameSource) -> Result<Open> {
    match source.recv()? {
        Frame::Open(o) if o.direction == Direction::Download => Ok(o),
        Frame::Open(_) => Err(Error::new(
            ErrorCode::Protocol,
            "send requires a download open",
        )),
        other => Err(unexpected(&other)),
    }
}

/// Full CLI flow: wait for a download open whose artifact is the source's
/// basename, create or reuse the snapshot, then serve it.
pub fn serve<R, W>(input: R, output: W, config: SendConfig) -> Result<()>
where
    R: Read + Send + 'static,
    W: Write,
{
    let mut writer = FrameWriter::new(output);
    let result = (|| {
        config.limits.validate()?;
        let mut source = FrameSource::spawn(input, &config.limits);
        let open = recv_open(&mut source)?;
        let basename = config
            .source
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| rejected("source has no usable file name"))?;
        if open.artifact != basename {
            return Err(rejected(
                "open artifact does not match the authorized source",
            ));
        }
        let snapshot = Snapshot::open_or_create_with(
            &config.state_dir,
            &open.key(),
            &config.source,
            config.limits.max_bytes,
            &SnapshotOptions {
                lock_wait: config.limits.idle_timeout,
                deadline: config.limits.deadline,
                hooks: config.hooks.clone(),
            },
        )?;
        send_loop(&mut source, &mut writer, &snapshot, &open, &config.limits)
    })();
    finish_with_error(&mut writer, result)
}

/// Serve an existing snapshot. `input` must start with the download `open`
/// (whose key must match the snapshot), followed by the receiver's `ready`
/// and acknowledgements.
pub fn run_send<R, W>(input: R, output: W, snapshot: Snapshot, limits: Limits) -> Result<()>
where
    R: Read + Send + 'static,
    W: Write,
{
    let mut writer = FrameWriter::new(output);
    let result = (|| {
        limits.validate()?;
        let mut source = FrameSource::spawn(input, &limits);
        let open = recv_open(&mut source)?;
        if open.key() != snapshot.meta.key() {
            return Err(Error::new(
                ErrorCode::MetadataMismatch,
                "open does not match the snapshot",
            ));
        }
        send_loop(&mut source, &mut writer, &snapshot, &open, &limits)
    })();
    finish_with_error(&mut writer, result)
}

fn send_loop<W: Write>(
    source: &mut FrameSource,
    writer: &mut FrameWriter<W>,
    snapshot: &Snapshot,
    open: &Open,
    limits: &Limits,
) -> Result<()> {
    let meta = &snapshot.meta;
    let tid = meta.transfer_id.clone();
    let negotiated = limits.negotiate(open.max_payload)?;
    writer.write_frame(&Frame::Ready(Ready {
        transfer_id: tid.clone(),
        committed_offset: None,
        length: Some(meta.length),
        sha256: Some(meta.sha256),
        max_payload: negotiated,
        completed: None,
    }))?;
    let ready = match source.recv()? {
        Frame::Ready(r) if r.transfer_id == tid => r,
        other => return Err(unexpected(&other)),
    };
    let mut offset = ready
        .committed_offset
        .ok_or_else(|| Error::new(ErrorCode::Protocol, "receiver ready lacks committed_offset"))?;
    if offset > meta.length {
        return Err(Error::new(
            ErrorCode::BadOffset,
            "receiver offset beyond snapshot length",
        ));
    }
    let chunk_max = negotiated.min(ready.max_payload);
    writer.set_max_payload(chunk_max);
    while offset < meta.length {
        let n = (meta.length - offset).min(chunk_max) as usize;
        let data = snapshot.read_at(offset, n)?;
        writer.write_frame(&Frame::chunk(&tid, offset, data))?;
        let next = offset + n as u64;
        match source.recv()? {
            Frame::Ack {
                transfer_id,
                committed_offset,
            } if transfer_id == tid => {
                if committed_offset != next {
                    return Err(Error::new(
                        ErrorCode::BadOffset,
                        format!("ack {committed_offset} does not match {next}"),
                    ));
                }
            }
            other => return Err(unexpected(&other)),
        }
        offset = next;
    }
    writer.write_frame(&Frame::Finish {
        transfer_id: tid.clone(),
        length: meta.length,
        sha256: meta.sha256,
    })?;
    match source.recv()? {
        Frame::Complete {
            transfer_id,
            length,
            sha256,
            ..
        } if transfer_id == tid => {
            if length != meta.length || sha256 != meta.sha256 {
                return Err(Error::new(
                    ErrorCode::MetadataMismatch,
                    "complete metadata differs from snapshot",
                ));
            }
            Ok(())
        }
        other => Err(unexpected(&other)),
    }
}
