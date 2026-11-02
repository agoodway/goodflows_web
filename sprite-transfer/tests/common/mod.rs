#![allow(dead_code)]

use std::io::{self, Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gf_transfer::fsutil::sha256;
use gf_transfer::protocol::{
    encode, Direction, Frame, FrameReader, Limits, Open, TransferKey, TransferMeta, MAX_PAYLOAD,
};
use gf_transfer::{FailPoint, FailPoints};

pub const BIN: &str = env!("CARGO_BIN_EXE_gf-transfer");

/// Unique scratch directory under the target dir (removed on drop).
pub struct TempDir(pub PathBuf);

impl TempDir {
    pub fn new(name: &str) -> TempDir {
        static N: AtomicUsize = AtomicUsize::new(0);
        let base = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
        let p = base.join(format!(
            "{name}-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    pub fn join(&self, p: &str) -> PathBuf {
        self.0.join(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Deterministic pseudo-random bytes (xorshift64*).
pub fn random_bytes(len: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    let mut out = Vec::with_capacity(len + 8);
    while out.len() < len {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        out.extend_from_slice(&s.wrapping_mul(0x2545_F491_4F6C_DD1D).to_le_bytes());
    }
    out.truncate(len);
    out
}

pub fn upload_meta(id: &str, data: &[u8]) -> TransferMeta {
    TransferMeta {
        transfer_id: id.to_string(),
        direction: Direction::Upload,
        session_id: "s-1".into(),
        member_id: "m-1".into(),
        lease_generation: 3,
        artifact: "workspace.tar.gz".into(),
        length: data.len() as u64,
        sha256: sha256(data),
    }
}

pub fn download_key(id: &str, artifact: &str) -> TransferKey {
    TransferKey {
        transfer_id: id.to_string(),
        direction: Direction::Download,
        session_id: "s-1".into(),
        member_id: "m-1".into(),
        lease_generation: 3,
        artifact: artifact.to_string(),
    }
}

pub fn limits(max_payload: u64) -> Limits {
    Limits {
        max_payload,
        max_bytes: 64 * 1024 * 1024,
        idle_timeout: Duration::from_millis(200),
        deadline: None,
    }
}

pub fn deadline_ms(from_now: Duration) -> u64 {
    (SystemTime::now() + from_now)
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

pub fn frame_bytes(frames: &[Frame]) -> Vec<u8> {
    let mut out = Vec::new();
    for f in frames {
        out.extend(encode(f, MAX_PAYLOAD).unwrap());
    }
    out
}

pub fn decode_all(bytes: &[u8]) -> Vec<Frame> {
    let mut r = FrameReader::with_max_payload(Cursor::new(bytes.to_vec()), MAX_PAYLOAD);
    let mut out = Vec::new();
    while let Some(f) = r.read_frame().unwrap() {
        out.push(f);
    }
    out
}

/// open + chunks (of `chunk` bytes) + optional finish for an upload.
pub fn upload_frames(
    meta: &TransferMeta,
    data: &[u8],
    chunk: usize,
    from: usize,
    finish: bool,
) -> Vec<Frame> {
    let mut frames = vec![Frame::Open(Open::upload(meta, MAX_PAYLOAD))];
    let mut off = from;
    while off < data.len() {
        let end = (off + chunk).min(data.len());
        frames.push(Frame::chunk(
            &meta.transfer_id,
            off as u64,
            data[off..end].to_vec(),
        ));
        off = end;
    }
    if finish {
        frames.push(Frame::Finish {
            transfer_id: meta.transfer_id.clone(),
            length: meta.length,
            sha256: meta.sha256,
        });
    }
    frames
}

/// Fails the `nth` (0-based) time `point` is reached, once.
pub struct FailAt {
    pub point: FailPoint,
    pub nth: usize,
    pub errno: Option<i32>,
    hits: AtomicUsize,
    fired: AtomicBool,
}

impl FailAt {
    pub fn new(point: FailPoint, nth: usize) -> Arc<FailAt> {
        Arc::new(FailAt {
            point,
            nth,
            errno: None,
            hits: AtomicUsize::new(0),
            fired: AtomicBool::new(false),
        })
    }

    pub fn enospc(point: FailPoint, nth: usize) -> Arc<FailAt> {
        Arc::new(FailAt {
            point,
            nth,
            errno: Some(libc::ENOSPC),
            hits: AtomicUsize::new(0),
            fired: AtomicBool::new(false),
        })
    }

    pub fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }
}

impl FailPoints for FailAt {
    fn check(&self, point: FailPoint) -> io::Result<()> {
        if point != self.point || self.fired.load(Ordering::SeqCst) {
            return Ok(());
        }
        if self.hits.fetch_add(1, Ordering::SeqCst) == self.nth {
            self.fired.store(true, Ordering::SeqCst);
            return Err(match self.errno {
                Some(e) => io::Error::from_raw_os_error(e),
                None => io::Error::other("injected crash"),
            });
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- tar helpers

/// Raw tar entry builder that bypasses the tar crate's path sanitizing, so
/// tests can construct hostile archives.
pub struct RawTar {
    builder: tar::Builder<Vec<u8>>,
}

impl Default for RawTar {
    fn default() -> Self {
        Self::new()
    }
}

impl RawTar {
    pub fn new() -> RawTar {
        RawTar {
            builder: tar::Builder::new(Vec::new()),
        }
    }

    pub fn entry(&mut self, name: &str, ty: tar::EntryType, link: &str, data: &[u8]) -> &mut Self {
        let mut h = tar::Header::new_gnu();
        {
            let old = h.as_old_mut();
            old.name[..name.len()].copy_from_slice(name.as_bytes());
            old.linkname[..link.len()].copy_from_slice(link.as_bytes());
        }
        h.set_entry_type(ty);
        h.set_mode(if ty == tar::EntryType::Directory {
            0o755
        } else {
            0o644
        });
        h.set_size(data.len() as u64);
        h.set_mtime(1_700_000_000);
        h.set_cksum();
        self.builder.append(&h, data).unwrap();
        self
    }

    pub fn file(&mut self, name: &str, data: &[u8]) -> &mut Self {
        self.entry(name, tar::EntryType::Regular, "", data)
    }

    pub fn dir(&mut self, name: &str) -> &mut Self {
        self.entry(name, tar::EntryType::Directory, "", b"")
    }

    pub fn symlink(&mut self, name: &str, target: &str) -> &mut Self {
        self.entry(name, tar::EntryType::Symlink, target, b"")
    }

    pub fn hardlink(&mut self, name: &str, target: &str) -> &mut Self {
        self.entry(name, tar::EntryType::Link, target, b"")
    }

    /// Long path via the tar crate's own (GNU long name) support.
    pub fn long_file(&mut self, path: &str, data: &[u8]) -> &mut Self {
        let mut h = tar::Header::new_gnu();
        h.set_size(data.len() as u64);
        h.set_mode(0o644);
        self.builder.append_data(&mut h, path, data).unwrap();
        self
    }

    pub fn tar(&mut self) -> Vec<u8> {
        let b = std::mem::replace(&mut self.builder, tar::Builder::new(Vec::new()));
        b.into_inner().unwrap()
    }

    pub fn gz(&mut self) -> Vec<u8> {
        gzip(&self.tar())
    }
}

pub fn gzip(data: &[u8]) -> Vec<u8> {
    let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

/// Files/dirs under `dir` (relative paths, sorted), not following links.
pub fn tree(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        for e in rd {
            let e = e.unwrap();
            let p = e.path();
            out.push(p.strip_prefix(base).unwrap().to_string_lossy().into_owned());
            if e.file_type().unwrap().is_dir() {
                walk(base, &p, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

pub fn mkfifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}
