//! Phase timings for one on-device re-sign, written where the user can read them.
//!
//! Re-signing on the phone was reported as taking "forever" with no way to see
//! where the time actually went, and the Apple-facing half of it cannot be
//! measured from a development machine without signing in as the user. So every
//! phase records how long it took to a plain text file in the app's Documents
//! folder, which file sharing makes visible in the Files app. One real run then
//! hands over the breakdown instead of us guessing at it.
//!
//! Phase names and seconds only. No Apple ID, no password, no token, no serial,
//! nothing that identifies the account or the device.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Past this the log is started over, so a phone that re-signs itself every
/// seven days for a year does not accumulate a file without end.
const MAX_BYTES: u64 = 64 * 1024;

static SINK: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

fn sink() -> &'static Mutex<Option<PathBuf>> {
    SINK.get_or_init(|| Mutex::new(None))
}

/// Point the timing log at a file and mark the start of a run.
pub fn start(path: &Path) {
    let mut guard = sink().lock().unwrap_or_else(|error| error.into_inner());
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::metadata(path).map(|meta| meta.len() > MAX_BYTES).unwrap_or(false) {
        let _ = std::fs::write(path, b"");
    }
    *guard = Some(path.to_path_buf());
    drop(guard);
    record_line(&format!("\n--- re-sign started {} ---", crate::anisette::apple_now()));
}

fn record_line(line: &str) {
    let guard = sink().lock().unwrap_or_else(|error| error.into_inner());
    let Some(path) = guard.as_ref() else { return };
    let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };
    let _ = writeln!(file, "{line}");
}

/// Record one finished phase and how long it took.
pub fn record(phase: &str, seconds: f64) {
    record_line(&format!("{seconds:7.2}s  {phase}"));
}

/// A phase that records itself when it goes out of scope.
///
/// Dropping rather than an explicit call at the end is deliberate: a phase that
/// fails or hangs and is torn down by `?` is exactly the one worth knowing the
/// duration of, and an explicit call after the `?` would never run.
pub struct Phase {
    name: String,
    start: Instant,
}

impl Phase {
    pub fn start(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            start: Instant::now(),
        }
    }
}

impl Drop for Phase {
    fn drop(&mut self) {
        record(&self.name, self.start.elapsed().as_secs_f64());
    }
}
