//! `gf-transfer`: the GoodFlows Sprite transfer helper.
//!
//! The helper is a short-lived, single-transfer CLI that speaks framed
//! protocol v1 (see `README.md`) over stdin/stdout. This library exposes the
//! building blocks so tests can drive them black-box:
//!
//! - [`protocol`]: frame types plus bounded incremental reader/writer.
//! - [`state`]: durable, resumable receiving state ([`state::Receiver`]).
//! - [`receive`]: workspace upload receive + verified extraction.
//! - [`send`]: immutable report snapshots and resumable sending.
//! - [`archive`]: confined tar(.gz) validation and extraction.
//! - [`collect`]: bounded outputs read plus report manifest.

pub mod archive;
pub mod collect;
pub mod fsutil;
pub mod protocol;
pub mod receive;
pub mod send;
pub mod state;
pub mod watchdog;

use std::fmt;
use std::io;

/// Wire error codes (`error` frame `code` field).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    UnsupportedVersion,
    Protocol,
    TooLarge,
    BadOffset,
    BadChunk,
    MetadataMismatch,
    Busy,
    RestartRequired,
    ArchiveRejected,
    ArchiveTooLarge,
    DiskFull,
    ExtractFailed,
    SourceRejected,
    Deadline,
    IdleTimeout,
    Internal,
}

impl ErrorCode {
    pub const ALL: [ErrorCode; 16] = [
        ErrorCode::UnsupportedVersion,
        ErrorCode::Protocol,
        ErrorCode::TooLarge,
        ErrorCode::BadOffset,
        ErrorCode::BadChunk,
        ErrorCode::MetadataMismatch,
        ErrorCode::Busy,
        ErrorCode::RestartRequired,
        ErrorCode::ArchiveRejected,
        ErrorCode::ArchiveTooLarge,
        ErrorCode::DiskFull,
        ErrorCode::ExtractFailed,
        ErrorCode::SourceRejected,
        ErrorCode::Deadline,
        ErrorCode::IdleTimeout,
        ErrorCode::Internal,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::UnsupportedVersion => "unsupported_version",
            ErrorCode::Protocol => "protocol",
            ErrorCode::TooLarge => "too_large",
            ErrorCode::BadOffset => "bad_offset",
            ErrorCode::BadChunk => "bad_chunk",
            ErrorCode::MetadataMismatch => "metadata_mismatch",
            ErrorCode::Busy => "busy",
            ErrorCode::RestartRequired => "restart_required",
            ErrorCode::ArchiveRejected => "archive_rejected",
            ErrorCode::ArchiveTooLarge => "archive_too_large",
            ErrorCode::DiskFull => "disk_full",
            ErrorCode::ExtractFailed => "extract_failed",
            ErrorCode::SourceRejected => "source_rejected",
            ErrorCode::Deadline => "deadline",
            ErrorCode::IdleTimeout => "idle_timeout",
            ErrorCode::Internal => "internal",
        }
    }

    pub fn parse(s: &str) -> Option<ErrorCode> {
        ErrorCode::ALL.iter().copied().find(|c| c.as_str() == s)
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Helper error. `message` never contains payload bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    /// False when the peer is gone or already reported the error itself
    /// (stdin EOF, a received `error` frame), so no error frame is written.
    pub reply: bool,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Error {
        Error {
            code,
            message: message.into(),
            reply: true,
        }
    }

    /// An error that must not be answered with an error frame.
    pub fn silent(code: ErrorCode, message: impl Into<String>) -> Error {
        Error {
            reply: false,
            ..Error::new(code, message)
        }
    }

    /// Map an I/O error with context; ENOSPC/EDQUOT become `disk_full`.
    pub fn io(context: &str, err: io::Error) -> Error {
        Error::new(
            io_code(&err, ErrorCode::Internal),
            format!("{context}: {err}"),
        )
    }

    /// Like [`Error::io`] but with a caller-chosen fallback code.
    pub fn io_as(code: ErrorCode, context: &str, err: io::Error) -> Error {
        Error::new(io_code(&err, code), format!("{context}: {err}"))
    }
}

fn io_code(err: &io::Error, fallback: ErrorCode) -> ErrorCode {
    match err.raw_os_error() {
        Some(libc::ENOSPC) | Some(libc::EDQUOT) => ErrorCode::DiskFull,
        _ if err.kind() == io::ErrorKind::StorageFull => ErrorCode::DiskFull,
        _ => fallback,
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

/// Durability boundaries at which tests can inject failures (simulated
/// crashes or `ENOSPC`). Production code passes no hooks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FailPoint {
    /// Before chunk bytes are written to the part file.
    BeforeDataWrite,
    /// Chunk bytes written but not yet fsync'd.
    AfterDataWrite,
    /// Chunk bytes fsync'd; sidecar still records the old boundary.
    AfterDataSync,
    /// New sidecar temp file written+fsync'd but not yet renamed.
    AfterSidecarTemp,
    /// Sidecar renamed into place, directory not yet fsync'd (a failure
    /// here leaves the new boundary recorded on disk).
    AfterSidecarRename,
    /// Sidecar atomically replaced; ack not yet sent.
    AfterSidecarCommit,
    /// Part file renamed to the published artifact; sidecar not yet updated.
    AfterPublishRename,
    /// Sidecar records `published`; completion not yet returned.
    AfterPublishRecord,
    /// Snapshot copy finished; source not yet re-checked for changes.
    SnapshotAfterCopy,
    /// Before each regular file is written during extraction.
    ExtractWrite,
}

/// Failure injection hook. Returning `Err` aborts the operation at that
/// boundary exactly as an I/O error would.
pub trait FailPoints: Send + Sync {
    fn check(&self, point: FailPoint) -> io::Result<()>;
}

pub(crate) fn fail_point(
    hooks: &Option<std::sync::Arc<dyn FailPoints>>,
    point: FailPoint,
) -> io::Result<()> {
    match hooks {
        Some(h) => h.check(point),
        None => Ok(()),
    }
}
