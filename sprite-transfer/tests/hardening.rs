//! Stdout watchdog, report-name filtering in `collect`, and no-follow
//! resolution of the `send --source` parent directories.

mod common;

use std::fs;
use std::io::BufReader;
use std::os::unix::fs::symlink;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use common::*;
use gf_transfer::collect::{collect, CollectConfig};
use gf_transfer::protocol::*;
use gf_transfer::send::Snapshot;
use gf_transfer::watchdog::WATCHDOG_EXIT_CODE;
use gf_transfer::ErrorCode;

const REPORT_CAP: u64 = 33_554_432;

fn wait_with_timeout(child: &mut Child, limit: Duration) -> std::process::ExitStatus {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if started.elapsed() >= limit {
            let _ = child.kill();
            panic!("helper did not exit within {limit:?}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Start `send` on a 4 MiB report, complete the handshake, then stop
/// reading stdout so the helper blocks writing its first 1 MiB chunk.
type Pipes = (
    FrameWriter<std::process::ChildStdin>,
    FrameReader<BufReader<std::process::ChildStdout>>,
);

fn blocked_send(tmp: &TempDir, idle_ms: u64, deadline: Duration) -> (Child, Pipes) {
    let reports = tmp.join("exec/reports");
    fs::create_dir_all(&reports).unwrap();
    let source = reports.join("big.jsonl");
    fs::write(&source, random_bytes(4 * 1024 * 1024, 9)).unwrap();
    let mut child = Command::new(BIN)
        .args(["send", "--state-dir"])
        .arg(tmp.join("state"))
        .arg("--source")
        .arg(&source)
        .args(["--max-bytes", &REPORT_CAP.to_string()])
        .args(["--idle-timeout-ms", &idle_ms.to_string()])
        .args(["--deadline-unix-ms", &deadline_ms(deadline).to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut w = FrameWriter::new(child.stdin.take().unwrap());
    let mut r =
        FrameReader::with_max_payload(BufReader::new(child.stdout.take().unwrap()), MAX_PAYLOAD);
    w.write_frame(&Frame::Open(Open::download(
        &download_key("t-blocked", "big.jsonl"),
        MAX_PAYLOAD,
    )))
    .unwrap();
    assert!(matches!(r.read_frame().unwrap(), Some(Frame::Ready(_))));
    w.write_frame(&Frame::Ready(Ready {
        transfer_id: "t-blocked".into(),
        committed_offset: Some(0),
        length: None,
        sha256: None,
        max_payload: MAX_PAYLOAD,
        completed: None,
    }))
    .unwrap();
    // Keep stdin open and stdout unread (but not closed).
    (child, (w, r))
}

fn stderr_of(child: &mut Child) -> String {
    let mut s = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut s).unwrap();
    s
}

#[test]
fn watchdog_ends_helper_blocked_writing_stdout_after_idle_timeout() {
    let tmp = TempDir::new("wd-idle");
    let (mut child, _pipes) = blocked_send(&tmp, 300, Duration::from_secs(60));
    let started = Instant::now();
    let status = wait_with_timeout(&mut child, Duration::from_secs(10));
    assert_eq!(status.code(), Some(WATCHDOG_EXIT_CODE));
    assert!(started.elapsed() >= Duration::from_millis(200));
    assert!(stderr_of(&mut child).contains("idle_timeout"));
}

#[test]
fn watchdog_ends_helper_blocked_writing_stdout_at_deadline() {
    let tmp = TempDir::new("wd-deadline");
    let (mut child, _pipes) = blocked_send(&tmp, 60_000, Duration::from_millis(1500));
    let status = wait_with_timeout(&mut child, Duration::from_secs(15));
    assert_eq!(status.code(), Some(WATCHDOG_EXIT_CODE));
    assert!(stderr_of(&mut child).contains("deadline"));
}

/// A slow reader that keeps draining stdout must not trip the watchdog even
/// though each 1 MiB chunk takes longer than the idle timeout to write.
#[test]
fn watchdog_counts_partial_write_progress() {
    let tmp = TempDir::new("wd-slow");
    let reports = tmp.join("exec/reports");
    fs::create_dir_all(&reports).unwrap();
    let data = random_bytes(2 * 1024 * 1024, 10);
    let source = reports.join("slow.jsonl");
    fs::write(&source, &data).unwrap();
    let mut child = Command::new(BIN)
        .args(["send", "--state-dir"])
        .arg(tmp.join("state"))
        .arg("--source")
        .arg(&source)
        .args(["--max-bytes", &REPORT_CAP.to_string()])
        .args(["--idle-timeout-ms", "400"])
        .args([
            "--deadline-unix-ms",
            &deadline_ms(Duration::from_secs(60)).to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut w = FrameWriter::new(child.stdin.take().unwrap());
    let stdout = child.stdout.take().unwrap();
    // Drain 64 KiB every 100 ms: one 1 MiB chunk takes ~1.6 s.
    struct Slow<R>(R);
    impl<R: std::io::Read> std::io::Read for Slow<R> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            std::thread::sleep(Duration::from_millis(100));
            let n = buf.len().min(64 * 1024);
            self.0.read(&mut buf[..n])
        }
    }
    let mut r = FrameReader::with_max_payload(Slow(stdout), MAX_PAYLOAD);
    w.write_frame(&Frame::Open(Open::download(
        &download_key("t-slow", "slow.jsonl"),
        MAX_PAYLOAD,
    )))
    .unwrap();
    assert!(matches!(r.read_frame().unwrap(), Some(Frame::Ready(_))));
    w.write_frame(&Frame::Ready(Ready {
        transfer_id: "t-slow".into(),
        committed_offset: Some(0),
        length: None,
        sha256: None,
        max_payload: MAX_PAYLOAD,
        completed: None,
    }))
    .unwrap();
    let mut got = Vec::new();
    loop {
        match r.read_frame().unwrap() {
            Some(Frame::Chunk { offset, data, .. }) => {
                assert_eq!(offset, got.len() as u64);
                got.extend_from_slice(&data);
                w.write_frame(&Frame::Ack {
                    transfer_id: "t-slow".into(),
                    committed_offset: got.len() as u64,
                })
                .unwrap();
            }
            Some(Frame::Finish { length, sha256, .. }) => {
                w.write_frame(&Frame::Complete {
                    transfer_id: "t-slow".into(),
                    length,
                    sha256,
                    extracted: None,
                })
                .unwrap();
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(got, data);
    let status = wait_with_timeout(&mut child, Duration::from_secs(10));
    assert!(status.success(), "{status:?}");
}

#[test]
fn collect_skips_report_names_the_helper_cannot_send() {
    let tmp = TempDir::new("collect-names");
    let outputs = tmp.join("outputs");
    fs::write(&outputs, b"").unwrap();
    let reports = tmp.join("reports");
    fs::create_dir(&reports).unwrap();
    fs::write(reports.join("ok-1.jsonl"), b"{}\n").unwrap();
    fs::write(reports.join("my report.jsonl"), b"{}\n").unwrap();
    fs::write(reports.join("caf\u{e9}.jsonl"), b"{}\n").unwrap();
    fs::write(reports.join(format!("{}.jsonl", "x".repeat(123))), b"").unwrap();
    fs::write(reports.join(format!("{}.jsonl", "y".repeat(122))), b"").unwrap();

    let mut config = CollectConfig::new(&outputs);
    config.report_dir = Some(reports.clone());
    let c = match collect(&config).unwrap() {
        Frame::Collect(c) => c,
        other => panic!("unexpected {other:?}"),
    };
    let names: Vec<_> = c.reports.iter().map(|r| r.name.as_str()).collect();
    let y = format!("{}.jsonl", "y".repeat(122));
    assert_eq!(names, ["ok-1.jsonl", y.as_str()]);
    assert_eq!(c.reports_skipped, 3);

    // The count survives the wire, and is omitted when zero.
    let f = Frame::Collect(c);
    let header = encode_header(&f);
    assert!(header.contains("\"reports_skipped\":3"), "{header}");
    let out = Command::new(BIN)
        .args(["collect", "--outputs"])
        .arg(&outputs)
        .arg("--report-dir")
        .arg(&reports)
        .output()
        .unwrap();
    assert!(out.status.success());
    match &decode_all(&out.stdout)[..] {
        [Frame::Collect(c)] => assert_eq!(c.reports_skipped, 3),
        other => panic!("unexpected {other:?}"),
    }
    fs::remove_file(reports.join("my report.jsonl")).unwrap();
    fs::remove_file(reports.join("caf\u{e9}.jsonl")).unwrap();
    fs::remove_file(reports.join(format!("{}.jsonl", "x".repeat(123)))).unwrap();
    let f = collect(&config).unwrap();
    let header = encode_header(&f);
    assert!(!header.contains("reports_skipped"), "{header}");
}

#[test]
fn send_source_does_not_follow_symlinked_parent_directories() {
    let tmp = TempDir::new("srclink");
    let elsewhere = tmp.join("elsewhere");
    fs::create_dir(&elsewhere).unwrap();
    fs::write(elsewhere.join("a.jsonl"), b"{\"secret\":1}\n").unwrap();

    // exec/reports -> elsewhere
    fs::create_dir(tmp.join("exec")).unwrap();
    symlink(&elsewhere, tmp.join("exec/reports")).unwrap();
    let err = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-1", "a.jsonl"),
        &tmp.join("exec/reports/a.jsonl"),
        REPORT_CAP,
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::SourceRejected);

    // exec2 -> exec3 (which holds a real reports/ dir)
    fs::create_dir_all(tmp.join("exec3/reports")).unwrap();
    fs::write(tmp.join("exec3/reports/a.jsonl"), b"{}\n").unwrap();
    symlink(tmp.join("exec3"), tmp.join("exec2")).unwrap();
    let err = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-2", "a.jsonl"),
        &tmp.join("exec2/reports/a.jsonl"),
        REPORT_CAP,
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::SourceRejected);

    // The real path works.
    let snap = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-3", "a.jsonl"),
        &tmp.join("exec3/reports/a.jsonl"),
        REPORT_CAP,
    )
    .unwrap();
    assert_eq!(snap.meta().length, 3);

    // A reports path that is a regular file is rejected, not an I/O error.
    fs::create_dir(tmp.join("exec4")).unwrap();
    fs::write(tmp.join("exec4/reports"), b"").unwrap();
    let err = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-4", "a.jsonl"),
        &tmp.join("exec4/reports/a.jsonl"),
        REPORT_CAP,
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::SourceRejected);
}
