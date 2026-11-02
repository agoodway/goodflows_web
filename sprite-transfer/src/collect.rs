//! `gf-transfer collect`: one bounded frame with the exec outputs file
//! (truncated to `max_outputs`) and a no-follow manifest of report files.

use std::collections::BinaryHeap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use crate::fsutil::is_valid_id;
use crate::protocol::{
    encode_header, encode_report_entry, Collect, Frame, FrameWriter, ReportEntry, MAX_HEADER,
    MAX_PAYLOAD,
};
use crate::{Error, ErrorCode, Result};

pub const DEFAULT_MAX_OUTPUTS: u64 = 65_537;
pub const DEFAULT_MAX_REPORTS: usize = 100;
pub const DEFAULT_MAX_REPORT_BYTES: u64 = 33_554_432;

#[derive(Debug, Clone)]
pub struct CollectConfig {
    pub outputs: PathBuf,
    pub report_dir: Option<PathBuf>,
    pub max_outputs: u64,
    pub max_reports: usize,
    pub max_report_bytes: u64,
}

impl CollectConfig {
    pub fn new(outputs: impl Into<PathBuf>) -> CollectConfig {
        CollectConfig {
            outputs: outputs.into(),
            report_dir: None,
            max_outputs: DEFAULT_MAX_OUTPUTS,
            max_reports: DEFAULT_MAX_REPORTS,
            max_report_bytes: DEFAULT_MAX_REPORT_BYTES,
        }
    }
}

/// Read up to `max` bytes of a regular, non-symlink file.
/// Returns (present, truncated, bytes).
fn read_outputs(path: &Path, max: u64) -> Result<(bool, bool, Vec<u8>)> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(f) => f,
        Err(e)
            if matches!(
                e.raw_os_error(),
                Some(libc::ENOENT) | Some(libc::ELOOP) | Some(libc::ENOTDIR)
            ) =>
        {
            return Ok((false, false, Vec::new()))
        }
        Err(e) => return Err(Error::io("open outputs", e)),
    };
    let md = file.metadata().map_err(|e| Error::io("stat outputs", e))?;
    if !md.file_type().is_file() {
        return Ok((false, false, Vec::new()));
    }
    let mut buf = Vec::new();
    // Read one extra byte to detect growth beyond the cap.
    file.take(max + 1)
        .read_to_end(&mut buf)
        .map_err(|e| Error::io("read outputs", e))?;
    let truncated = buf.len() as u64 > max || md.len() > max;
    buf.truncate(max as usize);
    Ok((true, truncated, buf))
}

/// Reports found by [`list_reports`].
struct Listing {
    entries: Vec<ReportEntry>,
    truncated: bool,
    skipped: u64,
}

/// Direct `*.jsonl` regular files (lstat, never followed), sorted by name
/// and capped at `max_reports`. Files whose names `send` would refuse
/// (anything but `[A-Za-z0-9._-]{1,128}`, including non-UTF-8 names) are
/// left out and counted in `skipped`, so every listed report can be
/// downloaded.
///
/// Work is bounded by the cap, not the directory size: the scan keeps only
/// the `max_reports + 1` smallest names in a max-heap (file type from the
/// directory entry, which does not follow links), and only those survivors
/// are `lstat`ed for their size.
fn list_reports(dir: &Path, max_reports: usize, max_bytes: u64) -> Result<Listing> {
    let empty = Listing {
        entries: Vec::new(),
        truncated: false,
        skipped: 0,
    };
    match fs::symlink_metadata(dir) {
        Ok(md) if md.file_type().is_dir() => {}
        Ok(_) => return Ok(empty),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(empty),
        Err(e) => return Err(Error::io("stat report dir", e)),
    }
    let keep = max_reports.saturating_add(1);
    let mut heap: BinaryHeap<String> = BinaryHeap::new();
    let mut evicted = false;
    let mut skipped = 0;
    for ent in fs::read_dir(dir).map_err(|e| Error::io("read report dir", e))? {
        let ent = ent.map_err(|e| Error::io("read report dir", e))?;
        let raw = ent.file_name();
        if !raw.as_bytes().ends_with(b".jsonl") {
            continue;
        }
        match ent.file_type() {
            Ok(t) if t.is_file() => {}
            _ => continue,
        }
        let name = match std::str::from_utf8(raw.as_bytes()) {
            Ok(n) if is_valid_id(n) => n,
            _ => {
                skipped += 1;
                continue;
            }
        };
        if heap.len() == keep {
            match heap.peek() {
                Some(max) if name < max.as_str() => {
                    heap.pop();
                    evicted = true;
                }
                _ => {
                    evicted = true;
                    continue;
                }
            }
        }
        heap.push(name.to_string());
    }
    let mut entries = Vec::with_capacity(heap.len());
    for name in heap.into_sorted_vec() {
        // The entry may have changed since the scan; re-check without
        // following links and drop anything no longer a regular file.
        let md = match fs::symlink_metadata(dir.join(&name)) {
            Ok(md) if md.file_type().is_file() => md,
            _ => continue,
        };
        entries.push(ReportEntry {
            name,
            size: md.len(),
            too_large: md.len() > max_bytes,
        });
    }
    let truncated = evicted || entries.len() > max_reports;
    entries.truncate(max_reports);
    Ok(Listing {
        entries,
        truncated,
        skipped,
    })
}

/// Keep the longest prefix of `frame.reports` whose header fits in
/// `MAX_HEADER`, marking the listing truncated when anything is dropped.
/// One pass: the header length is additive in its report entries (see
/// [`encode_report_entry`]).
fn fit_header(mut frame: Collect) -> Frame {
    let reports = std::mem::take(&mut frame.reports);
    let sizes: Vec<usize> = reports
        .iter()
        .map(|r| encode_report_entry(r).len())
        .collect();
    let list_len = |n: usize| sizes[..n].iter().sum::<usize>() + n.saturating_sub(1);
    let base = encode_header(&Frame::Collect(frame.clone())).len();
    if base + list_len(reports.len()) <= MAX_HEADER {
        frame.reports = reports;
        return Frame::Collect(frame);
    }
    frame.reports_truncated = true;
    let base = encode_header(&Frame::Collect(frame.clone())).len();
    let mut used = base;
    let mut n = 0;
    for size in &sizes {
        let add = size + usize::from(n > 0);
        if used + add > MAX_HEADER {
            break;
        }
        used += add;
        n += 1;
    }
    frame.reports = reports;
    frame.reports.truncate(n);
    let f = Frame::Collect(frame);
    debug_assert!(encode_header(&f).len() <= MAX_HEADER);
    f
}

/// Build the collect frame.
pub fn collect(config: &CollectConfig) -> Result<Frame> {
    if config.max_outputs > MAX_PAYLOAD {
        return Err(Error::new(
            ErrorCode::Protocol,
            "max outputs exceeds max payload",
        ));
    }
    let (present, out_truncated, outputs) = read_outputs(&config.outputs, config.max_outputs)?;
    let listing = match &config.report_dir {
        Some(d) => list_reports(d, config.max_reports, config.max_report_bytes)?,
        None => Listing {
            entries: Vec::new(),
            truncated: false,
            skipped: 0,
        },
    };
    Ok(fit_header(Collect {
        outputs_present: present,
        outputs_truncated: out_truncated,
        reports: listing.entries,
        reports_truncated: listing.truncated,
        reports_skipped: listing.skipped,
        outputs,
    }))
}

/// Write the collect frame to `output`.
pub fn run_collect<W: Write>(output: W, config: &CollectConfig) -> Result<()> {
    let frame = collect(config)?;
    FrameWriter::new(output).write_frame(&frame)
}
