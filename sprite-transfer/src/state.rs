//! Durable, resumable receiving state.
//!
//! Layout of `root/<transfer_id>/`:
//!
//! - `lock`        — `flock`ed for the owner's lifetime.
//! - `state.json`  — sidecar: immutable meta, `committed_offset`, `state`.
//!   Always replaced atomically (temp + fsync + rename + dir fsync).
//! - `data.part`   — partial bytes; anything past `committed_offset` is
//!   truncated on reopen.
//! - `artifact`    — the verified, published file (renamed from `data.part`).
//!
//! Per chunk: verify sha256 and offset → write → fsync data → replace sidecar
//! → ack. An acknowledged offset therefore never exceeds durable data.

use std::fs::{self, File};
use std::io::{self, ErrorKind};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::fsutil::{self, hash_prefix, private_transfer_dir, write_atomic};
use crate::protocol::{Limits, Sha256, TransferMeta};
use crate::{fail_point, Error, ErrorCode, FailPoint, FailPoints, Result};

pub const SIDECAR: &str = "state.json";
pub const PART: &str = "data.part";
pub const ARTIFACT: &str = "artifact";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiveState {
    /// Accepting chunks.
    Receiving,
    /// Verified and atomically published at `artifact`.
    Published,
    /// Extraction started; its outcome is uncertain after a crash.
    Extracting,
    /// Extraction completed successfully.
    Extracted,
    /// Extraction failed; the destination must be quarantined/reset.
    ExtractFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Sidecar {
    meta: TransferMeta,
    committed_offset: u64,
    state: ReceiveState,
}

/// A verified, published artifact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletedArtifact {
    pub path: PathBuf,
    pub length: u64,
    pub sha256: Sha256,
}

/// Owner of one transfer's receiving state.
pub struct Receiver {
    dir: PathBuf,
    sidecar: Sidecar,
    part: Option<File>,
    limits: Limits,
    hooks: Option<Arc<dyn FailPoints>>,
    poisoned: bool,
    _lock: File,
}

impl std::fmt::Debug for Receiver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Receiver")
            .field("dir", &self.dir)
            .field("committed_offset", &self.sidecar.committed_offset)
            .field("state", &self.sidecar.state)
            .finish()
    }
}

fn read_sidecar(dir: &Path) -> Result<Option<Sidecar>> {
    let path = dir.join(SIDECAR);
    let bytes = match fsutil::open_read_nofollow(&path) {
        Ok(mut f) => {
            let mut buf = Vec::new();
            io::Read::read_to_end(&mut io::Read::take(&mut f, 64 * 1024), &mut buf)
                .map_err(|e| Error::io("read sidecar", e))?;
            buf
        }
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::io("open sidecar", e)),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| Error::new(ErrorCode::Internal, "corrupt transfer sidecar"))
}

impl Receiver {
    /// Open or resume `root/<meta.transfer_id>`. See [`Receiver::open_with_hooks`].
    pub fn open(root: &Path, meta: &TransferMeta, limits: &Limits) -> Result<Receiver> {
        Receiver::open_with_hooks(root, meta, limits, None)
    }

    /// Open or resume a transfer:
    /// - lock it (waiting up to `limits.idle_timeout`, else `busy`);
    /// - refuse different metadata for an existing id (`metadata_mismatch`,
    ///   state untouched);
    /// - truncate the part file to the committed offset;
    /// - reconcile a publish that crashed before its sidecar update.
    pub fn open_with_hooks(
        root: &Path,
        meta: &TransferMeta,
        limits: &Limits,
        hooks: Option<Arc<dyn FailPoints>>,
    ) -> Result<Receiver> {
        meta.validate()?;
        limits.validate()?;
        if meta.length > limits.max_bytes {
            return Err(Error::new(
                ErrorCode::TooLarge,
                "transfer length exceeds max bytes",
            ));
        }
        let dir = private_transfer_dir(root, &meta.transfer_id)?;
        let lock = fsutil::lock_transfer(&dir, limits.idle_timeout, limits.deadline)?;

        let sidecar = match read_sidecar(&dir)? {
            Some(sc) => {
                if sc.meta != *meta {
                    return Err(Error::new(
                        ErrorCode::MetadataMismatch,
                        "transfer id reused with different metadata",
                    ));
                }
                sc
            }
            None => {
                // Fresh (or crashed before the first sidecar): discard strays.
                for name in [PART, ARTIFACT] {
                    fsutil::remove_any(&dir.join(name))
                        .map_err(|e| Error::io("remove stale state", e))?;
                }
                let sc = Sidecar {
                    meta: meta.clone(),
                    committed_offset: 0,
                    state: ReceiveState::Receiving,
                };
                write_atomic(
                    &dir,
                    SIDECAR,
                    &serde_json::to_vec(&sc).expect("json"),
                    &None,
                )
                .map_err(|e| Error::io("write sidecar", e.into()))?;
                sc
            }
        };

        let mut rx = Receiver {
            dir,
            sidecar,
            part: None,
            limits: limits.clone(),
            hooks,
            poisoned: false,
            _lock: lock,
        };
        rx.recover()?;
        Ok(rx)
    }

    fn recover(&mut self) -> Result<()> {
        if self.sidecar.state != ReceiveState::Receiving {
            if !self.artifact_path().exists() {
                self.invalidate();
                return Err(Error::new(
                    ErrorCode::RestartRequired,
                    "published artifact is missing",
                ));
            }
            return Ok(());
        }
        let part_path = self.dir.join(PART);
        let committed = self.sidecar.committed_offset;
        let part_exists = fs::symlink_metadata(&part_path).is_ok();
        if !part_exists && committed == self.sidecar.meta.length && committed > 0 {
            // Crash between publish rename and the sidecar update?
            if let Ok(mut f) = fsutil::open_read_nofollow(&self.artifact_path()) {
                let len = f
                    .metadata()
                    .map_err(|e| Error::io("stat artifact", e))?
                    .len();
                let ok = len == self.sidecar.meta.length
                    && hash_prefix(&mut f, len).map_err(|e| Error::io("hash artifact", e))?
                        == self.sidecar.meta.sha256;
                if ok {
                    self.set_state(ReceiveState::Published)?;
                    return Ok(());
                }
            }
        }
        let _ = fs::remove_file(self.artifact_path());
        let part = fsutil::open_rw_nofollow(&part_path).map_err(|e| Error::io("open part", e))?;
        let len = part
            .metadata()
            .map_err(|e| Error::io("stat part", e))?
            .len();
        if len < committed {
            self.invalidate();
            return Err(Error::new(
                ErrorCode::RestartRequired,
                "partial data shorter than committed offset",
            ));
        }
        if len > committed {
            part.set_len(committed)
                .map_err(|e| Error::io("truncate part", e))?;
            part.sync_all().map_err(|e| Error::io("sync part", e))?;
        }
        self.part = Some(part);
        Ok(())
    }

    pub fn meta(&self) -> &TransferMeta {
        &self.sidecar.meta
    }

    pub fn committed_offset(&self) -> u64 {
        self.sidecar.committed_offset
    }

    pub fn state(&self) -> ReceiveState {
        self.sidecar.state
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn part_path(&self) -> PathBuf {
        self.dir.join(PART)
    }

    pub fn artifact_path(&self) -> PathBuf {
        self.dir.join(ARTIFACT)
    }

    fn check_usable(&self) -> Result<()> {
        if self.poisoned {
            return Err(Error::new(
                ErrorCode::Internal,
                "receiver failed earlier; reopen to resume",
            ));
        }
        Ok(())
    }

    fn persist(&self, sc: &Sidecar) -> std::result::Result<(), fsutil::AtomicWriteError> {
        write_atomic(
            &self.dir,
            SIDECAR,
            &serde_json::to_vec(sc).expect("json"),
            &self.hooks,
        )
    }

    /// Durably record a new lifecycle state.
    pub fn set_state(&mut self, state: ReceiveState) -> Result<()> {
        let sc = Sidecar {
            state,
            ..self.sidecar.clone()
        };
        self.persist(&sc).map_err(|e| {
            self.poisoned = true;
            Error::io("write sidecar", e.into())
        })?;
        self.sidecar = sc;
        Ok(())
    }

    /// Verify and durably commit one chunk; returns the new committed offset
    /// (the value to acknowledge).
    pub fn commit_chunk(&mut self, offset: u64, data: &[u8], sha256: &Sha256) -> Result<u64> {
        self.check_usable()?;
        if self.sidecar.state != ReceiveState::Receiving {
            return Err(Error::new(ErrorCode::Protocol, "transfer already finished"));
        }
        if data.is_empty() {
            return Err(Error::new(ErrorCode::Protocol, "empty chunk"));
        }
        if data.len() as u64 > self.limits.max_payload {
            return Err(Error::new(ErrorCode::TooLarge, "chunk exceeds max_payload"));
        }
        let committed = self.sidecar.committed_offset;
        if offset != committed {
            return Err(Error::new(
                ErrorCode::BadOffset,
                format!("expected offset {committed}, got {offset}"),
            ));
        }
        let end = offset
            .checked_add(data.len() as u64)
            .ok_or_else(|| Error::new(ErrorCode::BadOffset, "offset + len overflows"))?;
        if end > self.sidecar.meta.length {
            return Err(Error::new(
                ErrorCode::BadOffset,
                "chunk extends past declared length",
            ));
        }
        if fsutil::sha256(data) != *sha256 {
            return Err(Error::new(ErrorCode::BadChunk, "chunk sha256 mismatch"));
        }

        // Whether the new sidecar (recording `end`) replaced the old one: once
        // it has, the bytes up to `end` are committed on disk even if the
        // directory fsync then fails, and must not be truncated.
        let mut recorded = false;
        let result = (|| -> io::Result<()> {
            let part = self.part.as_ref().expect("part open while receiving");
            fail_point(&self.hooks, FailPoint::BeforeDataWrite)?;
            part.write_all_at(data, offset)?;
            fail_point(&self.hooks, FailPoint::AfterDataWrite)?;
            part.sync_data()?;
            fail_point(&self.hooks, FailPoint::AfterDataSync)?;
            let sc = Sidecar {
                committed_offset: end,
                ..self.sidecar.clone()
            };
            if let Err(e) = self.persist(&sc) {
                recorded = e.renamed();
                return Err(e.into());
            }
            self.sidecar = sc;
            fail_point(&self.hooks, FailPoint::AfterSidecarCommit)
        })();
        if let Err(e) = result {
            if !recorded && self.sidecar.committed_offset == committed {
                // Best effort: drop bytes past the durable boundary now.
                if let Some(p) = &self.part {
                    let _ = p.set_len(committed);
                }
            }
            self.poisoned = true;
            return Err(Error::io("commit chunk", e));
        }
        Ok(end)
    }

    /// Verify total length and SHA-256 and atomically publish. Idempotent
    /// once published. A hash mismatch deletes the partial state and fails
    /// with `restart_required`.
    pub fn finish(&mut self) -> Result<CompletedArtifact> {
        self.check_usable()?;
        let meta = self.sidecar.meta.clone();
        let done = CompletedArtifact {
            path: self.artifact_path(),
            length: meta.length,
            sha256: meta.sha256,
        };
        if self.sidecar.state != ReceiveState::Receiving {
            return Ok(done);
        }
        if self.sidecar.committed_offset != meta.length {
            return Err(Error::new(
                ErrorCode::BadOffset,
                format!(
                    "finish before all bytes committed ({} of {})",
                    self.sidecar.committed_offset, meta.length
                ),
            ));
        }
        let mut part = self.part.take().expect("part open while receiving");
        let actual_len = part
            .metadata()
            .map_err(|e| Error::io("stat part", e))?
            .len();
        let digest = hash_prefix(&mut part, meta.length);
        drop(part);
        match digest {
            Ok(d) if d == meta.sha256 && actual_len == meta.length => {}
            Err(e) if e.kind() != ErrorKind::UnexpectedEof => {
                self.poisoned = true;
                return Err(Error::io("hash part", e));
            }
            _ => {
                self.invalidate();
                return Err(Error::new(
                    ErrorCode::RestartRequired,
                    "complete sha256 mismatch; partial transfer discarded",
                ));
            }
        }
        let publish = (|| -> io::Result<()> {
            fs::rename(self.part_path(), self.artifact_path())?;
            fsutil::fsync_dir(&self.dir)?;
            fail_point(&self.hooks, FailPoint::AfterPublishRename)?;
            let sc = Sidecar {
                state: ReceiveState::Published,
                ..self.sidecar.clone()
            };
            self.persist(&sc)?;
            self.sidecar = sc;
            fail_point(&self.hooks, FailPoint::AfterPublishRecord)
        })();
        if let Err(e) = publish {
            self.poisoned = true;
            return Err(Error::io("publish", e));
        }
        Ok(done)
    }

    /// Delete partial/published data and the sidecar (the lock file stays
    /// so a concurrent waiter does not lock a different inode).
    fn invalidate(&mut self) {
        self.part = None;
        self.poisoned = true;
        for name in [SIDECAR, PART, ARTIFACT] {
            let _ = fs::remove_file(self.dir.join(name));
        }
        let _ = fsutil::fsync_dir(&self.dir);
    }
}
