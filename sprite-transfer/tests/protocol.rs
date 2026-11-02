mod common;

use std::io::{self, Cursor, Read};
use std::path::PathBuf;
use std::process::Command;

use common::*;
use gf_transfer::fsutil::sha256;
use gf_transfer::protocol::*;
use gf_transfer::ErrorCode;

/// Reader that yields `data` in the given fragment sizes and records how
/// many bytes were consumed (to prove limits are checked before reads).
struct Fragmented {
    data: Vec<u8>,
    pos: usize,
    cuts: Vec<usize>,
    max_read: usize,
}

impl Fragmented {
    fn new(data: Vec<u8>, cuts: Vec<usize>) -> Self {
        Fragmented {
            data,
            pos: 0,
            cuts,
            max_read: usize::MAX,
        }
    }

    fn bytewise(data: Vec<u8>) -> Self {
        Fragmented {
            max_read: 1,
            ..Fragmented::new(data, vec![])
        }
    }
}

impl Read for Fragmented {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let next_cut = self
            .cuts
            .iter()
            .copied()
            .find(|c| *c > self.pos)
            .unwrap_or(self.data.len());
        let n = buf
            .len()
            .min(next_cut - self.pos)
            .min(self.max_read)
            .min(self.data.len() - self.pos);
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

fn raw(header: &str, payload: &[u8]) -> Vec<u8> {
    let mut out = (header.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(payload);
    out
}

const SHA_ABC: &str = "0000000000000000000000000000000000000000000000000000000000000000";

fn read_all(r: &mut FrameReader<impl Read>) -> Vec<Frame> {
    let mut out = vec![];
    while let Some(f) = r.read_frame().unwrap() {
        out.push(f);
    }
    out
}

/// Payload used in the documented binary fixture.
const BINARY: &[u8] = &[0x00, 0xff, 0x10, 0x80, b'a', b'b', b'c'];

fn fixture_frames() -> Vec<(&'static str, Frame)> {
    let sha = sha256(BINARY);
    let key = TransferKey {
        transfer_id: "t-0001".into(),
        direction: Direction::Upload,
        session_id: "s-1".into(),
        member_id: "m-1".into(),
        lease_generation: 3,
        artifact: "workspace.tar.gz".into(),
    };
    let meta = key.with_content(BINARY.len() as u64, sha);
    let dkey = TransferKey {
        transfer_id: "t-0002".into(),
        direction: Direction::Download,
        artifact: "a.jsonl".into(),
        ..key.clone()
    };
    vec![
        ("open_upload", Frame::Open(Open::upload(&meta, 1_048_576))),
        (
            "open_download",
            Frame::Open(Open::download(&dkey, 1_048_576)),
        ),
        (
            "ready_upload",
            Frame::Ready(Ready {
                transfer_id: "t-0001".into(),
                committed_offset: Some(0),
                length: None,
                sha256: None,
                max_payload: 1_048_576,
                completed: Some(false),
            }),
        ),
        (
            "ready_offer",
            Frame::Ready(Ready {
                transfer_id: "t-0002".into(),
                committed_offset: None,
                length: Some(7),
                sha256: Some(sha),
                max_payload: 1_048_576,
                completed: None,
            }),
        ),
        (
            "ready_resume",
            Frame::Ready(Ready {
                transfer_id: "t-0002".into(),
                committed_offset: Some(0),
                length: None,
                sha256: None,
                max_payload: 1_048_576,
                completed: None,
            }),
        ),
        ("chunk_binary", Frame::chunk("t-0001", 0, BINARY.to_vec())),
        (
            "ack",
            Frame::Ack {
                transfer_id: "t-0001".into(),
                committed_offset: 7,
            },
        ),
        (
            "finish",
            Frame::Finish {
                transfer_id: "t-0001".into(),
                length: 7,
                sha256: sha,
            },
        ),
        (
            "complete",
            Frame::Complete {
                transfer_id: "t-0001".into(),
                length: 7,
                sha256: sha,
                extracted: Some(true),
            },
        ),
        (
            "error",
            Frame::Error {
                code: "bad_chunk".into(),
                message: "chunk sha256 mismatch".into(),
            },
        ),
        (
            "collect",
            Frame::Collect(Collect {
                outputs_present: true,
                outputs_truncated: false,
                reports: vec![ReportEntry {
                    name: "a.jsonl".into(),
                    size: 123,
                    too_large: false,
                }],
                reports_truncated: false,
                reports_skipped: 0,
                outputs: b"ok\n".to_vec(),
            }),
        ),
    ]
}

/// The encoder must reproduce the committed fixtures byte-for-byte (shared
/// with the Elixir codec tests). Regenerate with GF_UPDATE_FIXTURES=1.
#[test]
fn fixtures_roundtrip() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let update = std::env::var_os("GF_UPDATE_FIXTURES").is_some();
    for (name, frame) in fixture_frames() {
        let bytes = encode(&frame, MAX_PAYLOAD).unwrap();
        let path = dir.join(format!("{name}.bin"));
        if update {
            std::fs::write(&path, &bytes).unwrap();
        }
        let fixture = std::fs::read(&path).unwrap_or_else(|_| panic!("missing fixture {name}"));
        assert_eq!(bytes, fixture, "fixture {name} differs from encoder output");
        let decoded = decode_all(&fixture);
        assert_eq!(decoded, vec![frame], "fixture {name} decode");
    }
}

#[test]
fn exact_header_text_and_key_order() {
    let frames: Vec<Frame> = fixture_frames().into_iter().map(|(_, f)| f).collect();
    let sha = hex::encode(sha256(BINARY));
    assert_eq!(
        encode_header(&frames[0]),
        format!(
            r#"{{"v":1,"type":"open","transfer_id":"t-0001","direction":"upload","session_id":"s-1","member_id":"m-1","lease_generation":3,"artifact":"workspace.tar.gz","max_payload":1048576,"length":7,"sha256":"{sha}"}}"#
        )
    );
    assert_eq!(
        encode_header(&frames[5]),
        format!(
            r#"{{"v":1,"type":"chunk","transfer_id":"t-0001","offset":0,"sha256":"{sha}","len":7}}"#
        )
    );
    assert_eq!(
        encode_header(&frames[10]),
        r#"{"v":1,"type":"collect","outputs_present":true,"outputs_truncated":false,"reports":[{"name":"a.jsonl","size":123,"too_large":false}],"reports_truncated":false,"len":3}"#
    );
}

#[test]
fn decoder_ignores_key_order_and_unknown_keys() {
    let sha = hex::encode(sha256(b"abc"));
    let hdr = format!(
        r#"{{"len":3,"extra":{{"x":[1,2]}},"sha256":"{sha}","offset":5,"transfer_id":"t","type":"chunk","v":1}}"#
    );
    let frames = read_all(&mut FrameReader::with_max_payload(
        Cursor::new(raw(&hdr, b"abc")),
        MAX_PAYLOAD,
    ));
    assert_eq!(frames, vec![Frame::chunk("t", 5, b"abc".to_vec())]);
}

#[test]
fn binary_fragmented_roundtrip() {
    let mut payload: Vec<u8> = (0..=255u8).collect();
    payload.extend_from_slice(&[0, 0, 0xff, 0xfe, 0xc3, 0x28, b'\n', b'{']);
    let frames = vec![
        Frame::chunk("t-1", 0, payload.clone()),
        Frame::Ack {
            transfer_id: "t-1".into(),
            committed_offset: payload.len() as u64,
        },
        Frame::chunk("t-1", 264, BINARY.to_vec()),
        Frame::chunk("t-1", 271, vec![0u8; 3]),
    ];
    let stream = frame_bytes(&frames);

    // Byte-at-a-time.
    let mut r = FrameReader::with_max_payload(Fragmented::bytewise(stream.clone()), MAX_PAYLOAD);
    assert_eq!(read_all(&mut r), frames);

    // Every two-fragment split, including inside prefix/header/payload.
    for cut in 0..=stream.len() {
        let mut r =
            FrameReader::with_max_payload(Fragmented::new(stream.clone(), vec![cut]), MAX_PAYLOAD);
        assert_eq!(read_all(&mut r), frames, "split at {cut}");
    }

    // Three fragments at every pair of boundaries within the first frame.
    let first = encode(&frames[0], MAX_PAYLOAD).unwrap().len();
    for a in (0..first).step_by(7) {
        for b in (a..first + 10).step_by(11) {
            let mut r = FrameReader::with_max_payload(
                Fragmented::new(stream.clone(), vec![a, b]),
                MAX_PAYLOAD,
            );
            assert_eq!(read_all(&mut r), frames, "split at {a},{b}");
        }
    }

    // Truncated stream: error, never a partial frame.
    let mut r = FrameReader::with_max_payload(
        Cursor::new(stream[..stream.len() - 1].to_vec()),
        MAX_PAYLOAD,
    );
    for _ in 0..3 {
        assert!(r.read_frame().unwrap().is_some());
    }
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::Protocol);
}

#[test]
fn reject_oversized_before_allocation() {
    // 8193-byte header: rejected after the 4-byte prefix only.
    let mut stream = 8193u32.to_be_bytes().to_vec();
    stream.extend(vec![b' '; 8193]);
    let mut r = FrameReader::with_max_payload(Fragmented::new(stream, vec![]), MAX_PAYLOAD);
    let err = r.read_frame().unwrap_err();
    assert_eq!(err.code, ErrorCode::TooLarge);
    assert_eq!(r.into_inner().pos, 4, "header bytes must not be read");

    // Exactly 8192 bytes is allowed (padding with JSON whitespace).
    let hdr = r#"{"v":1,"type":"ack","transfer_id":"t","committed_offset":1}"#;
    let padded = format!("{hdr}{}", " ".repeat(8192 - hdr.len()));
    let frames = decode_all(&raw(&padded, b""));
    assert_eq!(frames.len(), 1);

    // Zero-length header.
    let mut r = FrameReader::with_max_payload(Cursor::new(vec![0, 0, 0, 0]), MAX_PAYLOAD);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::Protocol);

    // Payload above the 1 MiB ceiling: rejected before any payload read,
    // even if the reader's own limit were higher.
    let hdr = format!(
        r#"{{"v":1,"type":"chunk","transfer_id":"t","offset":0,"sha256":"{SHA_ABC}","len":1048577}}"#
    );
    let stream = raw(&hdr, &[]);
    let hlen = stream.len();
    let mut r = FrameReader::with_max_payload(Fragmented::new(stream, vec![]), u64::MAX);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::TooLarge);
    assert_eq!(r.into_inner().pos, hlen);

    // Payload above the negotiated maximum.
    let hdr = format!(
        r#"{{"v":1,"type":"chunk","transfer_id":"t","offset":0,"sha256":"{SHA_ABC}","len":4097}}"#
    );
    let mut stream = raw(&hdr, &[]);
    let hlen = stream.len();
    stream.extend(vec![0u8; 4097]);
    let mut r = FrameReader::with_max_payload(Fragmented::new(stream.clone(), vec![]), MAX_PAYLOAD);
    r.set_max_payload(4096);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::TooLarge);
    assert_eq!(r.into_inner().pos, hlen);
    // ... and accepted once the negotiated maximum allows 4097 bytes.
    let mut r = FrameReader::with_max_payload(Cursor::new(stream), 4097);
    assert!(matches!(r.read_frame().unwrap(), Some(Frame::Chunk { .. })));

    // Control frames may not declare a payload.
    let hdr = r#"{"v":1,"type":"ack","transfer_id":"t","committed_offset":1,"len":1}"#;
    let mut r = FrameReader::with_max_payload(Cursor::new(raw(hdr, b"x")), MAX_PAYLOAD);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::Protocol);

    // Encoder refuses to produce oversized frames.
    let big = Frame::chunk("t", 0, vec![0u8; 4097]);
    assert_eq!(encode(&big, 4096).unwrap_err().code, ErrorCode::TooLarge);
    let long_msg = Frame::Error {
        code: "internal".into(),
        message: "x".repeat(9000),
    };
    assert_eq!(
        encode(&long_msg, MAX_PAYLOAD).unwrap_err().code,
        ErrorCode::TooLarge
    );
}

#[test]
fn reject_offset_overflow() {
    let hdr = format!(
        r#"{{"v":1,"type":"chunk","transfer_id":"t","offset":{},"sha256":"{SHA_ABC}","len":2}}"#,
        u64::MAX - 1
    );
    let mut r =
        FrameReader::with_max_payload(Fragmented::new(raw(&hdr, b"ab"), vec![]), MAX_PAYLOAD);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::BadOffset);

    // Integers beyond u64, negative or fractional are malformed.
    for bad in ["18446744073709551616", "-1", "1.5", "\"1\""] {
        let hdr = format!(r#"{{"v":1,"type":"ack","transfer_id":"t","committed_offset":{bad}}}"#);
        let mut r = FrameReader::with_max_payload(Cursor::new(raw(&hdr, b"")), MAX_PAYLOAD);
        assert_eq!(
            r.read_frame().unwrap_err().code,
            ErrorCode::Protocol,
            "{bad}"
        );
    }
}

#[test]
fn reject_unknown_version() {
    for v in ["2", "0", "\"1\"", "1.0", "null"] {
        let hdr = format!(r#"{{"v":{v},"type":"ack","transfer_id":"t","committed_offset":1}}"#);
        let mut r = FrameReader::with_max_payload(Cursor::new(raw(&hdr, b"")), MAX_PAYLOAD);
        assert_eq!(
            r.read_frame().unwrap_err().code,
            ErrorCode::UnsupportedVersion,
            "v={v}"
        );
    }
    let hdr = r#"{"type":"ack","transfer_id":"t","committed_offset":1}"#;
    let mut r = FrameReader::with_max_payload(Cursor::new(raw(hdr, b"")), MAX_PAYLOAD);
    assert_eq!(r.read_frame().unwrap_err().code, ErrorCode::Protocol);

    // The receive command answers with an unsupported_version error frame.
    let tmp = TempDir::new("version");
    let hdr = r#"{"v":2,"type":"open"}"#;
    let mut out = Vec::new();
    let err = gf_transfer::receive::run_receive(
        Cursor::new(raw(hdr, b"")),
        &mut out,
        gf_transfer::receive::ReceiveConfig {
            state_dir: tmp.join("state"),
            dest: tmp.join("dest"),
            limits: limits(MAX_PAYLOAD),
            archive: Default::default(),
            hooks: None,
        },
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::UnsupportedVersion);
    match &decode_all(&out)[..] {
        [Frame::Error { code, .. }] => assert_eq!(code, "unsupported_version"),
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn reject_malformed_headers() {
    let cases = [
        "not json",
        "[1,2]",
        r#"{"v":1}"#,
        r#"{"v":1,"type":"nope"}"#,
        r#"{"v":1,"type":"ack","transfer_id":"../x","committed_offset":1}"#,
        r#"{"v":1,"type":"ack","transfer_id":"..","committed_offset":1}"#,
        r#"{"v":1,"type":"finish","transfer_id":"t","length":1,"sha256":"ABC"}"#,
        r#"{"v":1,"type":"open","transfer_id":"t","direction":"sideways","session_id":"s","member_id":"m","lease_generation":1,"artifact":"a","max_payload":1}"#,
        r#"{"v":1,"type":"open","transfer_id":"t","direction":"upload","session_id":"s/x","member_id":"m","lease_generation":1,"artifact":"a","max_payload":1}"#,
        r#"{"v":1,"type":"open","transfer_id":"t","direction":"upload","session_id":"s","member_id":"m","lease_generation":1,"artifact":"a","max_payload":0}"#,
    ];
    for hdr in cases {
        let mut r = FrameReader::with_max_payload(Cursor::new(raw(hdr, b"")), MAX_PAYLOAD);
        assert_eq!(
            r.read_frame().unwrap_err().code,
            ErrorCode::Protocol,
            "{hdr}"
        );
    }
}

#[test]
fn version_handshake() {
    let out = Command::new(BIN).arg("version").output().unwrap();
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert_eq!(text.lines().count(), 1);
    let v: serde_json::Value = serde_json::from_str(text.trim_end()).unwrap();
    assert_eq!(v["name"], "gf-transfer");
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["protocol"], 1);

    let bad = Command::new(BIN).arg("bogus").output().unwrap();
    assert_eq!(bad.status.code(), Some(2));
    assert!(bad.stdout.is_empty());
}

/// L28: a zero idle or extraction timeout is a usage error (exit 2), not a
/// helper that gives up immediately.
#[test]
fn zero_timeouts_are_usage_errors() {
    let receive = |extract: &str, idle: &str| {
        Command::new(BIN)
            .arg("receive")
            .args(["--state-dir", "/nonexistent/s", "--dest", "/nonexistent/d"])
            .args(["--max-bytes", "1024", "--max-expanded-bytes", "1024"])
            .args(["--max-entries", "10", "--extract-timeout-ms", extract])
            .args([
                "--idle-timeout-ms",
                idle,
                "--deadline-unix-ms",
                "99999999999999",
            ])
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap()
    };
    for (extract, idle, flag) in [
        ("0", "1000", "extract-timeout-ms"),
        ("1000", "0", "idle-timeout-ms"),
    ] {
        let out = receive(extract, idle);
        assert_eq!(out.status.code(), Some(2), "{flag}=0 must be refused");
        assert!(out.stdout.is_empty());
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains(flag), "{err}");
    }
    let send = Command::new(BIN)
        .arg("send")
        .args([
            "--state-dir",
            "/nonexistent/s",
            "--source",
            "/nonexistent/a.jsonl",
        ])
        .args(["--max-bytes", "1024", "--idle-timeout-ms", "0"])
        .args(["--deadline-unix-ms", "99999999999999"])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(send.status.code(), Some(2));
}
