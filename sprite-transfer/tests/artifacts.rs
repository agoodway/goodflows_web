mod common;

use std::fs;
use std::io::{BufReader, Cursor, Read, Write};
use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use common::*;
use gf_transfer::archive::{validate_and_extract, ArchiveLimits};
use gf_transfer::collect::{collect, CollectConfig};
use gf_transfer::fsutil::sha256;
use gf_transfer::protocol::*;
use gf_transfer::receive::{run_receive, ReceiveConfig};
use gf_transfer::send::{run_send, serve, SendConfig, Snapshot, SnapshotOptions, SNAPSHOT_META};
use gf_transfer::state::{ReceiveState, Receiver};
use gf_transfer::{ErrorCode, FailPoint, FailPoints};
use tar::EntryType;

const REPORT_CAP: u64 = 33_554_432;

fn receive_config(tmp: &TempDir) -> ReceiveConfig {
    ReceiveConfig {
        state_dir: tmp.join("state"),
        dest: tmp.join("ws"),
        limits: limits(MAX_PAYLOAD),
        archive: ArchiveLimits::default(),
        hooks: None,
    }
}

fn extract(archive: &[u8], dest: &Path) -> gf_transfer::Result<()> {
    extract_with(archive, dest, &ArchiveLimits::default())
}

fn extract_with(archive: &[u8], dest: &Path, limits: &ArchiveLimits) -> gf_transfer::Result<()> {
    let path = dest.with_extension("archive");
    fs::write(&path, archive).unwrap();
    validate_and_extract(&path, dest, limits)
}

#[test]
fn workspace_not_ready_before_finish() {
    let tmp = TempDir::new("notready");
    let archive = RawTar::new()
        .file("a.txt", b"alpha")
        .dir("d")
        .file("d/b.txt", b"beta")
        .gz();
    let meta = upload_meta("t-ws", &archive);
    let config = receive_config(&tmp);

    // All chunks delivered, but no finish: input ends.
    let mut out = Vec::new();
    let input = frame_bytes(&upload_frames(&meta, &archive, 16, 0, false));
    let err = run_receive(Cursor::new(input), &mut out, config.clone()).unwrap_err();
    assert_eq!(err.code, ErrorCode::Protocol);
    assert!(!decode_all(&out)
        .iter()
        .any(|f| matches!(f, Frame::Complete { .. })));
    assert!(
        tree(&tmp.join("ws")).is_empty(),
        "nothing extracted before finish"
    );
    {
        let rx = Receiver::open(&config.state_dir, &meta, &config.limits).unwrap();
        assert_eq!(rx.state(), ReceiveState::Receiving);
        assert_eq!(rx.committed_offset(), meta.length);
    }

    // Resume: open (offset == length) then finish -> verified + extracted.
    let mut out = Vec::new();
    let input = frame_bytes(&upload_frames(&meta, &archive, 16, archive.len(), true));
    run_receive(Cursor::new(input), &mut out, config.clone()).unwrap();
    match &decode_all(&out)[..] {
        [Frame::Ready(r), Frame::Complete {
            extracted, length, ..
        }] => {
            assert_eq!(r.committed_offset, Some(meta.length));
            assert_eq!(r.completed, Some(false));
            assert_eq!(*extracted, Some(true));
            assert_eq!(*length, meta.length);
        }
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(fs::read(tmp.join("ws/d/b.txt")).unwrap(), b"beta");
    let rx = Receiver::open(&config.state_dir, &meta, &config.limits).unwrap();
    assert_eq!(rx.state(), ReceiveState::Extracted);
}

/// PAX extended-header records: `"<len> key=value\n"`, where `<len>` counts
/// the whole record including its own digits.
fn pax(records: &[(&str, &str)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (k, v) in records {
        let body = format!(" {k}={v}\n");
        let mut len = body.len() + 1;
        while format!("{len}{body}").len() != len {
            len += 1;
        }
        out.extend_from_slice(format!("{len}{body}").as_bytes());
    }
    out
}

#[test]
fn reject_archive_escape_and_special_entries() {
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("absolute path", RawTar::new().file("/etc/evil", b"x").gz()),
        ("dotdot", RawTar::new().file("../evil", b"x").gz()),
        (
            "nested dotdot",
            RawTar::new().file("a/../../evil", b"x").gz(),
        ),
        (
            "symlink escape",
            RawTar::new().symlink("l", "../outside").gz(),
        ),
        ("absolute symlink", RawTar::new().symlink("l", "/etc").gz()),
        (
            "link chain escape",
            RawTar::new()
                .dir("d")
                .symlink("d/up", "..")
                .symlink("l2", "d/up/..")
                .gz(),
        ),
        (
            "symlink dotdot through a missing dir",
            RawTar::new().symlink("a", "x/../..").gz(),
        ),
        (
            "late-bound chain escape via later link",
            RawTar::new().symlink("a", "x/../y").symlink("x", ".").gz(),
        ),
        (
            "duplicate path dir -> symlink",
            RawTar::new()
                .dir("d")
                .symlink("d", "sub")
                .file("d/f", b"x")
                .gz(),
        ),
        (
            "write through archive symlink",
            RawTar::new()
                .dir("sub")
                .symlink("l", "sub")
                .file("l/f", b"x")
                .gz(),
        ),
        (
            "duplicate file",
            RawTar::new().file("f", b"1").file("f", b"2").gz(),
        ),
        (
            "hardlink dotdot",
            RawTar::new().hardlink("h", "../etc/passwd").gz(),
        ),
        (
            "hardlink absolute",
            RawTar::new().hardlink("h", "/etc/passwd").gz(),
        ),
        ("hardlink missing", RawTar::new().hardlink("h", "nope").gz()),
        (
            "hardlink to symlink",
            RawTar::new().symlink("s", "t").hardlink("h", "s").gz(),
        ),
        (
            "hardlink through symlink",
            RawTar::new()
                .dir("real")
                .file("real/f", b"x")
                .symlink("l", "real")
                .hardlink("h", "l/f")
                .gz(),
        ),
        (
            "fifo",
            RawTar::new().entry("p", EntryType::Fifo, "", b"").gz(),
        ),
        (
            "char device",
            RawTar::new().entry("c", EntryType::Char, "", b"").gz(),
        ),
        (
            "block device",
            RawTar::new().entry("b", EntryType::Block, "", b"").gz(),
        ),
        (
            "not an archive",
            gzip(b"definitely not a tar archive, just some bytes"),
        ),
        // L20: path escapes carried in extension headers instead of the
        // ustar name/linkname fields.
        (
            "gnu long name dotdot",
            RawTar::new()
                .entry(
                    "././@LongLink",
                    EntryType::GNULongName,
                    "",
                    b"a/../../evil\0",
                )
                .file("x", b"x")
                .gz(),
        ),
        (
            "gnu long name absolute",
            RawTar::new()
                .entry("././@LongLink", EntryType::GNULongName, "", b"/etc/evil\0")
                .file("x", b"x")
                .gz(),
        ),
        (
            "gnu long link symlink escape",
            RawTar::new()
                .entry("././@LongLink", EntryType::GNULongLink, "", b"../../etc\0")
                .symlink("l", "t")
                .gz(),
        ),
        (
            "gnu long link hardlink escape",
            RawTar::new()
                .entry(
                    "././@LongLink",
                    EntryType::GNULongLink,
                    "",
                    b"../etc/passwd\0",
                )
                .hardlink("h", "t")
                .gz(),
        ),
        (
            "pax path dotdot",
            RawTar::new()
                .entry("pax", EntryType::XHeader, "", &pax(&[("path", "../evil")]))
                .file("x", b"x")
                .gz(),
        ),
        (
            "pax linkpath absolute",
            RawTar::new()
                .entry("pax", EntryType::XHeader, "", &pax(&[("linkpath", "/etc")]))
                .symlink("l", "t")
                .gz(),
        ),
        (
            "pax linkpath hardlink escape",
            RawTar::new()
                .entry("pax", EntryType::XHeader, "", &pax(&[("linkpath", "../x")]))
                .hardlink("h", "t")
                .gz(),
        ),
        (
            "global pax path",
            RawTar::new()
                .entry(
                    "pax",
                    EntryType::XGlobalHeader,
                    "",
                    &pax(&[("path", "evil")]),
                )
                .file("x", b"x")
                .gz(),
        ),
        (
            "global pax linkpath",
            RawTar::new()
                .entry(
                    "pax",
                    EntryType::XGlobalHeader,
                    "",
                    &pax(&[("linkpath", "/etc")]),
                )
                .symlink("l", "t")
                .gz(),
        ),
        (
            "dangling gnu long name",
            RawTar::new()
                .file("ok", b"x")
                .entry("././@LongLink", EntryType::GNULongName, "", b"../evil\0")
                .gz(),
        ),
    ];
    for (name, archive) in cases {
        let tmp = TempDir::new("escape");
        let dest = tmp.join("ws");
        fs::create_dir(&dest).unwrap();
        let err = extract(&archive, &dest).unwrap_err();
        assert_eq!(err.code, ErrorCode::ArchiveRejected, "{name}: {err}");
        assert!(tree(&dest).is_empty(), "{name}: nothing written");
        assert!(!tmp.join("evil").exists() && !tmp.path().parent().unwrap().join("evil").exists());
    }
}

/// Controls for the L20 cases: the same extension headers with confined
/// values are accepted, so the rejections above come from the values.
#[test]
fn confined_extension_header_paths_are_accepted() {
    let cases: Vec<(&str, Vec<u8>, &str)> = vec![
        (
            "gnu long name",
            RawTar::new()
                .entry(
                    "././@LongLink",
                    EntryType::GNULongName,
                    "",
                    b"a/long-name\0",
                )
                .file("x", b"x")
                .gz(),
            "a/long-name",
        ),
        (
            "gnu long link",
            RawTar::new()
                .file("t", b"x")
                .entry("././@LongLink", EntryType::GNULongLink, "", b"t\0")
                .symlink("l", "ignored")
                .gz(),
            "l",
        ),
        (
            "pax path",
            RawTar::new()
                .entry("pax", EntryType::XHeader, "", &pax(&[("path", "p/q")]))
                .file("x", b"x")
                .gz(),
            "p/q",
        ),
        (
            "pax linkpath",
            RawTar::new()
                .file("t", b"x")
                .entry("pax", EntryType::XHeader, "", &pax(&[("linkpath", "t")]))
                .hardlink("h", "ignored")
                .gz(),
            "h",
        ),
        (
            "global pax unrelated key",
            RawTar::new()
                .entry(
                    "pax",
                    EntryType::XGlobalHeader,
                    "",
                    &pax(&[("comment", "hi")]),
                )
                .file("x", b"x")
                .gz(),
            "x",
        ),
    ];
    for (name, archive, expect) in cases {
        let tmp = TempDir::new("ext-ok");
        let dest = tmp.join("ws");
        fs::create_dir(&dest).unwrap();
        extract(&archive, &dest).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(
            fs::symlink_metadata(dest.join(expect)).is_ok(),
            "{name}: {expect} extracted"
        );
    }
}

#[test]
fn valid_confined_symlinks_and_nested_archive_accepted() {
    let inner = RawTar::new().file("/etc/evil", b"x").symlink("l", "/").gz();
    let long = format!("deep/{}/file.txt", "n".repeat(150));
    let archive = RawTar::new()
        .dir("./")
        .dir("src")
        .file("src/a.txt", b"A")
        .entry("src/run.sh", EntryType::Regular, "", b"#!/bin/sh\n")
        .symlink("link", "src/a.txt")
        .symlink("src/self", "../src")
        .symlink("dangling", "missing/inside")
        .hardlink("src/b.txt", "src/a.txt")
        .file("vendor/dep.tar.gz", &inner)
        .long_file(&long, b"long")
        .gz();
    let tmp = TempDir::new("valid");
    let dest = tmp.join("ws");
    extract(&archive, &dest).unwrap();
    assert_eq!(fs::read(dest.join("src/a.txt")).unwrap(), b"A");
    assert_eq!(fs::read(dest.join("src/b.txt")).unwrap(), b"A");
    assert_eq!(
        fs::read_link(dest.join("link")).unwrap(),
        Path::new("src/a.txt")
    );
    assert_eq!(fs::read(dest.join("link")).unwrap(), b"A");
    assert_eq!(
        fs::read_link(dest.join("src/self")).unwrap(),
        Path::new("../src")
    );
    assert_eq!(fs::read(dest.join("vendor/dep.tar.gz")).unwrap(), inner);
    assert_eq!(fs::read(dest.join(&long)).unwrap(), b"long");
    assert!(!dest.join("etc").exists());

    // Uncompressed tar is accepted as well.
    let tmp2 = TempDir::new("plain");
    extract(&RawTar::new().file("x", b"y").tar(), &tmp2.join("ws")).unwrap();
    assert_eq!(fs::read(tmp2.join("ws/x")).unwrap(), b"y");
}

#[test]
fn preexisting_destination_symlinks_are_not_followed() {
    let tmp = TempDir::new("prelink");
    let dest = tmp.join("ws");
    let outside = tmp.join("outside");
    fs::create_dir_all(&dest).unwrap();
    fs::create_dir_all(&outside).unwrap();
    symlink(&outside, dest.join("pre")).unwrap();
    symlink(outside.join("target.txt"), dest.join("file-link")).unwrap();

    let err = extract(&RawTar::new().file("pre/x", b"x").gz(), &dest).unwrap_err();
    assert_eq!(err.code, ErrorCode::ExtractFailed);
    assert!(!outside.join("x").exists());

    // A file entry over an existing symlink replaces the link itself.
    extract(&RawTar::new().file("file-link", b"mine").gz(), &dest).unwrap();
    assert!(!outside.join("target.txt").exists());
    assert!(fs::symlink_metadata(dest.join("file-link"))
        .unwrap()
        .is_file());
}

#[test]
fn expansion_limits() {
    let tmp = TempDir::new("limits");
    let archive = RawTar::new().file("a", b"12345").file("b", b"67890").gz();
    let limits = |bytes, entries, timeout| ArchiveLimits {
        max_expanded_bytes: bytes,
        max_entries: entries,
        timeout,
        hooks: None,
    };
    let ok = Duration::from_secs(30);
    let err = extract_with(&archive, &tmp.join("a"), &limits(9, 10, ok)).unwrap_err();
    assert_eq!(err.code, ErrorCode::ArchiveTooLarge);
    let err = extract_with(&archive, &tmp.join("b"), &limits(100, 1, ok)).unwrap_err();
    assert_eq!(err.code, ErrorCode::ArchiveTooLarge);
    let err = extract_with(&archive, &tmp.join("c"), &limits(100, 10, Duration::ZERO)).unwrap_err();
    assert_eq!(err.code, ErrorCode::Deadline);
    for d in ["a", "b", "c"] {
        assert!(tree(&tmp.join(d)).is_empty());
    }
    // Exactly at the limits is fine.
    extract_with(&archive, &tmp.join("d"), &limits(10, 2, ok)).unwrap();
    assert_eq!(fs::read(tmp.join("d/b")).unwrap(), b"67890");

    // Oversized extension headers are refused without buffering them.
    let mut long_name = RawTar::new();
    long_name.entry(
        "././@LongLink",
        EntryType::GNULongName,
        "",
        &vec![b'a'; 5000],
    );
    long_name.file("x", b"");
    let err = extract(&long_name.gz(), &tmp.join("e")).unwrap_err();
    assert_eq!(err.code, ErrorCode::ArchiveRejected);

    // Through the receive command: compressed size limit is too_large.
    let tmp2 = TempDir::new("limits-rx");
    let mut config = receive_config(&tmp2);
    config.limits.max_bytes = (archive.len() - 1) as u64;
    let meta = upload_meta("t-big", &archive);
    let mut out = Vec::new();
    let input = frame_bytes(&upload_frames(&meta, &archive, 1024, 0, true));
    assert_eq!(
        run_receive(Cursor::new(input), &mut out, config)
            .unwrap_err()
            .code,
        ErrorCode::TooLarge
    );
    assert!(matches!(&decode_all(&out)[..], [Frame::Error { code, .. }] if code == "too_large"));
}

#[test]
fn disk_full_does_not_complete() {
    // Approach: inject ENOSPC through the FailPoints hooks at the chunk data
    // write and at extraction file writes (no real filesystem is filled).
    let tmp = TempDir::new("diskfull");
    let archive = RawTar::new().file("a", &random_bytes(5000, 3)).gz();
    let meta = upload_meta("t-full", &archive);
    let chunk = 1024;
    let mut config = receive_config(&tmp);
    config.hooks = Some(FailAt::enospc(FailPoint::BeforeDataWrite, 2));
    let mut out = Vec::new();
    let input = frame_bytes(&upload_frames(&meta, &archive, chunk, 0, true));
    let err = run_receive(Cursor::new(input), &mut out, config).unwrap_err();
    assert_eq!(err.code, ErrorCode::DiskFull);
    let frames = decode_all(&out);
    assert!(!frames.iter().any(|f| matches!(f, Frame::Complete { .. })));
    assert!(matches!(frames.last(), Some(Frame::Error { code, .. }) if code == "disk_full"));
    assert_eq!(
        frames
            .iter()
            .filter(|f| matches!(f, Frame::Ack { .. }))
            .count(),
        2
    );
    let rx = Receiver::open(&tmp.join("state"), &meta, &limits(MAX_PAYLOAD)).unwrap();
    assert_eq!(rx.committed_offset(), 2 * chunk as u64);
    drop(rx);
    assert!(tree(&tmp.join("ws")).is_empty());

    // ENOSPC during extraction: disk_full, never marked extracted, and a
    // retry reports extract_failed instead of extracting again.
    let tmp = TempDir::new("diskfull-extract");
    let mut config = receive_config(&tmp);
    config.archive.hooks = Some(FailAt::enospc(FailPoint::ExtractWrite, 0));
    let mut out = Vec::new();
    let input = frame_bytes(&upload_frames(&meta, &archive, chunk, 0, true));
    let err = run_receive(Cursor::new(input), &mut out, config).unwrap_err();
    assert_eq!(err.code, ErrorCode::DiskFull);
    assert!(!decode_all(&out)
        .iter()
        .any(|f| matches!(f, Frame::Complete { .. })));
    {
        let rx = Receiver::open(&tmp.join("state"), &meta, &limits(MAX_PAYLOAD)).unwrap();
        assert_eq!(rx.state(), ReceiveState::ExtractFailed);
    }
    let mut out = Vec::new();
    let retry = frame_bytes(&upload_frames(&meta, &archive, chunk, archive.len(), true));
    let err = run_receive(Cursor::new(retry), &mut out, receive_config(&tmp)).unwrap_err();
    assert_eq!(err.code, ErrorCode::ExtractFailed);
    assert!(
        matches!(&decode_all(&out)[..], [Frame::Error { code, .. }] if code == "extract_failed")
    );
}

/// Drive `run_send` as the receiver: returns (offer, received bytes, result).
/// Stops (input EOF) after `max_acks` acknowledgements.
fn send_session(
    snapshot: Snapshot,
    from: u64,
    max_acks: usize,
    chunk: u64,
) -> (Ready, Vec<u8>, gf_transfer::Result<()>) {
    let meta = snapshot.meta().clone();
    let key = meta.key();
    let mut input = vec![
        Frame::Open(Open::download(&key, chunk)),
        Frame::Ready(Ready {
            transfer_id: key.transfer_id.clone(),
            committed_offset: Some(from),
            length: None,
            sha256: None,
            max_payload: chunk,
            completed: None,
        }),
    ];
    let mut off = from;
    let mut acks = 0;
    while off < meta.length && acks < max_acks {
        off = (off + chunk).min(meta.length);
        input.push(Frame::Ack {
            transfer_id: key.transfer_id.clone(),
            committed_offset: off,
        });
        acks += 1;
    }
    if off == meta.length && acks < max_acks {
        input.push(Frame::Complete {
            transfer_id: key.transfer_id.clone(),
            length: meta.length,
            sha256: meta.sha256,
            extracted: None,
        });
    }
    let mut out = Vec::new();
    let res = run_send(
        Cursor::new(frame_bytes(&input)),
        &mut out,
        snapshot,
        limits(chunk),
    );
    let frames = decode_all(&out);
    let offer = match &frames[0] {
        Frame::Ready(r) => r.clone(),
        other => panic!("unexpected {other:?}"),
    };
    let mut bytes = Vec::new();
    let mut expect_off = from;
    for f in &frames[1..] {
        if let Frame::Chunk {
            offset,
            data,
            sha256: s,
            ..
        } = f
        {
            assert_eq!(*offset, expect_off);
            assert_eq!(sha256(data), *s);
            expect_off += data.len() as u64;
            bytes.extend_from_slice(data);
        }
    }
    (offer, bytes, res)
}

struct MutateSource(std::path::PathBuf);

impl FailPoints for MutateSource {
    fn check(&self, point: FailPoint) -> std::io::Result<()> {
        if point == FailPoint::SnapshotAfterCopy {
            fs::OpenOptions::new()
                .append(true)
                .open(&self.0)?
                .write_all(b"more")?;
        }
        Ok(())
    }
}

#[test]
fn report_snapshot_resume_is_immutable() {
    let tmp = TempDir::new("snapshot");
    let source = tmp.join("a.jsonl");
    let original = random_bytes(10_000, 9);
    fs::write(&source, &original).unwrap();
    let key = download_key("t-rep", "a.jsonl");
    let state = tmp.join("state");

    let snap = Snapshot::open_or_create(&state, &key, &source, REPORT_CAP).unwrap();
    assert_eq!(snap.meta().length, original.len() as u64);
    assert_eq!(snap.meta().sha256, sha256(&original));
    let (offer, first, res) = send_session(snap, 0, 3, 1024);
    assert!(res.is_err(), "interrupted after 3 acks");
    assert_eq!(offer.length, Some(original.len() as u64));
    assert_eq!(offer.sha256, Some(sha256(&original)));
    assert_eq!(
        first.len(),
        3 * 1024 + 1024,
        "3 acked chunks + 1 unacked in flight"
    );

    // Source changes (and even disappears) after the snapshot.
    fs::write(&source, b"replaced contents").unwrap();
    let snap = Snapshot::open_or_create(&state, &key, &source, REPORT_CAP).unwrap();
    assert_eq!(snap.meta().sha256, sha256(&original));
    fs::remove_file(&source).unwrap();
    let (offer2, rest, res) = send_session(snap, 3 * 1024, usize::MAX, 1024);
    res.unwrap();
    assert_eq!(offer2, offer);
    let mut all = original[..3 * 1024].to_vec();
    all.extend(rest);
    assert_eq!(all, original);

    // A different key for the same id is refused without touching state.
    let mut other = key.clone();
    other.lease_generation += 1;
    let err = Snapshot::open_or_create(&state, &other, &source, REPORT_CAP).unwrap_err();
    assert_eq!(err.code, ErrorCode::MetadataMismatch);

    // Mutation during snapshot creation is refused; nothing is bound.
    let src2 = tmp.join("b.jsonl");
    fs::write(&src2, b"stable?").unwrap();
    let opts = SnapshotOptions {
        hooks: Some(Arc::new(MutateSource(src2.clone()))),
        ..Default::default()
    };
    let key2 = download_key("t-rep2", "b.jsonl");
    let err = Snapshot::open_or_create_with(&state, &key2, &src2, REPORT_CAP, &opts).unwrap_err();
    assert_eq!(err.code, ErrorCode::SourceRejected);
    assert!(!state.join("t-rep2").join(SNAPSHOT_META).exists());
}

#[test]
fn report_cap_is_33554432() {
    let tmp = TempDir::new("cap");
    let ok = tmp.join("ok.jsonl");
    fs::File::create(&ok).unwrap().set_len(REPORT_CAP).unwrap();
    let snap = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-ok", "ok.jsonl"),
        &ok,
        REPORT_CAP,
    )
    .unwrap();
    assert_eq!(snap.meta().length, REPORT_CAP);
    assert_eq!(fs::metadata(snap.path()).unwrap().len(), REPORT_CAP);

    let big = tmp.join("big.jsonl");
    fs::File::create(&big)
        .unwrap()
        .set_len(REPORT_CAP + 1)
        .unwrap();
    let err = Snapshot::open_or_create(
        &tmp.join("state"),
        &download_key("t-big", "big.jsonl"),
        &big,
        REPORT_CAP,
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::TooLarge);
    assert!(!tmp.join("state/t-big").join(SNAPSHOT_META).exists());
}

#[test]
fn reject_report_symlink() {
    let tmp = TempDir::new("replink");
    let real = tmp.join("real.jsonl");
    fs::write(&real, b"{}\n").unwrap();
    let link = tmp.join("link.jsonl");
    symlink(&real, &link).unwrap();
    let fifo = tmp.join("fifo.jsonl");
    mkfifo(&fifo);
    let dir = tmp.join("dir.jsonl");
    fs::create_dir(&dir).unwrap();
    for (i, p) in [&link, &fifo, &dir, &tmp.join("missing.jsonl")]
        .iter()
        .enumerate()
    {
        let name = p.file_name().unwrap().to_str().unwrap();
        let err = Snapshot::open_or_create(
            &tmp.join("state"),
            &download_key(&format!("t-{i}"), name),
            p,
            REPORT_CAP,
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::SourceRejected, "{name}");
    }

    // serve() refuses an open whose artifact is not the authorized source.
    let mut out = Vec::new();
    let input = frame_bytes(&[Frame::Open(Open::download(
        &download_key("t-x", "other.jsonl"),
        MAX_PAYLOAD,
    ))]);
    let err = serve(
        Cursor::new(input),
        &mut out,
        SendConfig {
            state_dir: tmp.join("state"),
            source: real,
            limits: limits(MAX_PAYLOAD),
            hooks: None,
        },
    )
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::SourceRejected);
    assert!(
        matches!(&decode_all(&out)[..], [Frame::Error { code, .. }] if code == "source_rejected")
    );
}

#[test]
fn cleanup_invalidates_resume() {
    let tmp = TempDir::new("cleanup");
    let state = tmp.join("state");
    let data = random_bytes(100, 4);
    let meta = upload_meta("t-up", &data);
    {
        let mut rx = Receiver::open(&state, &meta, &limits(32)).unwrap();
        rx.commit_chunk(0, &data[..32], &sha256(&data[..32]))
            .unwrap();
    }
    let source = tmp.join("r.jsonl");
    fs::write(&source, b"version one").unwrap();
    let key = download_key("t-down", "r.jsonl");
    drop(Snapshot::open_or_create(&state, &key, &source, REPORT_CAP).unwrap());
    fs::write(&source, b"version two!").unwrap();

    let status = Command::new(BIN)
        .args(["cleanup", "--state-dir"])
        .arg(&state)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(!state.exists());
    // Cleanup of a missing dir is fine too.
    assert!(Command::new(BIN)
        .args(["cleanup", "--state-dir"])
        .arg(&state)
        .status()
        .unwrap()
        .success());

    let rx = Receiver::open(&state, &meta, &limits(32)).unwrap();
    assert_eq!(rx.committed_offset(), 0);
    let snap = Snapshot::open_or_create(&state, &key, &source, REPORT_CAP).unwrap();
    assert_eq!(snap.meta().sha256, sha256(b"version two!"));
}

#[test]
fn collect_outputs_and_manifest() {
    let tmp = TempDir::new("collect");
    let outputs = tmp.join("outputs");
    let big = random_bytes(100 * 1024, 5);
    fs::write(&outputs, &big).unwrap();
    let reports = tmp.join("reports");
    fs::create_dir(&reports).unwrap();
    fs::write(reports.join("b.jsonl"), b"{\"b\":1}\n").unwrap();
    fs::write(reports.join("a.jsonl"), b"{}\n").unwrap();
    fs::write(reports.join("notes.txt"), b"skip").unwrap();
    symlink(reports.join("a.jsonl"), reports.join("c.jsonl")).unwrap();
    fs::create_dir(reports.join("sub.jsonl")).unwrap();
    fs::write(reports.join("sub.jsonl/inner.jsonl"), b"{}").unwrap();
    fs::File::create(reports.join("huge.jsonl"))
        .unwrap()
        .set_len(REPORT_CAP + 1)
        .unwrap();
    fs::File::create(reports.join("edge.jsonl"))
        .unwrap()
        .set_len(REPORT_CAP)
        .unwrap();

    let mut config = CollectConfig::new(&outputs);
    config.report_dir = Some(reports.clone());
    let c = match collect(&config).unwrap() {
        Frame::Collect(c) => c,
        other => panic!("unexpected {other:?}"),
    };
    assert!(c.outputs_present);
    assert!(c.outputs_truncated);
    assert_eq!(c.outputs.len(), 65_537);
    assert_eq!(c.outputs, big[..65_537]);
    let names: Vec<_> = c.reports.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, ["a.jsonl", "b.jsonl", "edge.jsonl", "huge.jsonl"]);
    assert_eq!(c.reports[0].size, 3);
    assert!(!c.reports[2].too_large);
    assert!(c.reports[3].too_large);
    assert!(!c.reports_truncated);

    // Through the CLI: one frame on stdout, exit 0.
    let out = Command::new(BIN)
        .args(["collect", "--outputs"])
        .arg(&outputs)
        .arg("--report-dir")
        .arg(&reports)
        .args(["--max-reports", "2"])
        .output()
        .unwrap();
    assert!(out.status.success());
    match &decode_all(&out.stdout)[..] {
        [Frame::Collect(c)] => {
            assert_eq!(c.outputs.len(), 65_537);
            assert!(c.reports_truncated);
            assert_eq!(c.reports.len(), 2);
            assert_eq!(c.reports[0].name, "a.jsonl");
        }
        other => panic!("unexpected {other:?}"),
    }

    // Exactly 65,537 bytes is not truncated; symlinked outputs are absent;
    // a missing report dir yields an empty list.
    fs::write(&outputs, &big[..65_537]).unwrap();
    let small = tmp.join("small");
    fs::write(&small, b"").unwrap();
    let c = match collect(&CollectConfig::new(&outputs)).unwrap() {
        Frame::Collect(c) => c,
        _ => unreachable!(),
    };
    assert!(c.outputs_present && !c.outputs_truncated && c.outputs.len() == 65_537);
    assert!(c.reports.is_empty());
    let link = tmp.join("outputs-link");
    symlink(&outputs, &link).unwrap();
    let mut config = CollectConfig::new(&link);
    config.report_dir = Some(tmp.join("no-such-dir"));
    let c = match collect(&config).unwrap() {
        Frame::Collect(c) => c,
        _ => unreachable!(),
    };
    assert!(!c.outputs_present && c.outputs.is_empty() && c.reports.is_empty());

    // Many long names: the header stays within 8192 bytes by truncating.
    let many = tmp.join("many");
    fs::create_dir(&many).unwrap();
    for i in 0..100 {
        fs::write(many.join(format!("{i:03}-{}.jsonl", "x".repeat(100))), b"").unwrap();
    }
    let mut config = CollectConfig::new(&small);
    config.report_dir = Some(many);
    let f = collect(&config).unwrap();
    assert!(encode_header(&f).len() <= MAX_HEADER);
    match f {
        Frame::Collect(c) => {
            assert!(c.reports_truncated);
            assert!(c.reports.len() < 100 && !c.reports.is_empty());
            assert!(c.outputs_present && c.outputs.is_empty());
            // The longest prefix that fits: one more entry would not.
            let n = c.reports.len();
            let mut more = c.clone();
            more.reports.push(ReportEntry {
                name: format!("{n:03}-{}.jsonl", "x".repeat(100)),
                size: 0,
                too_large: false,
            });
            assert!(encode_header(&Frame::Collect(more)).len() > MAX_HEADER);
        }
        _ => unreachable!(),
    }
}

// ------------------------------------------------------------ end to end

fn spawn(args: &[&str], paths: &[(&str, &Path)]) -> Child {
    let mut cmd = Command::new(BIN);
    cmd.args(args);
    for (flag, p) in paths {
        cmd.arg(flag).arg(p);
    }
    cmd.args(["--idle-timeout-ms", "10000"])
        .args([
            "--deadline-unix-ms",
            &deadline_ms(Duration::from_secs(120)).to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

type Pipe = (
    FrameWriter<std::process::ChildStdin>,
    FrameReader<BufReader<std::process::ChildStdout>>,
);

fn pipes(child: &mut Child) -> Pipe {
    (
        FrameWriter::new(child.stdin.take().unwrap()),
        FrameReader::with_max_payload(BufReader::new(child.stdout.take().unwrap()), MAX_PAYLOAD),
    )
}

fn next(r: &mut FrameReader<BufReader<std::process::ChildStdout>>) -> Frame {
    r.read_frame().unwrap().expect("frame")
}

#[test]
fn cli_upload_and_download_resume_over_pipes() {
    const MIB: usize = 1024 * 1024;
    let tmp = TempDir::new("e2e");

    // ---- upload (server -> helper receive) of a >16 MiB archive.
    let payload = random_bytes(17 * MIB + 12_345, 11);
    let archive = RawTar::new().file("blob.bin", &payload).gz();
    assert!(archive.len() > 16 * MIB);
    let meta = upload_meta("t-e2e-up", &archive);
    let receive_args = [
        "receive",
        "--max-bytes",
        "268435456",
        "--max-expanded-bytes",
        "2147483648",
        "--max-entries",
        "100000",
        "--extract-timeout-ms",
        "60000",
    ];
    let paths = [
        ("--state-dir", &*tmp.join("state")),
        ("--dest", &*tmp.join("ws")),
    ];

    let mut child = spawn(&receive_args, &paths);
    let (mut w, mut r) = pipes(&mut child);
    w.write_frame(&Frame::Open(Open::upload(&meta, MAX_PAYLOAD)))
        .unwrap();
    match next(&mut r) {
        Frame::Ready(rd) => {
            assert_eq!(rd.committed_offset, Some(0));
            assert_eq!(rd.completed, Some(false));
            assert_eq!(rd.max_payload, MAX_PAYLOAD);
        }
        other => panic!("unexpected {other:?}"),
    }
    let mut off = 0usize;
    for _ in 0..4 {
        let end = off + MIB;
        w.write_frame(&Frame::chunk(
            &meta.transfer_id,
            off as u64,
            archive[off..end].to_vec(),
        ))
        .unwrap();
        match next(&mut r) {
            Frame::Ack {
                committed_offset, ..
            } => assert_eq!(committed_offset, end as u64),
            other => panic!("unexpected {other:?}"),
        }
        off = end;
    }
    // Send a fifth chunk and kill the helper without waiting for its ack.
    w.write_frame(&Frame::chunk(
        &meta.transfer_id,
        off as u64,
        archive[off..off + MIB].to_vec(),
    ))
    .unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(tree(&tmp.join("ws")).is_empty());

    let mut child = spawn(&receive_args, &paths);
    let (mut w, mut r) = pipes(&mut child);
    w.write_frame(&Frame::Open(Open::upload(&meta, MAX_PAYLOAD)))
        .unwrap();
    let mut off = match next(&mut r) {
        Frame::Ready(rd) => {
            let c = rd.committed_offset.unwrap() as usize;
            assert!(
                c == 4 * MIB || c == 5 * MIB,
                "resumes from a committed boundary, got {c}"
            );
            c
        }
        other => panic!("unexpected {other:?}"),
    };
    while off < archive.len() {
        let end = (off + MIB).min(archive.len());
        w.write_frame(&Frame::chunk(
            &meta.transfer_id,
            off as u64,
            archive[off..end].to_vec(),
        ))
        .unwrap();
        assert!(
            matches!(next(&mut r), Frame::Ack { committed_offset, .. } if committed_offset == end as u64)
        );
        off = end;
    }
    w.write_frame(&Frame::Finish {
        transfer_id: meta.transfer_id.clone(),
        length: meta.length,
        sha256: meta.sha256,
    })
    .unwrap();
    match next(&mut r) {
        Frame::Complete {
            extracted,
            sha256: s,
            length,
            ..
        } => {
            assert_eq!(extracted, Some(true));
            assert_eq!(s, meta.sha256);
            assert_eq!(length, meta.length);
        }
        other => panic!("unexpected {other:?}"),
    }
    assert!(child.wait().unwrap().success());
    assert_eq!(
        sha256(&fs::read(tmp.join("ws/blob.bin")).unwrap()),
        sha256(&payload)
    );

    // ---- download (helper send -> server) of a >16 MiB report.
    let report = tmp.join("big.jsonl");
    let original = random_bytes(17 * MIB + 777, 12);
    fs::write(&report, &original).unwrap();
    let key = download_key("t-e2e-down", "big.jsonl");
    let send_args = ["send", "--max-bytes", "33554432"];
    let send_paths = [("--state-dir", &*tmp.join("state")), ("--source", &*report)];

    let mut child = spawn(&send_args, &send_paths);
    let (mut w, mut r) = pipes(&mut child);
    w.write_frame(&Frame::Open(Open::download(&key, MAX_PAYLOAD)))
        .unwrap();
    let offer = match next(&mut r) {
        Frame::Ready(rd) => rd,
        other => panic!("unexpected {other:?}"),
    };
    assert_eq!(offer.length, Some(original.len() as u64));
    assert_eq!(offer.sha256, Some(sha256(&original)));
    w.write_frame(&Frame::Ready(Ready {
        transfer_id: key.transfer_id.clone(),
        committed_offset: Some(0),
        length: None,
        sha256: None,
        max_payload: MAX_PAYLOAD,
        completed: None,
    }))
    .unwrap();
    let mut received = Vec::new();
    for _ in 0..3 {
        match next(&mut r) {
            Frame::Chunk {
                offset,
                data,
                sha256: s,
                ..
            } => {
                assert_eq!(offset, received.len() as u64);
                assert_eq!(sha256(&data), s);
                received.extend(data);
            }
            other => panic!("unexpected {other:?}"),
        }
        w.write_frame(&Frame::Ack {
            transfer_id: key.transfer_id.clone(),
            committed_offset: received.len() as u64,
        })
        .unwrap();
    }
    // Disconnect: stdin EOF while chunk 4 is in flight (drain it so the
    // helper's stdout write cannot block). It exits nonzero; the source
    // then changes.
    drop(w);
    while let Ok(Some(_)) = r.read_frame() {}
    assert!(!child.wait().unwrap().success());
    fs::write(&report, b"mutated after the snapshot").unwrap();

    let mut child = spawn(&send_args, &send_paths);
    let (mut w, mut r) = pipes(&mut child);
    w.write_frame(&Frame::Open(Open::download(&key, MAX_PAYLOAD)))
        .unwrap();
    match next(&mut r) {
        Frame::Ready(rd) => assert_eq!(rd, offer, "same immutable snapshot offered"),
        other => panic!("unexpected {other:?}"),
    }
    w.write_frame(&Frame::Ready(Ready {
        transfer_id: key.transfer_id.clone(),
        committed_offset: Some(received.len() as u64),
        length: None,
        sha256: None,
        max_payload: MAX_PAYLOAD,
        completed: None,
    }))
    .unwrap();
    loop {
        match next(&mut r) {
            Frame::Chunk {
                offset,
                data,
                sha256: s,
                ..
            } => {
                assert_eq!(offset, received.len() as u64);
                assert_eq!(sha256(&data), s);
                received.extend(data);
                w.write_frame(&Frame::Ack {
                    transfer_id: key.transfer_id.clone(),
                    committed_offset: received.len() as u64,
                })
                .unwrap();
            }
            Frame::Finish {
                length, sha256: s, ..
            } => {
                assert_eq!(length, received.len() as u64);
                assert_eq!(s, sha256(&received));
                w.write_frame(&Frame::Complete {
                    transfer_id: key.transfer_id.clone(),
                    length,
                    sha256: s,
                    extracted: None,
                })
                .unwrap();
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(child.wait().unwrap().success());
    assert_eq!(sha256(&received), sha256(&original));
    let mut stderr = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(stderr.is_empty(), "no diagnostics on success: {stderr}");
}

/// M11: a snapshot open that finds the transfer lock briefly held (another
/// invocation finishing, or a forked child that has not yet exec'd and still
/// shares the lock descriptor) waits instead of failing `busy` at once.
#[test]
fn snapshot_open_waits_for_a_briefly_held_lock() {
    let tmp = TempDir::new("snaplock");
    let source = tmp.join("a.jsonl");
    fs::write(&source, b"{}\n").unwrap();
    let state = tmp.join("state");
    let key = download_key("t-lock", "a.jsonl");
    let dir = gf_transfer::fsutil::private_transfer_dir(&state, &key.transfer_id).unwrap();
    let held = gf_transfer::fsutil::lock_transfer(&dir, Duration::ZERO, None).unwrap();
    let releaser = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        drop(held);
    });
    let snap = Snapshot::open_or_create(&state, &key, &source, REPORT_CAP).unwrap();
    assert_eq!(snap.meta().length, 3);
    releaser.join().unwrap();
}
