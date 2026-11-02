//! Confined tar / tar.gz validation and extraction.
//!
//! Two passes over the (already checksum-verified, on-disk) archive:
//!
//! 1. Validate all metadata without writing anything: path normalization
//!    (no absolute paths, no `..`), allowed types (regular, dir, symlink,
//!    hardlink), no entry beneath a symlink or file, no duplicate
//!    non-directory paths (so a directory can never be swapped for a link),
//!    hardlinks only to earlier regular files, every symlink's target
//!    resolved through the final set of archive symlinks must stay inside
//!    the destination, expanded bytes / entry count / wall clock bounded.
//! 2. Extract with `openat`-family calls relative to the destination
//!    directory descriptor, opening every parent with `O_NOFOLLOW`, so
//!    preexisting symlinks in the destination are never followed.

use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tar::{EntryType, PaxExtensions};

use crate::fsutil::{self, IO_BUF};
use crate::{fail_point, Error, ErrorCode, FailPoint, FailPoints, Result};

const MAX_LONG_NAME: u64 = 4096;
const MAX_PAX: u64 = 64 * 1024;
const MAX_META_RUN: u32 = 8;
const MAX_LINK_DEPTH: u32 = 40;

/// Archive policy limits (defaults follow design.md D13).
#[derive(Clone)]
pub struct ArchiveLimits {
    pub max_expanded_bytes: u64,
    pub max_entries: u64,
    /// Wall-clock budget for validation plus extraction.
    pub timeout: Duration,
    /// Test-only failure injection (e.g. ENOSPC during extraction).
    pub hooks: Option<Arc<dyn FailPoints>>,
}

impl Default for ArchiveLimits {
    fn default() -> Self {
        ArchiveLimits {
            max_expanded_bytes: 2 * 1024 * 1024 * 1024,
            max_entries: 100_000,
            timeout: Duration::from_secs(60),
            hooks: None,
        }
    }
}

impl std::fmt::Debug for ArchiveLimits {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ArchiveLimits")
            .field("max_expanded_bytes", &self.max_expanded_bytes)
            .field("max_entries", &self.max_entries)
            .field("timeout", &self.timeout)
            .finish()
    }
}

type Comp = Vec<u8>;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Kind {
    Dir,
    File { size: u64, mode: u32 },
    Symlink(Vec<u8>),
    Hardlink(Vec<Comp>),
}

#[derive(Debug)]
struct Item {
    comps: Vec<Comp>,
    kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Node {
    Dir,
    File,
    Symlink(Vec<u8>),
}

fn rejected(msg: impl Into<String>) -> Error {
    Error::new(ErrorCode::ArchiveRejected, msg)
}

/// Reader that fails with `TimedOut` once the deadline passes.
struct DeadlineReader<R> {
    inner: R,
    deadline: Instant,
}

impl<R: Read> Read for DeadlineReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if Instant::now() >= self.deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "archive deadline exceeded",
            ));
        }
        self.inner.read(buf)
    }
}

fn deadline_error() -> Error {
    Error::new(
        ErrorCode::Deadline,
        "archive validation/extraction deadline exceeded",
    )
}

fn archive_read_error(e: io::Error) -> Error {
    if e.kind() == io::ErrorKind::TimedOut {
        deadline_error()
    } else {
        rejected("malformed archive")
    }
}

fn normalize(path: &[u8]) -> Result<Vec<Comp>> {
    if path.is_empty() {
        return Err(rejected("empty entry path"));
    }
    if path[0] == b'/' {
        return Err(rejected("absolute entry path"));
    }
    let mut comps = Vec::new();
    for c in path.split(|b| *b == b'/') {
        match c {
            b"" | b"." => {}
            b".." => return Err(rejected("entry path contains '..'")),
            name => comps.push(name.to_vec()),
        }
    }
    Ok(comps)
}

fn read_meta<R: Read>(entry: &mut R, size: u64, max: u64) -> Result<Vec<u8>> {
    if size > max {
        return Err(rejected("archive extension header too large"));
    }
    let mut buf = Vec::with_capacity(size as usize);
    entry
        .take(max + 1)
        .read_to_end(&mut buf)
        .map_err(archive_read_error)?;
    Ok(buf)
}

fn trim_nul(mut v: Vec<u8>) -> Vec<u8> {
    while v.last() == Some(&0) {
        v.pop();
    }
    v
}

/// Iterate real archive entries (GNU long names and pax headers applied).
fn walk<F>(archive: &Path, limits: &ArchiveLimits, deadline: Instant, mut f: F) -> Result<()>
where
    F: FnMut(&Item, &mut dyn Read) -> Result<()>,
{
    let mut file = fsutil::open_read_nofollow(archive)
        .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "open archive", e))?;
    let mut magic = [0u8; 2];
    let n = file
        .read(&mut magic)
        .map_err(|e| Error::io("read archive", e))?;
    let file = {
        use std::io::{Seek, SeekFrom};
        let mut file = file;
        file.seek(SeekFrom::Start(0))
            .map_err(|e| Error::io("seek archive", e))?;
        file
    };
    let raw: Box<dyn Read> = if n == 2 && magic == [0x1f, 0x8b] {
        Box::new(flate2::read::GzDecoder::new(BufReader::new(file)))
    } else {
        Box::new(BufReader::new(file))
    };
    let reader = DeadlineReader {
        inner: raw,
        deadline,
    };
    let mut ar = tar::Archive::new(reader);
    let entries = ar.entries().map_err(archive_read_error)?.raw(true);

    let mut count: u64 = 0;
    let mut meta_run: u32 = 0;
    let mut long_name: Option<Vec<u8>> = None;
    let mut long_link: Option<Vec<u8>> = None;
    let mut pax_size: Option<u64> = None;

    for entry in entries {
        if Instant::now() >= deadline {
            return Err(deadline_error());
        }
        let mut entry = entry.map_err(archive_read_error)?;
        let etype = entry.header().entry_type();
        let size = entry.size();

        let is_meta = etype.is_gnu_longname()
            || etype.is_gnu_longlink()
            || etype.is_pax_local_extensions()
            || etype.is_pax_global_extensions();
        if is_meta {
            meta_run += 1;
            if meta_run > MAX_META_RUN {
                return Err(rejected("too many consecutive extension headers"));
            }
            if etype.is_gnu_longname() || etype.is_gnu_longlink() {
                let v = trim_nul(read_meta(&mut entry, size, MAX_LONG_NAME)?);
                let slot = if etype.is_gnu_longname() {
                    &mut long_name
                } else {
                    &mut long_link
                };
                if slot.is_some() {
                    return Err(rejected("duplicate long name header"));
                }
                *slot = Some(v);
                continue;
            }
            let buf = read_meta(&mut entry, size, MAX_PAX)?;
            let global = etype.is_pax_global_extensions();
            for ext in PaxExtensions::new(&buf) {
                let ext = ext.map_err(|_| rejected("malformed pax header"))?;
                let key = ext.key_bytes();
                let relevant = matches!(key, b"path" | b"linkpath" | b"size");
                if global {
                    if relevant {
                        return Err(rejected("global pax header overrides entry fields"));
                    }
                    continue;
                }
                match key {
                    b"path" => long_name = Some(ext.value_bytes().to_vec()),
                    b"linkpath" => long_link = Some(ext.value_bytes().to_vec()),
                    b"size" => {
                        let s = std::str::from_utf8(ext.value_bytes())
                            .ok()
                            .and_then(|s| s.parse::<u64>().ok())
                            .ok_or_else(|| rejected("invalid pax size"))?;
                        pax_size = Some(s);
                    }
                    _ => {}
                }
            }
            continue;
        }
        meta_run = 0;

        let path = long_name
            .take()
            .unwrap_or_else(|| entry.header().path_bytes().into_owned());
        let link = long_link
            .take()
            .or_else(|| entry.header().link_name_bytes().map(|c| c.into_owned()));
        if let Some(ps) = pax_size.take() {
            if ps != size {
                return Err(rejected("pax size disagrees with header size"));
            }
        }

        count += 1;
        if count > limits.max_entries {
            return Err(Error::new(
                ErrorCode::ArchiveTooLarge,
                "archive exceeds max entries",
            ));
        }

        let comps = normalize(&path)?;
        let kind = match etype {
            EntryType::Regular | EntryType::Continuous => {
                let mode = entry
                    .header()
                    .mode()
                    .map_err(|_| rejected("invalid entry mode"))?;
                Kind::File {
                    size,
                    mode: (mode & 0o777) | 0o600,
                }
            }
            EntryType::Directory => Kind::Dir,
            EntryType::Symlink => {
                let target = link
                    .filter(|l| !l.is_empty())
                    .ok_or_else(|| rejected("symlink without target"))?;
                if target[0] == b'/' {
                    return Err(rejected("symlink target is absolute"));
                }
                Kind::Symlink(target)
            }
            EntryType::Link => {
                let target = link.ok_or_else(|| rejected("hardlink without target"))?;
                let t = normalize(&target)?;
                if t.is_empty() {
                    return Err(rejected("hardlink target is empty"));
                }
                Kind::Hardlink(t)
            }
            _ => {
                return Err(rejected(
                    "unsupported entry type (device, fifo, socket or other)",
                ))
            }
        };
        if !matches!(kind, Kind::File { .. }) && size != 0 {
            return Err(rejected("non-file entry carries data"));
        }
        if comps.is_empty() {
            if kind == Kind::Dir {
                continue; // "./" root entry
            }
            return Err(rejected("entry path resolves to the destination root"));
        }
        f(&Item { comps, kind }, &mut entry)?;
    }
    if long_name.is_some() || long_link.is_some() || pax_size.is_some() {
        return Err(rejected("dangling extension header"));
    }
    Ok(())
}

/// Resolve `target` (relative) from directory `start` through archive
/// symlinks. `Err` when it escapes the root or loops.
fn resolve(
    model: &HashMap<Vec<Comp>, Node>,
    start: Vec<Comp>,
    target: &[u8],
    depth: &mut u32,
) -> std::result::Result<Vec<Comp>, ()> {
    if target.first() == Some(&b'/') {
        return Err(());
    }
    let mut cur = start;
    for c in target.split(|b| *b == b'/') {
        match c {
            b"" | b"." => {}
            b".." => {
                cur.pop().ok_or(())?;
            }
            name => {
                cur.push(name.to_vec());
                if let Some(Node::Symlink(t)) = model.get(&cur) {
                    *depth += 1;
                    if *depth > MAX_LINK_DEPTH {
                        return Err(());
                    }
                    let parent = cur[..cur.len() - 1].to_vec();
                    let t = t.clone();
                    cur = resolve(model, parent, &t, depth)?;
                }
            }
        }
    }
    Ok(cur)
}

fn validate(archive: &Path, limits: &ArchiveLimits, deadline: Instant) -> Result<()> {
    let mut model: HashMap<Vec<Comp>, Node> = HashMap::new();
    let mut expanded: u64 = 0;
    walk(archive, limits, deadline, |item, _| {
        let n = item.comps.len();
        for i in 1..n {
            let prefix = item.comps[..i].to_vec();
            match model.get(&prefix) {
                None => {
                    model.insert(prefix, Node::Dir);
                }
                Some(Node::Dir) => {}
                Some(_) => return Err(rejected("entry path traverses a symlink or file")),
            }
        }
        let node = match &item.kind {
            Kind::Dir => Node::Dir,
            Kind::File { size, .. } => {
                expanded = expanded
                    .checked_add(*size)
                    .filter(|t| *t <= limits.max_expanded_bytes)
                    .ok_or_else(|| {
                        Error::new(
                            ErrorCode::ArchiveTooLarge,
                            "archive exceeds max expanded bytes",
                        )
                    })?;
                Node::File
            }
            Kind::Symlink(t) => Node::Symlink(t.clone()),
            Kind::Hardlink(target) => {
                for i in 1..target.len() {
                    if model.get(&target[..i]) != Some(&Node::Dir) {
                        return Err(rejected("hardlink target traverses a non-directory"));
                    }
                }
                if model.get(target) != Some(&Node::File) {
                    return Err(rejected(
                        "hardlink target is not an earlier regular file in the archive",
                    ));
                }
                Node::File
            }
        };
        match model.get(&item.comps) {
            None => {}
            Some(Node::Dir) if node == Node::Dir => {}
            Some(_) => return Err(rejected("duplicate archive path")),
        }
        model.insert(item.comps.clone(), node);
        Ok(())
    })?;
    for (path, node) in &model {
        if let Node::Symlink(t) = node {
            let mut depth = 0;
            let parent = path[..path.len() - 1].to_vec();
            if resolve(&model, parent, t, &mut depth).is_err() {
                return Err(rejected("symlink resolves outside the destination"));
            }
        }
        if Instant::now() >= deadline {
            return Err(deadline_error());
        }
    }
    Ok(())
}

fn cstr(name: &[u8]) -> Result<CString> {
    CString::new(name).map_err(|_| rejected("entry name contains NUL"))
}

fn last_err(context: &str) -> Error {
    Error::io_as(
        ErrorCode::ExtractFailed,
        context,
        io::Error::last_os_error(),
    )
}

fn open_dir_at(parent: RawFd, name: &CString) -> io::Result<OwnedFd> {
    // SAFETY: valid dirfd and NUL-terminated name.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was just returned by openat and is owned here.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Open (creating as needed) the directory for `comps` beneath `root`
/// without following any symlink.
fn walk_dirs(root: &OwnedFd, comps: &[Comp], create: bool) -> Result<Option<OwnedFd>> {
    let mut cur: Option<OwnedFd> = None;
    for c in comps {
        let name = cstr(c)?;
        let parent = cur.as_ref().unwrap_or(root).as_raw_fd();
        if create {
            // SAFETY: valid dirfd and name.
            let rc = unsafe { libc::mkdirat(parent, name.as_ptr(), 0o755) };
            if rc != 0 && io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
                return Err(last_err("create directory"));
            }
        }
        let next = open_dir_at(parent, &name).map_err(|e| {
            if matches!(e.raw_os_error(), Some(libc::ELOOP) | Some(libc::ENOTDIR)) {
                Error::new(
                    ErrorCode::ExtractFailed,
                    "refusing to traverse a symlink or non-directory in destination",
                )
            } else {
                Error::io_as(ErrorCode::ExtractFailed, "open directory", e)
            }
        })?;
        cur = Some(next);
    }
    Ok(cur)
}

fn lstat_at(dir: RawFd, name: &CString) -> io::Result<Option<libc::stat>> {
    let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: valid dirfd/name and an out-pointer to a stat buffer.
    let rc = unsafe {
        libc::fstatat(
            dir,
            name.as_ptr(),
            st.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if rc == 0 {
        // SAFETY: fstatat succeeded and initialized the buffer.
        Ok(Some(unsafe { st.assume_init() }))
    } else {
        let e = io::Error::last_os_error();
        if e.raw_os_error() == Some(libc::ENOENT) {
            Ok(None)
        } else {
            Err(e)
        }
    }
}

fn is_dir(st: &libc::stat) -> bool {
    st.st_mode & libc::S_IFMT == libc::S_IFDIR
}

/// Remove an existing non-directory at `dir/name` (never follows links).
fn clear_non_dir(dir: RawFd, name: &CString) -> Result<()> {
    match lstat_at(dir, name).map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "stat", e))? {
        None => Ok(()),
        Some(st) if is_dir(&st) => Err(Error::new(
            ErrorCode::ExtractFailed,
            "cannot replace an existing directory",
        )),
        Some(_) => {
            // SAFETY: valid dirfd/name.
            if unsafe { libc::unlinkat(dir, name.as_ptr(), 0) } != 0 {
                return Err(last_err("remove existing entry"));
            }
            Ok(())
        }
    }
}

fn split_last(comps: &[Comp]) -> (&[Comp], &Comp) {
    let (last, parents) = comps.split_last().expect("non-empty path");
    (parents, last)
}

fn extract(archive: &Path, dest: &Path, limits: &ArchiveLimits, deadline: Instant) -> Result<()> {
    fs::create_dir_all(dest)
        .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "create dest", e))?;
    let root: OwnedFd = File::open(dest)
        .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "open dest", e))?
        .into();
    let mut buf = vec![0u8; IO_BUF];
    walk(archive, limits, deadline, |item, data| {
        let (parents, last) = split_last(&item.comps);
        let pfd = walk_dirs(&root, parents, true)?;
        let dir = pfd.as_ref().unwrap_or(&root).as_raw_fd();
        let name = cstr(last)?;
        match &item.kind {
            Kind::Dir => {
                if let Some(st) = lstat_at(dir, &name)
                    .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "stat", e))?
                {
                    if is_dir(&st) {
                        return Ok(());
                    }
                    clear_non_dir(dir, &name)?;
                }
                // SAFETY: valid dirfd/name.
                if unsafe { libc::mkdirat(dir, name.as_ptr(), 0o755) } != 0 {
                    return Err(last_err("create directory"));
                }
            }
            Kind::File { size, mode } => {
                fail_point(&limits.hooks, FailPoint::ExtractWrite)
                    .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "write file", e))?;
                clear_non_dir(dir, &name)?;
                // SAFETY: valid dirfd/name; flags forbid following links.
                let fd = unsafe {
                    libc::openat(
                        dir,
                        name.as_ptr(),
                        libc::O_WRONLY
                            | libc::O_CREAT
                            | libc::O_EXCL
                            | libc::O_NOFOLLOW
                            | libc::O_CLOEXEC,
                        0o600 as libc::c_uint,
                    )
                };
                if fd < 0 {
                    return Err(last_err("create file"));
                }
                // SAFETY: fd freshly opened and owned.
                let mut out = unsafe { File::from_raw_fd(fd) };
                let mut written: u64 = 0;
                loop {
                    let n = data.read(&mut buf).map_err(archive_read_error)?;
                    if n == 0 {
                        break;
                    }
                    out.write_all(&buf[..n])
                        .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "write file", e))?;
                    written += n as u64;
                }
                if written != *size {
                    return Err(rejected("truncated archive entry"));
                }
                use std::os::unix::fs::PermissionsExt;
                out.set_permissions(fs::Permissions::from_mode(*mode))
                    .map_err(|e| Error::io_as(ErrorCode::ExtractFailed, "chmod", e))?;
            }
            Kind::Symlink(target) => {
                clear_non_dir(dir, &name)?;
                let t = cstr(target)?;
                // SAFETY: valid strings and dirfd.
                if unsafe { libc::symlinkat(t.as_ptr(), dir, name.as_ptr()) } != 0 {
                    return Err(last_err("create symlink"));
                }
            }
            Kind::Hardlink(target) => {
                let (tparents, tlast) = split_last(target);
                let tfd = walk_dirs(&root, tparents, false)?;
                let tdir = tfd.as_ref().unwrap_or(&root).as_raw_fd();
                let tname = cstr(tlast)?;
                clear_non_dir(dir, &name)?;
                // SAFETY: valid dirfds/names; flags 0 = never follow symlinks.
                if unsafe { libc::linkat(tdir, tname.as_ptr(), dir, name.as_ptr(), 0) } != 0 {
                    return Err(last_err("create hardlink"));
                }
            }
        }
        Ok(())
    })?;
    // SAFETY: valid fd.
    if unsafe { libc::syncfs(root.as_raw_fd()) } != 0 {
        return Err(last_err("sync destination"));
    }
    Ok(())
}

/// Validate the whole archive, then extract it into `destination`.
/// Nothing is written to `destination` unless validation succeeds.
pub fn validate_and_extract(
    archive: &Path,
    destination: &Path,
    limits: &ArchiveLimits,
) -> Result<()> {
    let deadline = Instant::now() + limits.timeout;
    validate(archive, limits, deadline)?;
    extract(archive, destination, limits, deadline)
}
