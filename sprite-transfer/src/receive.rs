//! `gf-transfer receive`: resumable workspace upload into the Sprite,
//! verified publish, then confined extraction into the destination.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

use crate::archive::{validate_and_extract, ArchiveLimits};
use crate::protocol::{Direction, Frame, FrameSource, FrameWriter, Limits, Ready};
use crate::state::{ReceiveState, Receiver};
use crate::{Error, ErrorCode, FailPoints, Result};

#[derive(Clone)]
pub struct ReceiveConfig {
    /// Private state root (outside the destination); per-transfer state
    /// lives in `state_dir/<transfer_id>/`.
    pub state_dir: PathBuf,
    /// Extraction destination (the workspace).
    pub dest: PathBuf,
    /// `max_bytes` is the compressed archive limit.
    pub limits: Limits,
    pub archive: ArchiveLimits,
    /// Test-only failure injection.
    pub hooks: Option<Arc<dyn FailPoints>>,
}

/// Run one upload receive conversation. On failure an `error` frame is
/// written (unless the peer is gone or itself reported an error) and the
/// error is returned.
pub fn run_receive<R, W>(input: R, output: W, config: ReceiveConfig) -> Result<()>
where
    R: Read + Send + 'static,
    W: Write,
{
    let mut writer = FrameWriter::new(output);
    let result = (|| {
        config.limits.validate()?;
        let mut source = FrameSource::spawn(input, &config.limits);
        receive_inner(&mut source, &mut writer, &config)
    })();
    if let Err(e) = &result {
        if e.reply {
            let _ = writer.write_frame(&Frame::error(e));
        }
    }
    result
}

fn unexpected(frame: &Frame) -> Error {
    Error::new(
        ErrorCode::Protocol,
        format!("unexpected {} frame", frame.type_name()),
    )
}

fn receive_inner<W: Write>(
    source: &mut FrameSource,
    writer: &mut FrameWriter<W>,
    config: &ReceiveConfig,
) -> Result<()> {
    let open = match source.recv()? {
        Frame::Open(o) => o,
        other => return Err(unexpected(&other)),
    };
    if open.direction != Direction::Upload {
        return Err(Error::new(
            ErrorCode::Protocol,
            "receive requires an upload open",
        ));
    }
    let meta = open.upload_meta()?;
    if meta.length > config.limits.max_bytes {
        return Err(Error::new(ErrorCode::TooLarge, "upload exceeds max bytes"));
    }
    let negotiated = config.limits.negotiate(open.max_payload)?;
    let limits = Limits {
        max_payload: negotiated,
        ..config.limits.clone()
    };
    let mut rx =
        Receiver::open_with_hooks(&config.state_dir, &meta, &limits, config.hooks.clone())?;
    let tid = meta.transfer_id.clone();

    let (committed, completed) = match rx.state() {
        ReceiveState::Receiving => (rx.committed_offset(), false),
        ReceiveState::Published => (meta.length, false),
        ReceiveState::Extracted => (meta.length, true),
        ReceiveState::Extracting | ReceiveState::ExtractFailed => {
            return Err(Error::new(
                ErrorCode::ExtractFailed,
                "workspace extraction previously failed or was interrupted",
            ))
        }
    };
    source.set_max_payload(negotiated);
    writer.write_frame(&Frame::Ready(Ready {
        transfer_id: tid.clone(),
        committed_offset: Some(committed),
        length: None,
        sha256: None,
        max_payload: negotiated,
        completed: Some(completed),
    }))?;

    loop {
        let frame = source.recv()?;
        if frame.transfer_id() != Some(tid.as_str()) {
            return Err(Error::new(
                ErrorCode::Protocol,
                "frame for a different transfer",
            ));
        }
        match frame {
            Frame::Chunk {
                offset,
                sha256,
                data,
                ..
            } => {
                let c = rx.commit_chunk(offset, &data, &sha256)?;
                writer.write_frame(&Frame::Ack {
                    transfer_id: tid.clone(),
                    committed_offset: c,
                })?;
            }
            Frame::Finish { length, sha256, .. } => {
                if length != meta.length || sha256 != meta.sha256 {
                    return Err(Error::new(
                        ErrorCode::MetadataMismatch,
                        "finish metadata differs from open",
                    ));
                }
                let done = rx.finish()?;
                if rx.state() == ReceiveState::Published {
                    rx.set_state(ReceiveState::Extracting)?;
                    let extracted = validate_and_extract(&done.path, &config.dest, &config.archive);
                    if let Err(e) = extracted {
                        let _ = rx.set_state(ReceiveState::ExtractFailed);
                        return Err(e);
                    }
                    rx.set_state(ReceiveState::Extracted)?;
                } else if rx.state() != ReceiveState::Extracted {
                    return Err(Error::new(
                        ErrorCode::ExtractFailed,
                        "workspace extraction previously failed or was interrupted",
                    ));
                }
                writer.write_frame(&Frame::Complete {
                    transfer_id: tid,
                    length: done.length,
                    sha256: done.sha256,
                    extracted: Some(true),
                })?;
                return Ok(());
            }
            other => return Err(unexpected(&other)),
        }
    }
}
