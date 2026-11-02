//! Small filesystem helpers: no-follow opens, atomic replace with fsync,
//! private directories and `flock` ownership.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use sha2::{Digest, Sha256};

use crate::{fail_point, Error, ErrorCode, FailPoint, FailPoints, Result};

/// Bounded read size for hashing/copying.
pub const IO_BUF: usize = 64 * 1024;

/// Validate an identifier that may be used as a single path component:
/// `^[A-Za-z0-9._-]{1,128}$`, excluding `.` and `..`.
pub fn validate_id(field: &str, value: &str) -> Result<()> {
    if is_valid_id(value) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorCode::Protocol,
            format!("invalid {field}: must match [A-Za-z0-9._-]{{1,128}}"),
        ))
    }
}

/// True when `value` matches `^[A-Za-z0-9._-]{1,128}$` and is not `.`/`..`.
pub fn is_valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

/// Open an existing file read-only without following a final symlink.
pub fn open_read_nofollow(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

/// Open an existing file read-only so that neither its final component nor
/// the `nofollow_parents` directories directly above it may be symlinks.
///
/// The ancestors above those directories are opened normally (they are
/// server-owned, e.g. `/tmp`); each of the last `nofollow_parents`
/// directories is opened with `openat(O_DIRECTORY | O_NOFOLLOW)` relative to
/// the previous descriptor, and the file with `openat(O_NOFOLLOW | flags)`.
/// A symlinked component fails with `ELOOP`, a non-directory with
/// `ENOTDIR`, and a `.`/`..`/root component in the checked part with
/// `EINVAL`.
pub fn open_read_beneath_nofollow(
    path: &Path,
    nofollow_parents: usize,
    flags: libc::c_int,
) -> io::Result<File> {
    use std::ffi::CString;
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Component;

    let invalid = || io::Error::from_raw_os_error(libc::EINVAL);
    let name = match path.components().next_back() {
        Some(Component::Normal(n)) => n,
        _ => return Err(invalid()),
    };
    let parent = path.parent().ok_or_else(invalid)?;
    let parts: Vec<Component> = parent.components().collect();
    let split = parts.len().saturating_sub(nofollow_parents);
    let (base, checked) = parts.split_at(split);
    let base: PathBuf = if base.is_empty() {
        PathBuf::from(".")
    } else {
        base.iter().collect()
    };
    let cstr = |b: &[u8]| CString::new(b).map_err(|_| invalid());

    let openat = |dir: libc::c_int, name: &[u8], flags: libc::c_int| -> io::Result<OwnedFd> {
        let c = cstr(name)?;
        loop {
            // SAFETY: valid NUL-terminated path; `dir` is an open descriptor
            // or AT_FDCWD.
            let fd = unsafe { libc::openat(dir, c.as_ptr(), flags | libc::O_CLOEXEC) };
            if fd >= 0 {
                // SAFETY: freshly opened descriptor we exclusively own.
                return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
            }
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EINTR) {
                return Err(err);
            }
        }
    };

    let mut dir = openat(
        libc::AT_FDCWD,
        base.as_os_str().as_bytes(),
        libc::O_RDONLY | libc::O_DIRECTORY,
    )?;
    for c in checked {
        let Component::Normal(n) = c else {
            return Err(invalid());
        };
        dir = openat(
            dir.as_raw_fd(),
            n.as_bytes(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )?;
    }
    let fd = openat(
        dir.as_raw_fd(),
        name.as_bytes(),
        libc::O_RDONLY | libc::O_NOFOLLOW | flags,
    )?;
    Ok(File::from(fd))
}

/// Open (creating if needed) a file read-write without following symlinks.
pub fn open_rw_nofollow(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

/// fsync a directory so renames/creates inside it are durable.
pub fn fsync_dir(dir: &Path) -> io::Result<()> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(dir)?;
    f.sync_all()
}

/// Why [`write_atomic`] failed, split at the rename: before it the old
/// contents of `dir/name` are intact; after it the new contents are in place
/// (only the directory fsync failed), so callers must treat them as current.
#[derive(Debug)]
pub enum AtomicWriteError {
    BeforeRename(io::Error),
    AfterRename(io::Error),
}

impl AtomicWriteError {
    /// Whether the new contents replaced `dir/name`.
    pub fn renamed(&self) -> bool {
        matches!(self, AtomicWriteError::AfterRename(_))
    }
}

impl From<AtomicWriteError> for io::Error {
    fn from(e: AtomicWriteError) -> io::Error {
        match e {
            AtomicWriteError::BeforeRename(e) | AtomicWriteError::AfterRename(e) => e,
        }
    }
}

/// Atomically replace `dir/name` with `bytes`: write `name.tmp`, fsync,
/// rename, fsync the directory. The error says whether the rename happened.
pub fn write_atomic(
    dir: &Path,
    name: &str,
    bytes: &[u8],
    hooks: &Option<Arc<dyn FailPoints>>,
) -> std::result::Result<(), AtomicWriteError> {
    let before = (|| -> io::Result<()> {
        let tmp = dir.join(format!("{name}.tmp"));
        let _ = fs::remove_file(&tmp);
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        fail_point(hooks, FailPoint::AfterSidecarTemp)?;
        fs::rename(&tmp, dir.join(name))
    })();
    before.map_err(AtomicWriteError::BeforeRename)?;
    fail_point(hooks, FailPoint::AfterSidecarRename)
        .and_then(|()| fsync_dir(dir))
        .map_err(AtomicWriteError::AfterRename)
}

/// Create `root` (if missing) and the private per-transfer directory
/// `root/<transfer_id>` with mode 0700. Refuses symlinked transfer dirs.
pub fn private_transfer_dir(root: &Path, transfer_id: &str) -> Result<PathBuf> {
    validate_id("transfer_id", transfer_id)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)
        .map_err(|e| Error::io("create state dir", e))?;
    let dir = root.join(transfer_id);
    match fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(Error::io("create transfer dir", e)),
    }
    let md = fs::symlink_metadata(&dir).map_err(|e| Error::io("stat transfer dir", e))?;
    if !md.file_type().is_dir() {
        return Err(Error::new(
            ErrorCode::Internal,
            "transfer state path is not a directory",
        ));
    }
    Ok(dir)
}

/// Time left before `deadline` (zero if passed); `None` without a deadline.
pub fn remaining(deadline: Option<SystemTime>) -> Option<Duration> {
    deadline.map(|d| {
        d.duration_since(SystemTime::now())
            .unwrap_or(Duration::ZERO)
    })
}

/// Acquire an exclusive `flock` on `dir/lock`, retrying for up to `wait`
/// (bounded by `deadline`). The lock is released when the returned file is
/// closed, including on process exit.
pub fn lock_transfer(dir: &Path, wait: Duration, deadline: Option<SystemTime>) -> Result<File> {
    let file = open_rw_nofollow(&dir.join("lock")).map_err(|e| Error::io("open lock", e))?;
    let started = Instant::now();
    let wait = match remaining(deadline) {
        Some(r) => wait.min(r),
        None => wait,
    };
    loop {
        // SAFETY: flock on a valid, owned descriptor.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return Ok(file);
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EWOULDBLOCK) => {}
            Some(libc::EINTR) => continue,
            _ => return Err(Error::io("lock transfer", err)),
        }
        let elapsed = started.elapsed();
        if elapsed >= wait {
            return Err(Error::new(
                ErrorCode::Busy,
                "transfer is owned by another invocation",
            ));
        }
        thread::sleep((wait - elapsed).min(Duration::from_millis(25)));
    }
}

/// SHA-256 of the first `len` bytes of `file` (from offset 0), using bounded
/// reads. Fails if the file is shorter than `len`.
pub fn hash_prefix(file: &mut File, len: u64) -> io::Result<[u8; 32]> {
    use std::io::{Seek, SeekFrom};
    file.seek(SeekFrom::Start(0))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; IO_BUF];
    let mut left = len;
    while left > 0 {
        let want = left.min(IO_BUF as u64) as usize;
        let n = file.read(&mut buf[..want])?;
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "file shorter than expected",
            ));
        }
        hasher.update(&buf[..n]);
        left -= n as u64;
    }
    Ok(hasher.finalize().into())
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// Remove a path whether it is a file, symlink or directory tree.
/// Missing paths are fine.
pub fn remove_any(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(md) if md.file_type().is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
