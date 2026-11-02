//! `gf-transfer` CLI. All paths and limits are server-owned argv; stdin and
//! stdout carry protocol frames only; stderr carries short diagnostics.

use std::collections::HashMap;
use std::io::{self, BufWriter, Write};
use std::path::PathBuf;
use std::time::{Duration, UNIX_EPOCH};

use gf_transfer::archive::ArchiveLimits;
use gf_transfer::collect::{self, CollectConfig};
use gf_transfer::protocol::{Limits, MAX_PAYLOAD, PROTOCOL_VERSION};
use gf_transfer::receive::{run_receive, ReceiveConfig};
use gf_transfer::send::{serve, SendConfig};
use gf_transfer::watchdog::{Watchdog, WatchedWriter};
use gf_transfer::{fsutil, Error};

const USAGE: &str = "usage:
  gf-transfer version
  gf-transfer receive --state-dir DIR --dest DIR --max-bytes N --max-expanded-bytes N \\
      --max-entries N --extract-timeout-ms N --idle-timeout-ms N --deadline-unix-ms N [--max-payload N]
  gf-transfer send --state-dir DIR --source FILE --max-bytes N --idle-timeout-ms N \\
      --deadline-unix-ms N [--max-payload N]
  gf-transfer collect --outputs FILE [--report-dir DIR] [--max-outputs N] [--max-reports N] \\
      [--max-report-bytes N]
  gf-transfer cleanup --state-dir DIR";

struct Args {
    values: HashMap<String, String>,
}

impl Args {
    fn parse(argv: &[String], allowed: &[&str]) -> Result<Args, String> {
        let mut values = HashMap::new();
        let mut it = argv.iter();
        while let Some(flag) = it.next() {
            let name = flag
                .strip_prefix("--")
                .filter(|n| allowed.contains(n))
                .ok_or_else(|| format!("unknown argument {flag}"))?;
            let value = it
                .next()
                .ok_or_else(|| format!("missing value for {flag}"))?;
            if values.insert(name.to_string(), value.clone()).is_some() {
                return Err(format!("duplicate argument {flag}"));
            }
        }
        Ok(Args { values })
    }

    fn opt(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    fn req(&self, name: &str) -> Result<&str, String> {
        self.opt(name).ok_or_else(|| format!("missing --{name}"))
    }

    fn path(&self, name: &str) -> Result<PathBuf, String> {
        self.req(name).map(PathBuf::from)
    }

    fn num(&self, name: &str) -> Result<u64, String> {
        self.req(name)?
            .parse()
            .map_err(|_| format!("--{name} must be a non-negative integer"))
    }

    /// A required duration in milliseconds that must be positive: a zero
    /// timeout would make the helper give up before doing any work.
    fn positive_ms(&self, name: &str) -> Result<Duration, String> {
        match self.num(name)? {
            0 => Err(format!("--{name} must be a positive integer")),
            ms => Ok(Duration::from_millis(ms)),
        }
    }

    fn num_or(&self, name: &str, default: u64) -> Result<u64, String> {
        match self.opt(name) {
            None => Ok(default),
            Some(_) => self.num(name),
        }
    }

    fn limits(&self) -> Result<Limits, String> {
        let max_payload = self.num_or("max-payload", MAX_PAYLOAD)?;
        if max_payload == 0 || max_payload > MAX_PAYLOAD {
            return Err(format!("--max-payload must be within 1..={MAX_PAYLOAD}"));
        }
        Ok(Limits {
            max_payload,
            max_bytes: self.num("max-bytes")?,
            idle_timeout: self.positive_ms("idle-timeout-ms")?,
            deadline: Some(UNIX_EPOCH + Duration::from_millis(self.num("deadline-unix-ms")?)),
        })
    }
}

enum Outcome {
    Ok,
    Usage(String),
    Failed(Error),
}

fn exit_code(outcome: Outcome) -> i32 {
    match outcome {
        Outcome::Ok => 0,
        Outcome::Usage(msg) => {
            eprintln!("gf-transfer: {msg}\n{USAGE}");
            2
        }
        Outcome::Failed(e) => {
            eprintln!("gf-transfer: {e}");
            1
        }
    }
}

fn stdout() -> BufWriter<io::Stdout> {
    BufWriter::with_capacity(64 * 1024, io::stdout())
}

/// Stdout for `receive`/`send`, watched so a blocked write cannot outlive
/// the idle timeout or the deadline (see `watchdog`).
fn watched_stdout(limits: &Limits) -> BufWriter<WatchedWriter<io::Stdout>> {
    let watchdog = Watchdog::spawn_exiting(limits.idle_timeout, limits.deadline);
    BufWriter::with_capacity(64 * 1024, watchdog.writer(io::stdout()))
}

fn cmd_receive(argv: &[String]) -> Outcome {
    let parsed = Args::parse(
        argv,
        &[
            "state-dir",
            "dest",
            "max-bytes",
            "max-expanded-bytes",
            "max-entries",
            "extract-timeout-ms",
            "idle-timeout-ms",
            "deadline-unix-ms",
            "max-payload",
        ],
    )
    .and_then(|a| {
        Ok(ReceiveConfig {
            state_dir: a.path("state-dir")?,
            dest: a.path("dest")?,
            limits: a.limits()?,
            archive: ArchiveLimits {
                max_expanded_bytes: a.num("max-expanded-bytes")?,
                max_entries: a.num("max-entries")?,
                timeout: a.positive_ms("extract-timeout-ms")?,
                hooks: None,
            },
            hooks: None,
        })
    });
    match parsed {
        Err(msg) => Outcome::Usage(msg),
        Ok(config) => match run_receive(io::stdin(), watched_stdout(&config.limits), config) {
            Ok(()) => Outcome::Ok,
            Err(e) => Outcome::Failed(e),
        },
    }
}

fn cmd_send(argv: &[String]) -> Outcome {
    let parsed = Args::parse(
        argv,
        &[
            "state-dir",
            "source",
            "max-bytes",
            "idle-timeout-ms",
            "deadline-unix-ms",
            "max-payload",
        ],
    )
    .and_then(|a| {
        Ok(SendConfig {
            state_dir: a.path("state-dir")?,
            source: a.path("source")?,
            limits: a.limits()?,
            hooks: None,
        })
    });
    match parsed {
        Err(msg) => Outcome::Usage(msg),
        Ok(config) => match serve(io::stdin(), watched_stdout(&config.limits), config) {
            Ok(()) => Outcome::Ok,
            Err(e) => Outcome::Failed(e),
        },
    }
}

fn cmd_collect(argv: &[String]) -> Outcome {
    let parsed = Args::parse(
        argv,
        &[
            "outputs",
            "report-dir",
            "max-outputs",
            "max-reports",
            "max-report-bytes",
        ],
    )
    .and_then(|a| {
        Ok(CollectConfig {
            outputs: a.path("outputs")?,
            report_dir: a.opt("report-dir").map(PathBuf::from),
            max_outputs: a.num_or("max-outputs", collect::DEFAULT_MAX_OUTPUTS)?,
            max_reports: a.num_or("max-reports", collect::DEFAULT_MAX_REPORTS as u64)? as usize,
            max_report_bytes: a.num_or("max-report-bytes", collect::DEFAULT_MAX_REPORT_BYTES)?,
        })
    });
    match parsed {
        Err(msg) => Outcome::Usage(msg),
        Ok(config) => match collect::run_collect(stdout(), &config) {
            Ok(()) => Outcome::Ok,
            Err(e) => Outcome::Failed(e),
        },
    }
}

fn cmd_cleanup(argv: &[String]) -> Outcome {
    let dir = match Args::parse(argv, &["state-dir"]).and_then(|a| a.path("state-dir")) {
        Ok(d) => d,
        Err(msg) => return Outcome::Usage(msg),
    };
    match fsutil::remove_any(&dir) {
        Ok(()) => Outcome::Ok,
        Err(e) => Outcome::Failed(Error::io("cleanup", e)),
    }
}

fn cmd_version() -> Outcome {
    let line = format!(
        "{{\"name\":\"gf-transfer\",\"version\":\"{}\",\"protocol\":{}}}\n",
        env!("CARGO_PKG_VERSION"),
        PROTOCOL_VERSION
    );
    let mut out = io::stdout();
    match out.write_all(line.as_bytes()).and_then(|_| out.flush()) {
        Ok(()) => Outcome::Ok,
        Err(e) => Outcome::Failed(Error::io("write version", e)),
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let outcome = match argv.first().map(String::as_str) {
        Some("version") if argv.len() == 1 => cmd_version(),
        Some("receive") => cmd_receive(&argv[1..]),
        Some("send") => cmd_send(&argv[1..]),
        Some("collect") => cmd_collect(&argv[1..]),
        Some("cleanup") => cmd_cleanup(&argv[1..]),
        _ => Outcome::Usage("unknown command".into()),
    };
    // Exit explicitly so a reader thread blocked on stdin cannot keep the
    // process (and its flock) alive. Frames are flushed as they are written.
    std::process::exit(exit_code(outcome));
}
