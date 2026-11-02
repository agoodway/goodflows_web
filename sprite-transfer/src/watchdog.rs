//! Stdout watchdog.
//!
//! [`crate::protocol::FrameSource`] enforces the idle timeout and the
//! absolute deadline only while the helper waits for input. A helper can
//! also block *writing* stdout (a 1 MiB chunk into a pipe nobody drains), and
//! then nothing else would end it. The watchdog is a background thread that
//! ends the process when:
//!
//! - a stdout write (wrapped with [`Watchdog::writer`]) has made no progress
//!   for the idle timeout, or
//! - the absolute deadline plus [`DEADLINE_GRACE`] has passed, whatever the
//!   helper is doing (the grace lets the cooperative checks answer with an
//!   `error` frame first).
//!
//! Writes are split into slices of at most [`crate::fsutil::IO_BUF`] bytes so
//! a slow but steady reader keeps refreshing the progress clock. Time spent
//! waiting for input, extracting or snapshotting never counts as idle here.

use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::fsutil::IO_BUF;

/// Exit status used when the watchdog ends the process.
pub const WATCHDOG_EXIT_CODE: i32 = 3;

/// How long after the deadline the watchdog waits before ending the process.
pub const DEADLINE_GRACE: Duration = Duration::from_secs(1);

/// Why the watchdog fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trip {
    /// A stdout write made no progress for the idle timeout.
    IdleTimeout,
    /// The absolute deadline (plus grace) passed.
    Deadline,
}

impl Trip {
    pub fn message(self) -> &'static str {
        match self {
            Trip::IdleTimeout => "idle_timeout: stdout write made no progress within idle timeout",
            Trip::Deadline => "deadline: deadline reached",
        }
    }
}

struct Shared {
    start: Instant,
    /// Number of writes in progress (0 or 1 in practice).
    writing: AtomicBool,
    /// Milliseconds since `start` of the last write progress.
    last_progress_ms: AtomicU64,
}

impl Shared {
    fn now_ms(&self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }

    fn touch(&self) {
        self.last_progress_ms.store(self.now_ms(), Ordering::SeqCst);
    }
}

/// Handle to a running watchdog thread.
#[derive(Clone)]
pub struct Watchdog {
    shared: Arc<Shared>,
}

impl Watchdog {
    /// Start the watchdog. `on_trip` runs once, on the watchdog thread, when
    /// it fires (the CLI exits the process there).
    pub fn spawn<F>(idle_timeout: Duration, deadline: Option<SystemTime>, on_trip: F) -> Watchdog
    where
        F: FnOnce(Trip) + Send + 'static,
    {
        let shared = Arc::new(Shared {
            start: Instant::now(),
            writing: AtomicBool::new(false),
            last_progress_ms: AtomicU64::new(0),
        });
        let watched = shared.clone();
        let poll = (idle_timeout / 4).clamp(Duration::from_millis(5), Duration::from_millis(100));
        let idle_ms = idle_timeout.as_millis() as u64;
        thread::Builder::new()
            .name("gf-transfer-watchdog".into())
            .spawn(move || loop {
                thread::sleep(poll);
                if let Some(d) = deadline {
                    if SystemTime::now() >= d + DEADLINE_GRACE {
                        on_trip(Trip::Deadline);
                        return;
                    }
                }
                if watched.writing.load(Ordering::SeqCst) {
                    let last = watched.last_progress_ms.load(Ordering::SeqCst);
                    if watched.now_ms().saturating_sub(last) >= idle_ms {
                        on_trip(Trip::IdleTimeout);
                        return;
                    }
                }
            })
            .expect("spawn watchdog thread");
        Watchdog { shared }
    }

    /// Wrap `inner` so its writes and flushes are watched.
    pub fn writer<W: Write>(&self, inner: W) -> WatchedWriter<W> {
        WatchedWriter {
            inner,
            shared: self.shared.clone(),
        }
    }

    /// Start the CLI watchdog: on a trip, write a short diagnostic to stderr
    /// (bounded, so a full stderr pipe cannot hold the process) and exit with
    /// [`WATCHDOG_EXIT_CODE`].
    pub fn spawn_exiting(idle_timeout: Duration, deadline: Option<SystemTime>) -> Watchdog {
        Watchdog::spawn(idle_timeout, deadline, |trip| {
            let (tx, rx) = std::sync::mpsc::channel();
            let _ = thread::Builder::new().spawn(move || {
                let _ = writeln!(io::stderr(), "gf-transfer: {}", trip.message());
                let _ = tx.send(());
            });
            let _ = rx.recv_timeout(Duration::from_millis(200));
            std::process::exit(WATCHDOG_EXIT_CODE);
        })
    }
}

/// A writer whose blocking time is visible to the [`Watchdog`].
pub struct WatchedWriter<W> {
    inner: W,
    shared: Arc<Shared>,
}

impl<W: Write> WatchedWriter<W> {
    fn watched<T>(&mut self, f: impl FnOnce(&mut W) -> io::Result<T>) -> io::Result<T> {
        self.shared.touch();
        self.shared.writing.store(true, Ordering::SeqCst);
        let result = f(&mut self.inner);
        self.shared.touch();
        self.shared.writing.store(false, Ordering::SeqCst);
        result
    }
}

impl<W: Write> Write for WatchedWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = buf.len().min(IO_BUF);
        self.watched(|w| w.write(&buf[..n]))
    }

    fn flush(&mut self) -> io::Result<()> {
        self.watched(|w| w.flush())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    /// Blocks every write until released.
    struct Stuck(mpsc::Receiver<()>);

    impl Write for Stuck {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let _ = self.0.recv();
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// Accepts at most 64 KiB per call, taking `delay` each time.
    struct Slow(Duration, usize);

    impl Write for Slow {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            thread::sleep(self.0);
            let n = buf.len().min(64 * 1024);
            self.1 += n;
            Ok(n)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn tripped(idle: Duration, deadline: Option<SystemTime>) -> (Watchdog, mpsc::Receiver<Trip>) {
        let (tx, rx) = mpsc::channel();
        let wd = Watchdog::spawn(idle, deadline, move |t| {
            let _ = tx.send(t);
        });
        (wd, rx)
    }

    #[test]
    fn trips_on_a_stuck_write() {
        let (wd, rx) = tripped(Duration::from_millis(100), None);
        let (_release, stuck) = mpsc::channel();
        let mut w = wd.writer(Stuck(stuck));
        thread::spawn(move || {
            let _ = w.write_all(&[0u8; 10]);
        });
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(5)),
            Ok(Trip::IdleTimeout)
        );
    }

    #[test]
    fn slow_but_steady_writes_and_idle_reads_do_not_trip() {
        let (wd, rx) = tripped(Duration::from_millis(150), None);
        let mut w = wd.writer(Slow(Duration::from_millis(40), 0));
        // 1 MiB in 16 slices of 40 ms: ~640 ms total, never 150 ms stalled.
        w.write_all(&vec![0u8; 1024 * 1024]).unwrap();
        assert_eq!(w.inner.1, 1024 * 1024);
        // Not writing (e.g. waiting for input) is never idle here.
        thread::sleep(Duration::from_millis(400));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn trips_after_the_deadline_grace() {
        let started = Instant::now();
        let (_wd, rx) = tripped(
            Duration::from_secs(60),
            Some(SystemTime::now() + Duration::from_millis(100)),
        );
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok(Trip::Deadline));
        assert!(started.elapsed() >= Duration::from_millis(100) + DEADLINE_GRACE);
    }
}
