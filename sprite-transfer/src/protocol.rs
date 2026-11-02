//! Protocol v1 framing.
//!
//! Frame = 4-byte big-endian header length `H` (1..=8192), `H` bytes of a
//! UTF-8 JSON object header, then exactly `len` raw payload bytes (`len` is
//! the header's integer `"len"`, absent = 0). All limits are checked before
//! any allocation of the declared size.
//!
//! Headers are encoded as compact JSON with a fixed key order so encoder
//! output is byte-for-byte deterministic: `"v"`, `"type"`, `"transfer_id"`,
//! then the type's remaining fields in contract order, `"len"` last.
//! Decoders never depend on key order and ignore unknown keys.

use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::fsutil::{remaining, validate_id};
use crate::{Error, ErrorCode, Result};

pub const PROTOCOL_VERSION: u64 = 1;
/// Fixed maximum JSON header length in bytes.
pub const MAX_HEADER: usize = 8192;
/// Default and ceiling for the negotiated maximum payload per frame.
pub const MAX_PAYLOAD: u64 = 1_048_576;

pub type Sha256 = [u8; 32];

pub fn sha_hex(sha: &Sha256) -> String {
    hex::encode(sha)
}

/// Parse a lowercase 64-character hex SHA-256.
pub fn parse_sha(s: &str) -> Result<Sha256> {
    if s.len() != 64 || !s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return Err(Error::new(
            ErrorCode::Protocol,
            "sha256 must be 64 lowercase hex characters",
        ));
    }
    let mut out = [0u8; 32];
    hex::decode_to_slice(s, &mut out)
        .map_err(|_| Error::new(ErrorCode::Protocol, "invalid sha256 hex"))?;
    Ok(out)
}

mod sha_serde {
    use super::{parse_sha, sha_hex, Sha256};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(sha: &Sha256, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&sha_hex(sha))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Sha256, D::Error> {
        let s = String::deserialize(d)?;
        parse_sha(&s).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Upload,
    Download,
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::Upload => "upload",
            Direction::Download => "download",
        }
    }
}

/// Transfer identity without the content binding (length/hash). Download
/// opens carry only this; the snapshot binds length/hash.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransferKey {
    pub transfer_id: String,
    pub direction: Direction,
    pub session_id: String,
    pub member_id: String,
    pub lease_generation: u64,
    pub artifact: String,
}

impl TransferKey {
    pub fn validate(&self) -> Result<()> {
        validate_id("transfer_id", &self.transfer_id)?;
        validate_id("session_id", &self.session_id)?;
        validate_id("member_id", &self.member_id)?;
        validate_id("artifact", &self.artifact)
    }

    pub fn with_content(&self, length: u64, sha256: Sha256) -> TransferMeta {
        TransferMeta {
            transfer_id: self.transfer_id.clone(),
            direction: self.direction,
            session_id: self.session_id.clone(),
            member_id: self.member_id.clone(),
            lease_generation: self.lease_generation,
            artifact: self.artifact.clone(),
            length,
            sha256,
        }
    }
}

/// Immutable transfer identity: everything a transfer id binds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransferMeta {
    pub transfer_id: String,
    pub direction: Direction,
    pub session_id: String,
    pub member_id: String,
    pub lease_generation: u64,
    pub artifact: String,
    pub length: u64,
    #[serde(with = "sha_serde")]
    pub sha256: Sha256,
}

impl TransferMeta {
    pub fn key(&self) -> TransferKey {
        TransferKey {
            transfer_id: self.transfer_id.clone(),
            direction: self.direction,
            session_id: self.session_id.clone(),
            member_id: self.member_id.clone(),
            lease_generation: self.lease_generation,
            artifact: self.artifact.clone(),
        }
    }

    pub fn validate(&self) -> Result<()> {
        self.key().validate()
    }
}

/// Per-transfer limits and timing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Limits {
    /// This side's maximum payload per frame (1..=1 MiB).
    pub max_payload: u64,
    /// Maximum artifact length in bytes.
    pub max_bytes: u64,
    /// Maximum wait for a complete frame; also the maximum lock wait.
    pub idle_timeout: Duration,
    /// Absolute wall-clock deadline for the invocation.
    pub deadline: Option<SystemTime>,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_payload: MAX_PAYLOAD,
            max_bytes: 256 * 1024 * 1024,
            idle_timeout: Duration::from_secs(60),
            deadline: None,
        }
    }
}

impl Limits {
    pub fn validate(&self) -> Result<()> {
        if self.max_payload == 0 || self.max_payload > MAX_PAYLOAD {
            return Err(Error::new(
                ErrorCode::Protocol,
                format!("max_payload must be within 1..={MAX_PAYLOAD}"),
            ));
        }
        Ok(())
    }

    /// The lesser of the peer's proposal and our own maximum.
    pub fn negotiate(&self, proposed: u64) -> Result<u64> {
        if proposed == 0 {
            return Err(Error::new(ErrorCode::Protocol, "max_payload must be >= 1"));
        }
        Ok(proposed.min(self.max_payload).min(MAX_PAYLOAD))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Open {
    pub transfer_id: String,
    pub direction: Direction,
    pub session_id: String,
    pub member_id: String,
    pub lease_generation: u64,
    pub artifact: String,
    pub max_payload: u64,
    /// Upload only.
    pub length: Option<u64>,
    /// Upload only.
    pub sha256: Option<Sha256>,
}

impl Open {
    pub fn key(&self) -> TransferKey {
        TransferKey {
            transfer_id: self.transfer_id.clone(),
            direction: self.direction,
            session_id: self.session_id.clone(),
            member_id: self.member_id.clone(),
            lease_generation: self.lease_generation,
            artifact: self.artifact.clone(),
        }
    }

    /// Full metadata for an upload open (requires length and sha256).
    pub fn upload_meta(&self) -> Result<TransferMeta> {
        match (self.length, self.sha256) {
            (Some(length), Some(sha)) => Ok(self.key().with_content(length, sha)),
            _ => Err(Error::new(
                ErrorCode::Protocol,
                "upload open requires length and sha256",
            )),
        }
    }

    pub fn upload(meta: &TransferMeta, max_payload: u64) -> Open {
        Open {
            transfer_id: meta.transfer_id.clone(),
            direction: meta.direction,
            session_id: meta.session_id.clone(),
            member_id: meta.member_id.clone(),
            lease_generation: meta.lease_generation,
            artifact: meta.artifact.clone(),
            max_payload,
            length: Some(meta.length),
            sha256: Some(meta.sha256),
        }
    }

    pub fn download(key: &TransferKey, max_payload: u64) -> Open {
        Open {
            transfer_id: key.transfer_id.clone(),
            direction: key.direction,
            session_id: key.session_id.clone(),
            member_id: key.member_id.clone(),
            lease_generation: key.lease_generation,
            artifact: key.artifact.clone(),
            max_payload,
            length: None,
            sha256: None,
        }
    }
}

/// `ready`: upload reply (`committed_offset`, `max_payload`, `completed`),
/// download offer (`length`, `sha256`, `max_payload`), or download receiver
/// progress (`committed_offset`, `max_payload`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ready {
    pub transfer_id: String,
    pub committed_offset: Option<u64>,
    pub length: Option<u64>,
    pub sha256: Option<Sha256>,
    pub max_payload: u64,
    pub completed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportEntry {
    pub name: String,
    pub size: u64,
    pub too_large: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collect {
    pub outputs_present: bool,
    pub outputs_truncated: bool,
    pub reports: Vec<ReportEntry>,
    pub reports_truncated: bool,
    /// Report files left out because their names cannot be downloaded
    /// (not `[A-Za-z0-9._-]{1,128}`). Omitted from the header when zero.
    pub reports_skipped: u64,
    /// Payload: the (possibly truncated) outputs bytes.
    pub outputs: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    Open(Open),
    Ready(Ready),
    Chunk {
        transfer_id: String,
        offset: u64,
        sha256: Sha256,
        data: Vec<u8>,
    },
    Ack {
        transfer_id: String,
        committed_offset: u64,
    },
    Finish {
        transfer_id: String,
        length: u64,
        sha256: Sha256,
    },
    Complete {
        transfer_id: String,
        length: u64,
        sha256: Sha256,
        /// Upload receive includes `extracted: true`.
        extracted: Option<bool>,
    },
    Error {
        code: String,
        message: String,
    },
    Collect(Collect),
}

impl Frame {
    pub fn type_name(&self) -> &'static str {
        match self {
            Frame::Open(_) => "open",
            Frame::Ready(_) => "ready",
            Frame::Chunk { .. } => "chunk",
            Frame::Ack { .. } => "ack",
            Frame::Finish { .. } => "finish",
            Frame::Complete { .. } => "complete",
            Frame::Error { .. } => "error",
            Frame::Collect(_) => "collect",
        }
    }

    pub fn error(err: &Error) -> Frame {
        Frame::Error {
            code: err.code.as_str().to_string(),
            message: err.message.clone(),
        }
    }

    /// Build a chunk frame, computing its SHA-256.
    pub fn chunk(transfer_id: &str, offset: u64, data: Vec<u8>) -> Frame {
        Frame::Chunk {
            transfer_id: transfer_id.to_string(),
            offset,
            sha256: crate::fsutil::sha256(&data),
            data,
        }
    }

    pub fn transfer_id(&self) -> Option<&str> {
        match self {
            Frame::Open(o) => Some(&o.transfer_id),
            Frame::Ready(r) => Some(&r.transfer_id),
            Frame::Chunk { transfer_id, .. }
            | Frame::Ack { transfer_id, .. }
            | Frame::Finish { transfer_id, .. }
            | Frame::Complete { transfer_id, .. } => Some(transfer_id),
            Frame::Error { .. } | Frame::Collect(_) => None,
        }
    }

    fn payload(&self) -> &[u8] {
        match self {
            Frame::Chunk { data, .. } => data,
            Frame::Collect(c) => &c.outputs,
            _ => &[],
        }
    }
}

/// Convert a received `error` frame into a (silent) local error.
pub fn peer_error(code: &str, message: &str) -> Error {
    let parsed = ErrorCode::parse(code).unwrap_or(ErrorCode::Protocol);
    let mut msg: String = message.chars().take(256).collect();
    msg = format!(
        "peer error {}: {msg}",
        code.chars().take(64).collect::<String>()
    );
    Error::silent(parsed, msg)
}

// ---------------------------------------------------------------- encoding

struct Obj(String);

impl Obj {
    fn new(ty: &str) -> Obj {
        let mut o = Obj(String::with_capacity(256));
        o.0.push_str("{\"v\":1");
        o.str("type", ty);
        o
    }
    fn key(&mut self, k: &str) {
        self.0.push_str(",\"");
        self.0.push_str(k);
        self.0.push_str("\":");
    }
    fn str(&mut self, k: &str, v: &str) {
        self.key(k);
        self.0
            .push_str(&serde_json::to_string(v).expect("string serialization"));
    }
    fn u64(&mut self, k: &str, v: u64) {
        self.key(k);
        self.0.push_str(&v.to_string());
    }
    fn bool(&mut self, k: &str, v: bool) {
        self.key(k);
        self.0.push_str(if v { "true" } else { "false" });
    }
    fn sha(&mut self, k: &str, v: &Sha256) {
        self.str(k, &sha_hex(v));
    }
    fn finish(mut self) -> String {
        self.0.push('}');
        self.0
    }
}

/// Encode just the JSON header (deterministic key order).
/// One `reports` element of a collect header. The collect header's length is
/// exactly its length with no reports plus each element's length plus one
/// comma between elements, which `collect` relies on to fit the header.
pub fn encode_report_entry(r: &ReportEntry) -> String {
    format!(
        "{{\"name\":{},\"size\":{},\"too_large\":{}}}",
        serde_json::to_string(&r.name).expect("string"),
        r.size,
        r.too_large
    )
}

pub fn encode_header(frame: &Frame) -> String {
    let mut o = Obj::new(frame.type_name());
    match frame {
        Frame::Open(op) => {
            o.str("transfer_id", &op.transfer_id);
            o.str("direction", op.direction.as_str());
            o.str("session_id", &op.session_id);
            o.str("member_id", &op.member_id);
            o.u64("lease_generation", op.lease_generation);
            o.str("artifact", &op.artifact);
            o.u64("max_payload", op.max_payload);
            if let Some(l) = op.length {
                o.u64("length", l);
            }
            if let Some(s) = &op.sha256 {
                o.sha("sha256", s);
            }
        }
        Frame::Ready(r) => {
            o.str("transfer_id", &r.transfer_id);
            if let Some(c) = r.committed_offset {
                o.u64("committed_offset", c);
            }
            if let Some(l) = r.length {
                o.u64("length", l);
            }
            if let Some(s) = &r.sha256 {
                o.sha("sha256", s);
            }
            o.u64("max_payload", r.max_payload);
            if let Some(c) = r.completed {
                o.bool("completed", c);
            }
        }
        Frame::Chunk {
            transfer_id,
            offset,
            sha256,
            data,
        } => {
            o.str("transfer_id", transfer_id);
            o.u64("offset", *offset);
            o.sha("sha256", sha256);
            o.u64("len", data.len() as u64);
        }
        Frame::Ack {
            transfer_id,
            committed_offset,
        } => {
            o.str("transfer_id", transfer_id);
            o.u64("committed_offset", *committed_offset);
        }
        Frame::Finish {
            transfer_id,
            length,
            sha256,
        } => {
            o.str("transfer_id", transfer_id);
            o.u64("length", *length);
            o.sha("sha256", sha256);
        }
        Frame::Complete {
            transfer_id,
            length,
            sha256,
            extracted,
        } => {
            o.str("transfer_id", transfer_id);
            o.u64("length", *length);
            o.sha("sha256", sha256);
            if let Some(e) = extracted {
                o.bool("extracted", *e);
            }
        }
        Frame::Error { code, message } => {
            o.str("code", code);
            o.str("message", message);
        }
        Frame::Collect(c) => {
            o.bool("outputs_present", c.outputs_present);
            o.bool("outputs_truncated", c.outputs_truncated);
            o.key("reports");
            o.0.push('[');
            for (i, r) in c.reports.iter().enumerate() {
                if i > 0 {
                    o.0.push(',');
                }
                o.0.push_str(&encode_report_entry(r));
            }
            o.0.push(']');
            o.bool("reports_truncated", c.reports_truncated);
            if c.reports_skipped > 0 {
                o.u64("reports_skipped", c.reports_skipped);
            }
            o.u64("len", c.outputs.len() as u64);
        }
    }
    o.finish()
}

/// Encode a complete frame. Fails if the header exceeds [`MAX_HEADER`] or
/// the payload exceeds `max_payload`.
pub fn encode(frame: &Frame, max_payload: u64) -> Result<Vec<u8>> {
    let header = encode_header(frame);
    if header.len() > MAX_HEADER {
        return Err(Error::new(
            ErrorCode::TooLarge,
            "frame header exceeds 8192 bytes",
        ));
    }
    let payload = frame.payload();
    if payload.len() as u64 > max_payload.min(MAX_PAYLOAD) {
        return Err(Error::new(
            ErrorCode::TooLarge,
            "frame payload exceeds max_payload",
        ));
    }
    let mut out = Vec::with_capacity(4 + header.len() + payload.len());
    out.extend_from_slice(&(header.len() as u32).to_be_bytes());
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

// ---------------------------------------------------------------- decoding

fn perr(msg: impl Into<String>) -> Error {
    Error::new(ErrorCode::Protocol, msg)
}

struct Fields<'a>(&'a Map<String, Value>);

impl Fields<'_> {
    fn get(&self, k: &str) -> Option<&Value> {
        self.0.get(k).filter(|v| !v.is_null())
    }
    fn str(&self, k: &str) -> Result<String> {
        self.get(k)
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| perr(format!("missing or invalid string field {k}")))
    }
    fn id(&self, k: &str) -> Result<String> {
        let s = self.str(k)?;
        validate_id(k, &s)?;
        Ok(s)
    }
    fn opt_u64(&self, k: &str) -> Result<Option<u64>> {
        match self.get(k) {
            None => Ok(None),
            Some(v) => v
                .as_u64()
                .map(Some)
                .ok_or_else(|| perr(format!("field {k} must be a non-negative integer"))),
        }
    }
    fn u64(&self, k: &str) -> Result<u64> {
        self.opt_u64(k)?
            .ok_or_else(|| perr(format!("missing integer field {k}")))
    }
    fn opt_bool(&self, k: &str) -> Result<Option<bool>> {
        match self.get(k) {
            None => Ok(None),
            Some(v) => v
                .as_bool()
                .map(Some)
                .ok_or_else(|| perr(format!("field {k} must be a boolean"))),
        }
    }
    fn bool(&self, k: &str) -> Result<bool> {
        self.opt_bool(k)?
            .ok_or_else(|| perr(format!("missing boolean field {k}")))
    }
    fn opt_sha(&self, k: &str) -> Result<Option<Sha256>> {
        match self.get(k) {
            None => Ok(None),
            Some(v) => {
                let s = v
                    .as_str()
                    .ok_or_else(|| perr(format!("field {k} must be a string")))?;
                parse_sha(s).map(Some)
            }
        }
    }
    fn sha(&self, k: &str) -> Result<Sha256> {
        self.opt_sha(k)?
            .ok_or_else(|| perr(format!("missing sha256 field {k}")))
    }
    fn max_payload(&self) -> Result<u64> {
        let p = self.u64("max_payload")?;
        if p == 0 {
            return Err(perr("max_payload must be >= 1"));
        }
        Ok(p)
    }
}

/// Parse and validate a header. Returns the frame (payload not yet read,
/// i.e. empty) and the declared payload length, which is already checked
/// against `max_payload`.
pub fn decode_header(bytes: &[u8], max_payload: u64) -> Result<(Frame, u64)> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| perr("header is not valid JSON"))?;
    let obj = value
        .as_object()
        .ok_or_else(|| perr("header must be a JSON object"))?;
    match obj.get("v") {
        None => return Err(perr("header missing v")),
        Some(v) if v.as_u64() == Some(PROTOCOL_VERSION) => {}
        Some(_) => {
            return Err(Error::new(
                ErrorCode::UnsupportedVersion,
                "unsupported protocol version",
            ))
        }
    }
    let f = Fields(obj);
    let ty = f.str("type")?;
    let len = f.opt_u64("len")?.unwrap_or(0);
    let has_payload = matches!(ty.as_str(), "chunk" | "collect");
    if !has_payload && len != 0 {
        return Err(perr("control frames carry no payload"));
    }
    if len > max_payload.min(MAX_PAYLOAD) {
        return Err(Error::new(
            ErrorCode::TooLarge,
            "payload length exceeds negotiated max_payload",
        ));
    }
    let frame = match ty.as_str() {
        "open" => {
            let direction = match f.str("direction")?.as_str() {
                "upload" => Direction::Upload,
                "download" => Direction::Download,
                _ => return Err(perr("direction must be upload or download")),
            };
            Frame::Open(Open {
                transfer_id: f.id("transfer_id")?,
                direction,
                session_id: f.id("session_id")?,
                member_id: f.id("member_id")?,
                lease_generation: f.u64("lease_generation")?,
                artifact: f.id("artifact")?,
                max_payload: f.max_payload()?,
                length: f.opt_u64("length")?,
                sha256: f.opt_sha("sha256")?,
            })
        }
        "ready" => Frame::Ready(Ready {
            transfer_id: f.id("transfer_id")?,
            committed_offset: f.opt_u64("committed_offset")?,
            length: f.opt_u64("length")?,
            sha256: f.opt_sha("sha256")?,
            max_payload: f.max_payload()?,
            completed: f.opt_bool("completed")?,
        }),
        "chunk" => {
            let offset = f.u64("offset")?;
            if offset.checked_add(len).is_none() {
                return Err(Error::new(ErrorCode::BadOffset, "offset + len overflows"));
            }
            Frame::Chunk {
                transfer_id: f.id("transfer_id")?,
                offset,
                sha256: f.sha("sha256")?,
                data: Vec::new(),
            }
        }
        "ack" => Frame::Ack {
            transfer_id: f.id("transfer_id")?,
            committed_offset: f.u64("committed_offset")?,
        },
        "finish" => Frame::Finish {
            transfer_id: f.id("transfer_id")?,
            length: f.u64("length")?,
            sha256: f.sha("sha256")?,
        },
        "complete" => Frame::Complete {
            transfer_id: f.id("transfer_id")?,
            length: f.u64("length")?,
            sha256: f.sha("sha256")?,
            extracted: f.opt_bool("extracted")?,
        },
        "error" => Frame::Error {
            code: f.str("code")?,
            message: f
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        "collect" => {
            let reports = match f.get("reports") {
                None => Vec::new(),
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|item| {
                        let o = item
                            .as_object()
                            .ok_or_else(|| perr("report entry must be an object"))?;
                        let rf = Fields(o);
                        Ok(ReportEntry {
                            name: rf.str("name")?,
                            size: rf.u64("size")?,
                            too_large: rf.bool("too_large")?,
                        })
                    })
                    .collect::<Result<Vec<_>>>()?,
                Some(_) => return Err(perr("reports must be an array")),
            };
            Frame::Collect(Collect {
                outputs_present: f.bool("outputs_present")?,
                outputs_truncated: f.bool("outputs_truncated")?,
                reports,
                reports_truncated: f.bool("reports_truncated")?,
                reports_skipped: f.opt_u64("reports_skipped")?.unwrap_or(0),
                outputs: Vec::new(),
            })
        }
        _ => return Err(perr("unknown frame type")),
    };
    Ok((frame, len))
}

/// Bounded incremental frame reader over any `Read` (handles arbitrary
/// fragmentation; never allocates more than the checked declared sizes).
pub struct FrameReader<R> {
    inner: R,
    max_payload: Arc<AtomicU64>,
}

fn read_err(e: io::Error) -> Error {
    Error::silent(ErrorCode::Internal, format!("read failed: {e}"))
}

impl<R: Read> FrameReader<R> {
    pub fn new(inner: R, limits: &Limits) -> Self {
        Self::with_max_payload(inner, limits.max_payload)
    }

    pub fn with_max_payload(inner: R, max_payload: u64) -> Self {
        FrameReader {
            inner,
            max_payload: Arc::new(AtomicU64::new(max_payload.min(MAX_PAYLOAD))),
        }
    }

    /// Apply a negotiated maximum to subsequently decoded frames.
    pub fn set_max_payload(&self, max_payload: u64) {
        self.max_payload
            .store(max_payload.min(MAX_PAYLOAD), Ordering::SeqCst);
    }

    pub fn max_payload_handle(&self) -> Arc<AtomicU64> {
        self.max_payload.clone()
    }

    pub fn into_inner(self) -> R {
        self.inner
    }

    /// Read exactly `buf.len()` bytes. Returns the number read before EOF.
    fn fill(&mut self, buf: &mut [u8]) -> Result<usize> {
        let mut got = 0;
        while got < buf.len() {
            match self.inner.read(&mut buf[got..]) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(read_err(e)),
            }
        }
        Ok(got)
    }

    /// Read the next frame. `Ok(None)` means clean EOF at a frame boundary.
    pub fn read_frame(&mut self) -> Result<Option<Frame>> {
        let mut prefix = [0u8; 4];
        match self.fill(&mut prefix)? {
            0 => return Ok(None),
            4 => {}
            _ => return Err(perr("truncated frame prefix")),
        }
        let hlen = u32::from_be_bytes(prefix) as usize;
        if hlen == 0 {
            return Err(perr("empty frame header"));
        }
        if hlen > MAX_HEADER {
            return Err(Error::new(
                ErrorCode::TooLarge,
                "frame header exceeds 8192 bytes",
            ));
        }
        let mut header = vec![0u8; hlen];
        if self.fill(&mut header)? != hlen {
            return Err(perr("truncated frame header"));
        }
        let max_payload = self.max_payload.load(Ordering::SeqCst);
        let (mut frame, len) = decode_header(&header, max_payload)?;
        if len > 0 {
            // len <= max_payload <= 1 MiB was checked by decode_header.
            let mut payload = vec![0u8; len as usize];
            if self.fill(&mut payload)? as u64 != len {
                return Err(perr("truncated frame payload"));
            }
            match &mut frame {
                Frame::Chunk { data, .. } => *data = payload,
                Frame::Collect(c) => c.outputs = payload,
                _ => unreachable!("payload only for chunk/collect"),
            }
        }
        Ok(Some(frame))
    }
}

/// Frame writer; flushes after every frame.
pub struct FrameWriter<W> {
    inner: W,
    max_payload: u64,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> Self {
        FrameWriter {
            inner,
            max_payload: MAX_PAYLOAD,
        }
    }

    pub fn with_max_payload(inner: W, max_payload: u64) -> Self {
        FrameWriter {
            inner,
            max_payload: max_payload.min(MAX_PAYLOAD),
        }
    }

    pub fn set_max_payload(&mut self, max_payload: u64) {
        self.max_payload = max_payload.min(MAX_PAYLOAD);
    }

    pub fn write_frame(&mut self, frame: &Frame) -> Result<()> {
        let bytes = encode(frame, self.max_payload)?;
        self.inner
            .write_all(&bytes)
            .and_then(|_| self.inner.flush())
            .map_err(|e| Error::silent(ErrorCode::Internal, format!("write failed: {e}")))
    }

    pub fn get_ref(&self) -> &W {
        &self.inner
    }

    pub fn into_inner(self) -> W {
        self.inner
    }
}

enum Event {
    Frame(Frame),
    Eof,
    Err(Error),
}

/// Frames decoded on a background thread so the caller can enforce the idle
/// timeout and absolute deadline while stdin blocks.
pub struct FrameSource {
    rx: mpsc::Receiver<Event>,
    max_payload: Arc<AtomicU64>,
    idle_timeout: Duration,
    deadline: Option<SystemTime>,
    done: bool,
}

impl FrameSource {
    pub fn spawn<R: Read + Send + 'static>(input: R, limits: &Limits) -> FrameSource {
        let mut reader = FrameReader::new(input, limits);
        let max_payload = reader.max_payload_handle();
        // Rendezvous channel: at most one decoded frame is outstanding.
        let (tx, rx) = mpsc::sync_channel(0);
        thread::Builder::new()
            .name("gf-transfer-reader".into())
            .spawn(move || loop {
                let ev = match reader.read_frame() {
                    Ok(Some(f)) => Event::Frame(f),
                    Ok(None) => Event::Eof,
                    Err(e) => Event::Err(e),
                };
                let stop = !matches!(ev, Event::Frame(_));
                if tx.send(ev).is_err() || stop {
                    break;
                }
            })
            .expect("spawn reader thread");
        FrameSource {
            rx,
            max_payload,
            idle_timeout: limits.idle_timeout,
            deadline: limits.deadline,
            done: false,
        }
    }

    pub fn set_max_payload(&self, max_payload: u64) {
        self.max_payload
            .store(max_payload.min(MAX_PAYLOAD), Ordering::SeqCst);
    }

    /// Wait for the next frame, bounded by the idle timeout and deadline.
    /// A received `error` frame is returned as a silent error.
    pub fn recv(&mut self) -> Result<Frame> {
        if self.done {
            return Err(Error::silent(ErrorCode::Protocol, "input closed"));
        }
        let mut wait = self.idle_timeout;
        let mut deadline_bound = false;
        if let Some(rem) = remaining(self.deadline) {
            if rem.is_zero() {
                return Err(Error::new(ErrorCode::Deadline, "deadline reached"));
            }
            if rem <= wait {
                wait = rem;
                deadline_bound = true;
            }
        }
        match self.rx.recv_timeout(wait) {
            Ok(Event::Frame(Frame::Error { code, message })) => {
                self.done = true;
                Err(peer_error(&code, &message))
            }
            Ok(Event::Frame(f)) => Ok(f),
            Ok(Event::Eof) => {
                self.done = true;
                Err(Error::silent(ErrorCode::Protocol, "input closed"))
            }
            Ok(Event::Err(e)) => {
                self.done = true;
                Err(e)
            }
            Err(RecvTimeoutError::Timeout) if deadline_bound => {
                Err(Error::new(ErrorCode::Deadline, "deadline reached"))
            }
            Err(RecvTimeoutError::Timeout) => Err(Error::new(
                ErrorCode::IdleTimeout,
                "no complete frame within idle timeout",
            )),
            Err(RecvTimeoutError::Disconnected) => {
                self.done = true;
                Err(Error::silent(ErrorCode::Protocol, "input closed"))
            }
        }
    }
}
