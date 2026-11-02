mod common;

use std::io::{BufReader, Cursor};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use common::*;
use gf_transfer::fsutil::sha256;
use gf_transfer::protocol::*;
use gf_transfer::receive::{run_receive, ReceiveConfig};
use gf_transfer::state::{ReceiveState, Receiver, ARTIFACT, PART, SIDECAR};
use gf_transfer::{ErrorCode, FailPoint};

const CHUNK: usize = 4;

fn data() -> Vec<u8> {
    random_bytes(18, 7) // 4 full chunks + a 2-byte tail
}

fn commit(rx: &mut Receiver, data: &[u8], from: usize, to: usize) -> u64 {
    let mut off = from;
    let mut last = rx.committed_offset();
    while off < to {
        let end = (off + CHUNK).min(data.len());
        last = rx
            .commit_chunk(off as u64, &data[off..end], &sha256(&data[off..end]))
            .unwrap();
        assert_eq!(last, end as u64);
        off = end;
    }
    last
}

fn part_len(rx_dir: &Path) -> u64 {
    std::fs::metadata(rx_dir.join(PART)).unwrap().len()
}

#[test]
fn resume_after_lost_ack() {
    let tmp = TempDir::new("lost-ack");
    let data = data();
    let meta = upload_meta("t-lost", &data);
    {
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        assert_eq!(rx.committed_offset(), 0);
        commit(&mut rx, &data, 0, 8);
        // The ack for offset 8 is "lost": the process disappears here.
    }
    let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(
        rx.committed_offset(),
        8,
        "reopen reports the authoritative offset"
    );
    // A sender that never saw the ack resends offset 4: refused, no duplicate.
    let err = rx
        .commit_chunk(4, &data[4..8], &sha256(&data[4..8]))
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::BadOffset);
    commit(&mut rx, &data, 8, data.len());
    let done = rx.finish().unwrap();
    assert_eq!(std::fs::read(&done.path).unwrap(), data);
    assert_eq!(done.sha256, sha256(&data));
    assert_eq!(done.length, data.len() as u64);
}

#[test]
fn truncate_uncommitted_tail() {
    let data = data();
    // (failure point, committed offset expected after reopen)
    let cases = [
        (FailPoint::BeforeDataWrite, 4),
        (FailPoint::AfterDataWrite, 4),
        (FailPoint::AfterDataSync, 4),
        (FailPoint::AfterSidecarTemp, 4),
        // L29: the rename landed, so the new boundary is on disk; cleanup
        // must not truncate bytes the sidecar records as committed.
        (FailPoint::AfterSidecarRename, 8),
        (FailPoint::AfterSidecarCommit, 8),
    ];
    for (point, expect) in cases {
        let tmp = TempDir::new("tail");
        let meta = upload_meta("t-tail", &data);
        let hook = FailAt::new(point, 1); // second chunk
        let dir;
        {
            let mut rx = Receiver::open_with_hooks(
                tmp.path(),
                &meta,
                &limits(CHUNK as u64),
                Some(hook.clone()),
            )
            .unwrap();
            dir = rx.dir().to_path_buf();
            commit(&mut rx, &data, 0, 4);
            let err = rx
                .commit_chunk(4, &data[4..8], &sha256(&data[4..8]))
                .unwrap_err();
            assert!(hook.fired(), "{point:?}");
            assert_eq!(err.code, ErrorCode::Internal, "{point:?}");
            // A poisoned receiver refuses further work in this process.
            assert!(rx
                .commit_chunk(4, &data[4..8], &sha256(&data[4..8]))
                .is_err());
        }
        // Simulate a crash that left uncommitted bytes past the boundary.
        std::fs::OpenOptions::new()
            .append(true)
            .open(dir.join(PART))
            .and_then(|mut f| std::io::Write::write_all(&mut f, b"garbage-tail"))
            .unwrap();
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        assert_eq!(rx.committed_offset(), expect, "{point:?}");
        assert_eq!(
            part_len(&dir),
            expect,
            "{point:?}: tail truncated on reopen"
        );
        assert!(
            !dir.join(format!("{SIDECAR}.tmp")).exists() || point == FailPoint::AfterSidecarTemp
        );
        commit(&mut rx, &data, expect as usize, data.len());
        let done = rx.finish().unwrap();
        assert_eq!(std::fs::read(done.path).unwrap(), data, "{point:?}");
    }
}

#[test]
fn reject_metadata_change() {
    let tmp = TempDir::new("meta");
    let data = data();
    let meta = upload_meta("t-meta", &data);
    let dir = {
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        commit(&mut rx, &data, 0, 8);
        rx.dir().to_path_buf()
    };
    let sidecar_before = std::fs::read(dir.join(SIDECAR)).unwrap();
    let part_before = std::fs::read(dir.join(PART)).unwrap();

    let mut variants = vec![];
    let mut m = meta.clone();
    m.lease_generation += 1;
    variants.push(m);
    let mut m = meta.clone();
    m.session_id = "s-2".into();
    variants.push(m);
    let mut m = meta.clone();
    m.member_id = "m-2".into();
    variants.push(m);
    let mut m = meta.clone();
    m.artifact = "other.tar.gz".into();
    variants.push(m);
    let mut m = meta.clone();
    m.length += 1;
    variants.push(m);
    let mut m = meta.clone();
    m.sha256[0] ^= 1;
    variants.push(m);
    let mut m = meta.clone();
    m.direction = Direction::Download;
    variants.push(m);

    for v in variants {
        let err = Receiver::open(tmp.path(), &v, &limits(CHUNK as u64)).unwrap_err();
        assert_eq!(err.code, ErrorCode::MetadataMismatch, "{v:?}");
        assert_eq!(std::fs::read(dir.join(SIDECAR)).unwrap(), sidecar_before);
        assert_eq!(std::fs::read(dir.join(PART)).unwrap(), part_before);
    }
    let rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(rx.committed_offset(), 8);
}

#[test]
fn exclusive_writer() {
    let tmp = TempDir::new("excl");
    let data = data();
    let meta = upload_meta("t-excl", &data);
    let mut first = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    commit(&mut first, &data, 0, 4);
    let part_before = std::fs::read(first.part_path()).unwrap();

    let started = Instant::now();
    let err = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap_err();
    assert_eq!(err.code, ErrorCode::Busy);
    assert!(
        started.elapsed() >= Duration::from_millis(150),
        "waited for the idle timeout"
    );
    assert_eq!(std::fs::read(first.part_path()).unwrap(), part_before);
    assert_eq!(first.committed_offset(), 4);

    // The first owner continues unaffected; once it is gone the next one wins.
    commit(&mut first, &data, 4, 8);
    drop(first);
    let second = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(second.committed_offset(), 8);
}

#[test]
fn bad_chunk_does_not_advance() {
    let tmp = TempDir::new("badchunk");
    let data = data();
    let meta = upload_meta("t-bad", &data);
    let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    commit(&mut rx, &data, 0, 4);

    let chunk = &data[4..8];
    let mut wrong = sha256(chunk);
    wrong[31] ^= 0xff;
    assert_eq!(
        rx.commit_chunk(4, chunk, &wrong).unwrap_err().code,
        ErrorCode::BadChunk
    );
    assert_eq!(
        rx.commit_chunk(8, chunk, &sha256(chunk)).unwrap_err().code,
        ErrorCode::BadOffset
    );
    assert_eq!(
        rx.commit_chunk(0, &data[0..4], &sha256(&data[0..4]))
            .unwrap_err()
            .code,
        ErrorCode::BadOffset
    );
    let five = &data[4..9];
    assert_eq!(
        rx.commit_chunk(4, five, &sha256(five)).unwrap_err().code,
        ErrorCode::TooLarge
    );
    assert_eq!(
        rx.commit_chunk(4, &[], &sha256(&[])).unwrap_err().code,
        ErrorCode::Protocol
    );
    // Past the declared length.
    let mut rx2_meta = upload_meta("t-bad2", &data[..6]);
    rx2_meta.sha256 = sha256(&data[..6]);
    let mut rx2 = Receiver::open(tmp.path(), &rx2_meta, &limits(CHUNK as u64)).unwrap();
    commit(&mut rx2, &data[..6], 0, 4);
    assert_eq!(
        rx2.commit_chunk(4, chunk, &sha256(chunk)).unwrap_err().code,
        ErrorCode::BadOffset
    );
    // Finish before all data is committed.
    assert_eq!(rx.finish().unwrap_err().code, ErrorCode::BadOffset);

    assert_eq!(rx.committed_offset(), 4);
    assert_eq!(part_len(rx.dir()), 4);
    // Validation failures do not poison the receiver.
    commit(&mut rx, &data, 4, data.len());
    assert_eq!(std::fs::read(rx.finish().unwrap().path).unwrap(), data);
}

#[test]
fn bad_final_hash_never_publishes() {
    let tmp = TempDir::new("badfinal");
    let data = data();
    let mut meta = upload_meta("t-final", &data);
    meta.sha256 = sha256(b"something else entirely");
    let dir = {
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        commit(&mut rx, &data, 0, data.len());
        let err = rx.finish().unwrap_err();
        assert_eq!(err.code, ErrorCode::RestartRequired);
        assert!(!rx.artifact_path().exists());
        rx.dir().to_path_buf()
    };
    assert!(!dir.join(ARTIFACT).exists());
    assert!(!dir.join(PART).exists());
    let rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(rx.committed_offset(), 0, "partial state invalidated");
    assert_eq!(rx.state(), ReceiveState::Receiving);
}

#[test]
fn finish_reply_loss_is_idempotent() {
    let tmp = TempDir::new("idem");
    let data = data();
    let meta = upload_meta("t-idem", &data);
    let (first, ino) = {
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        commit(&mut rx, &data, 0, data.len());
        let done = rx.finish().unwrap();
        // Repeated finish in-process returns the same result.
        assert_eq!(rx.finish().unwrap(), done);
        let ino = std::fs::metadata(&done.path).unwrap().ino();
        (done, ino)
        // The complete reply is lost here.
    };
    let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(rx.state(), ReceiveState::Published);
    assert_eq!(rx.committed_offset(), data.len() as u64);
    let again = rx.finish().unwrap();
    assert_eq!(again, first);
    assert_eq!(
        std::fs::metadata(&again.path).unwrap().ino(),
        ino,
        "not republished"
    );
    assert!(rx.commit_chunk(0, &data[..4], &sha256(&data[..4])).is_err());
}

#[test]
fn finish_reply_loss_does_not_extract_twice() {
    let tmp = TempDir::new("idem-ws");
    let archive = RawTar::new()
        .file("hello.txt", b"hello")
        .file("b.txt", b"b")
        .gz();
    let meta = upload_meta("t-ws", &archive);
    let config = ReceiveConfig {
        state_dir: tmp.join("state"),
        dest: tmp.join("ws"),
        limits: limits(MAX_PAYLOAD),
        archive: Default::default(),
        hooks: None,
    };
    let input = frame_bytes(&upload_frames(&meta, &archive, 64, 0, true));
    let mut out = Vec::new();
    run_receive(Cursor::new(input), &mut out, config.clone()).unwrap();
    let frames = decode_all(&out);
    assert!(matches!(
        frames.last(),
        Some(Frame::Complete {
            extracted: Some(true),
            ..
        })
    ));
    assert_eq!(std::fs::read(tmp.join("ws/hello.txt")).unwrap(), b"hello");

    // The complete reply was lost; the server retries open + finish.
    std::fs::remove_file(tmp.join("ws/hello.txt")).unwrap();
    let retry = frame_bytes(&[
        Frame::Open(Open::upload(&meta, MAX_PAYLOAD)),
        Frame::Finish {
            transfer_id: meta.transfer_id.clone(),
            length: meta.length,
            sha256: meta.sha256,
        },
    ]);
    let mut out = Vec::new();
    run_receive(Cursor::new(retry), &mut out, config).unwrap();
    let frames = decode_all(&out);
    match &frames[..] {
        [Frame::Ready(r), Frame::Complete {
            extracted, sha256, ..
        }] => {
            assert_eq!(r.completed, Some(true));
            assert_eq!(r.committed_offset, Some(meta.length));
            assert_eq!(*extracted, Some(true));
            assert_eq!(*sha256, meta.sha256);
        }
        other => panic!("unexpected {other:?}"),
    }
    assert!(
        !tmp.join("ws/hello.txt").exists(),
        "workspace was not extracted again"
    );
}

#[test]
fn recover_after_publish_before_receipt() {
    let data = data();
    for point in [FailPoint::AfterPublishRename, FailPoint::AfterPublishRecord] {
        let tmp = TempDir::new("publish");
        let meta = upload_meta("t-pub", &data);
        {
            let hook = FailAt::new(point, 0);
            let mut rx = Receiver::open_with_hooks(
                tmp.path(),
                &meta,
                &limits(CHUNK as u64),
                Some(hook.clone()),
            )
            .unwrap();
            commit(&mut rx, &data, 0, data.len());
            assert!(rx.finish().is_err());
            assert!(hook.fired());
        }
        let mut rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
        assert_eq!(rx.state(), ReceiveState::Published, "{point:?}");
        assert_eq!(rx.committed_offset(), data.len() as u64);
        let done = rx.finish().unwrap();
        assert_eq!(std::fs::read(&done.path).unwrap(), data);
        assert_eq!(done.sha256, meta.sha256);
    }

    // A crash after the rename where the published bytes are damaged is not
    // treated as finished: state is invalidated and restart is required.
    let tmp = TempDir::new("publish-bad");
    let meta = upload_meta("t-pub", &data);
    let dir = {
        let hook = FailAt::new(FailPoint::AfterPublishRename, 0);
        let mut rx =
            Receiver::open_with_hooks(tmp.path(), &meta, &limits(CHUNK as u64), Some(hook))
                .unwrap();
        commit(&mut rx, &data, 0, data.len());
        assert!(rx.finish().is_err());
        rx.dir().to_path_buf()
    };
    std::fs::write(dir.join(ARTIFACT), b"corrupted").unwrap();
    let err = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap_err();
    assert_eq!(err.code, ErrorCode::RestartRequired);
    let rx = Receiver::open(tmp.path(), &meta, &limits(CHUNK as u64)).unwrap();
    assert_eq!(rx.committed_offset(), 0);
}

fn spawn_receive(state: &Path, dest: &Path, idle_ms: u64) -> std::process::Child {
    Command::new(BIN)
        .args(["receive", "--state-dir"])
        .arg(state)
        .arg("--dest")
        .arg(dest)
        .args(["--max-bytes", "1048576", "--max-expanded-bytes", "1048576"])
        .args(["--max-entries", "100", "--extract-timeout-ms", "5000"])
        .args(["--idle-timeout-ms", &idle_ms.to_string()])
        .args([
            "--deadline-unix-ms",
            &deadline_ms(Duration::from_secs(60)).to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn wait_with_timeout(child: &mut std::process::Child, limit: Duration) -> std::process::ExitStatus {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(started.elapsed() < limit, "helper did not exit in time");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn stale_lock_released_after_idle_timeout() {
    let tmp = TempDir::new("stale");
    let archive = RawTar::new().file("f", b"data").gz();
    let meta = upload_meta("t-stale", &archive);

    // No frames at all, stdin held open: exits after the idle timeout.
    let mut idle = spawn_receive(&tmp.join("state"), &tmp.join("ws"), 200);
    let started = Instant::now();
    let status = wait_with_timeout(&mut idle, Duration::from_secs(10));
    assert!(!status.success());
    assert!(started.elapsed() >= Duration::from_millis(150));
    let out = std::io::Read::bytes(idle.stdout.take().unwrap())
        .map(|b| b.unwrap())
        .collect::<Vec<_>>();
    match &decode_all(&out)[..] {
        [Frame::Error { code, .. }] => assert_eq!(code, "idle_timeout"),
        other => panic!("unexpected {other:?}"),
    }

    // Owner takes the lock, then the connection "drops" without EOF.
    let mut old = spawn_receive(&tmp.join("state"), &tmp.join("ws"), 1500);
    let mut w = FrameWriter::new(old.stdin.take().unwrap());
    let mut r =
        FrameReader::with_max_payload(BufReader::new(old.stdout.take().unwrap()), MAX_PAYLOAD);
    w.write_frame(&Frame::Open(Open::upload(&meta, MAX_PAYLOAD)))
        .unwrap();
    assert!(matches!(r.read_frame().unwrap(), Some(Frame::Ready(_))));
    w.write_frame(&Frame::chunk(&meta.transfer_id, 0, archive[..10].to_vec()))
        .unwrap();
    assert!(matches!(
        r.read_frame().unwrap(),
        Some(Frame::Ack {
            committed_offset: 10,
            ..
        })
    ));

    // While it is alive, a replacement waits (bounded) and reports busy.
    let mut competitor = spawn_receive(&tmp.join("state"), &tmp.join("ws"), 50);
    let mut cw = FrameWriter::new(competitor.stdin.take().unwrap());
    cw.write_frame(&Frame::Open(Open::upload(&meta, MAX_PAYLOAD)))
        .unwrap();
    let mut cr = FrameReader::with_max_payload(competitor.stdout.take().unwrap(), MAX_PAYLOAD);
    match cr.read_frame().unwrap() {
        Some(Frame::Error { code, .. }) => assert_eq!(code, "busy"),
        other => panic!("unexpected {other:?}"),
    }
    assert!(!wait_with_timeout(&mut competitor, Duration::from_secs(10)).success());

    // The stale owner (stdin still open, writer `w` alive) exits on idle.
    let status = wait_with_timeout(&mut old, Duration::from_secs(10));
    assert!(!status.success());
    match r.read_frame().unwrap() {
        Some(Frame::Error { code, .. }) => assert_eq!(code, "idle_timeout"),
        other => panic!("unexpected {other:?}"),
    }
    drop(w);

    // A new invocation acquires the lock and resumes at the committed offset.
    let mut new = spawn_receive(&tmp.join("state"), &tmp.join("ws"), 5000);
    let mut w = FrameWriter::new(new.stdin.take().unwrap());
    let mut r = FrameReader::with_max_payload(new.stdout.take().unwrap(), MAX_PAYLOAD);
    w.write_frame(&Frame::Open(Open::upload(&meta, MAX_PAYLOAD)))
        .unwrap();
    match r.read_frame().unwrap() {
        Some(Frame::Ready(rd)) => assert_eq!(rd.committed_offset, Some(10)),
        other => panic!("unexpected {other:?}"),
    }
    w.write_frame(&Frame::chunk(&meta.transfer_id, 10, archive[10..].to_vec()))
        .unwrap();
    assert!(matches!(r.read_frame().unwrap(), Some(Frame::Ack { .. })));
    w.write_frame(&Frame::Finish {
        transfer_id: meta.transfer_id.clone(),
        length: meta.length,
        sha256: meta.sha256,
    })
    .unwrap();
    assert!(matches!(
        r.read_frame().unwrap(),
        Some(Frame::Complete { .. })
    ));
    assert!(wait_with_timeout(&mut new, Duration::from_secs(10)).success());
    assert_eq!(std::fs::read(tmp.join("ws/f")).unwrap(), b"data");
}

#[test]
fn deadline_terminates_helper() {
    let tmp = TempDir::new("deadline");
    let mut child = Command::new(BIN)
        .args(["receive", "--state-dir"])
        .arg(tmp.join("state"))
        .arg("--dest")
        .arg(tmp.join("ws"))
        .args([
            "--max-bytes",
            "10",
            "--max-expanded-bytes",
            "10",
            "--max-entries",
            "1",
        ])
        .args(["--extract-timeout-ms", "10", "--idle-timeout-ms", "60000"])
        .args([
            "--deadline-unix-ms",
            &deadline_ms(Duration::from_millis(300)).to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take();
    let status = wait_with_timeout(&mut child, Duration::from_secs(10));
    assert!(!status.success());
    let mut r = FrameReader::with_max_payload(child.stdout.take().unwrap(), MAX_PAYLOAD);
    match r.read_frame().unwrap() {
        Some(Frame::Error { code, .. }) => assert_eq!(code, "deadline"),
        other => panic!("unexpected {other:?}"),
    }
}

fn negotiate(config_max: u64, proposed: u64) -> (Vec<Frame>, gf_transfer::Result<()>) {
    let tmp = TempDir::new("negotiate");
    let data = random_bytes(2 * 1024 * 1024, 1);
    let meta = upload_meta("t-neg", &data);
    let mut open = Open::upload(&meta, proposed);
    open.max_payload = proposed;
    let input = frame_bytes(&[Frame::Open(open)]);
    let mut out = Vec::new();
    let res = run_receive(
        Cursor::new(input),
        &mut out,
        ReceiveConfig {
            state_dir: tmp.join("state"),
            dest: tmp.join("ws"),
            limits: limits(config_max),
            archive: Default::default(),
            hooks: None,
        },
    );
    (decode_all(&out), res)
}

#[test]
fn negotiate_max_payload() {
    for (config_max, proposed, expect) in [
        (MAX_PAYLOAD, 4096, 4096),
        (MAX_PAYLOAD, 2 * MAX_PAYLOAD, MAX_PAYLOAD),
        (65_536, MAX_PAYLOAD, 65_536),
        (65_536, 1, 1),
    ] {
        let (frames, _) = negotiate(config_max, proposed);
        match &frames[0] {
            Frame::Ready(r) => assert_eq!(r.max_payload, expect, "{config_max}/{proposed}"),
            other => panic!("unexpected {other:?}"),
        }
    }
    let (frames, res) = negotiate(MAX_PAYLOAD, 0);
    assert_eq!(res.unwrap_err().code, ErrorCode::Protocol);
    assert!(matches!(&frames[..], [Frame::Error { .. }]));

    // A chunk above the negotiated maximum is refused before it is written.
    let tmp = TempDir::new("negotiate-chunk");
    let data = random_bytes(10_000, 2);
    let meta = upload_meta("t-neg2", &data);
    let input = frame_bytes(&[
        Frame::Open(Open::upload(&meta, 4096)),
        Frame::chunk(&meta.transfer_id, 0, data[..4097].to_vec()),
    ]);
    let mut out = Vec::new();
    let err = run_receive(
        Cursor::new(input),
        &mut out,
        ReceiveConfig {
            state_dir: tmp.join("state"),
            dest: tmp.join("ws"),
            limits: limits(MAX_PAYLOAD),
            archive: Default::default(),
            hooks: None,
        },
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::TooLarge);
    match &decode_all(&out)[..] {
        [Frame::Ready(r), Frame::Error { code, .. }] => {
            assert_eq!(r.max_payload, 4096);
            assert_eq!(code, "too_large");
        }
        other => panic!("unexpected {other:?}"),
    }
    let rx = Receiver::open(&tmp.join("state"), &meta, &limits(MAX_PAYLOAD)).unwrap();
    assert_eq!(rx.committed_offset(), 0);
}
