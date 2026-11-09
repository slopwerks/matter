//! Logging implementation.

use super::*;

static APP_LOG_TX: Lazy<tokio::sync::broadcast::Sender<AppLogEntry>> =
    Lazy::new(|| tokio::sync::broadcast::channel(LOG_RING_CAP).0);

/// Ring buffer that keeps the last 5,000 log entries so late-joining
/// subscribers (Dart) can retrieve them via `get_recent_logs()`.
static LOG_RING: Lazy<std::sync::Mutex<VecDeque<AppLogEntry>>> =
    Lazy::new(|| std::sync::Mutex::new(VecDeque::new()));

const LOG_RING_CAP: usize = 5_000;

/// Directory where logs are persisted (`{data_dir}/logs`), set once the first
/// client is created or restored.
static LOG_DIR: Lazy<std::sync::RwLock<Option<std::path::PathBuf>>> =
    Lazy::new(|| std::sync::RwLock::new(None));

/// Open handle to the current log file plus its size so writes can trigger
/// rotation. Writes are appended and flushed per entry so a crash loses at
/// most the line being written.
struct ActiveLogFile {
    file: std::fs::File,
    written: u64,
}

static LOG_FILE: Lazy<std::sync::Mutex<Option<ActiveLogFile>>> =
    Lazy::new(|| std::sync::Mutex::new(None));

/// Rotate `matter.log` to a single `matter.log.1` backup past this size.
const LOG_FILE_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Point log persistence at `{data_dir}/logs`, rotating an oversized log.
/// Called when a client is created or restored; safe to call repeatedly.
pub(super) fn init_log_store(data_dir: &str) {
    let log_dir = std::path::Path::new(data_dir).join("logs");
    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        warn!("Failed to create log dir {}: {e}", log_dir.display());
        return;
    }
    let path = log_dir.join("matter.log");
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > LOG_FILE_MAX_BYTES {
            let _ = std::fs::rename(&path, log_dir.join("matter.log.1"));
        }
    }
    let written = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(file) => {
            if let Ok(mut dir) = LOG_DIR.write() {
                *dir = Some(log_dir);
            }
            if let Ok(mut guard) = LOG_FILE.lock() {
                *guard = Some(ActiveLogFile { file, written });
            }
        }
        Err(e) => warn!("Failed to open log file {}: {e}", path.display()),
    }
}

pub(super) fn initialize_log_store(data_dir: String) {
    init_log_store(&data_dir);
}

/// Format epoch milliseconds as `YYYY-MM-DDTHH:MM:SSZ` (UTC) without pulling
/// in a date library.
pub(super) fn format_utc(millis: i64) -> String {
    let secs = millis.div_euclid(1000);
    let day_secs = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(secs.div_euclid(86_400));
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        day_secs / 3600,
        (day_secs % 3600) / 60,
        day_secs % 60
    )
}

/// Howard Hinnant's civil-from-days algorithm: days since Unix epoch →
/// (year, month, day).
pub(super) fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub(super) fn app_log(level: &str, tag: &str, message: String) {
    let ts = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let entry = AppLogEntry {
        timestamp: ts,
        level: level.to_string(),
        tag: tag.to_string(),
        message,
    };
    // Also print to Android logcat
    match level {
        "error" => log::error!("[{}] {}", tag, entry.message),
        "warn" => log::warn!("[{}] {}", tag, entry.message),
        "debug" => log::debug!("[{}] {}", tag, entry.message),
        _ => log::info!("[{}] {}", tag, entry.message),
    }
    // Push to broadcast (live listeners)
    let _ = APP_LOG_TX.send(entry.clone());
    // Persist to the log file (survives restarts, not limited by the ring cap)
    if let Ok(mut guard) = LOG_FILE.lock() {
        if let Some(active) = guard.as_mut() {
            use std::io::Write as _;
            let line = format!(
                "{} [{}] [{}] {}\n",
                format_utc(ts),
                level.to_uppercase(),
                tag,
                entry.message.replace('\n', "\n    ")
            );
            let _ = active.file.write_all(line.as_bytes());
            let _ = active.file.flush();
            active.written += line.len() as u64;
            if active.written > LOG_FILE_MAX_BYTES {
                // Close the handle before renaming (required on Windows).
                guard.take();
                if let Some(dir) = LOG_DIR.read().ok().and_then(|d| d.clone()) {
                    let path = dir.join("matter.log");
                    let _ = std::fs::rename(&path, dir.join("matter.log.1"));
                    if let Ok(file) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&path)
                    {
                        *guard = Some(ActiveLogFile { file, written: 0 });
                    }
                }
            }
        }
    }
    // Push to ring buffer (for get_recent_logs)
    if let Ok(mut ring) = LOG_RING.lock() {
        if ring.len() >= LOG_RING_CAP {
            ring.pop_front();
        }
        ring.push_back(entry);
    }
}

/// Record an API failure in the app log and return the message for
/// propagation to Dart, so no error crosses the FFI boundary silently.
pub(super) fn api_err(tag: &str, message: String) -> String {
    app_log("error", tag, message.clone());
    message
}

pub(super) fn watch_app_logs(sink: crate::frb_generated::StreamSink<AppLogEntry>) {
    let mut rx = APP_LOG_TX.subscribe();
    std::thread::spawn(move || {
        loop {
            match rx.blocking_recv() {
                Ok(entry) => {
                    if sink.add(entry).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    // Continue listening; the ring buffer remains available for export.
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

pub(super) fn get_recent_logs() -> Vec<AppLogEntry> {
    if let Ok(ring) = LOG_RING.lock() {
        ring.iter().cloned().collect()
    } else {
        vec![]
    }
}

pub(super) fn clear_app_logs() {
    if let Ok(mut ring) = LOG_RING.lock() {
        ring.clear();
    }
}

pub(super) fn log_app_message(level: String, tag: String, message: String) {
    let level = match level.as_str() {
        "error" | "warn" | "debug" => level,
        _ => "info".to_string(),
    };
    app_log(&level, &tag, message);
}

pub(super) async fn read_log_files() -> Vec<LogFileContent> {
    let dir = LOG_DIR.read().ok().and_then(|d| d.clone());
    let Some(dir) = dir else { return vec![] };
    let mut files = Vec::new();
    for name in ["matter.log.1", "matter.log"] {
        if let Ok(content) = tokio::fs::read_to_string(dir.join(name)).await {
            files.push(LogFileContent {
                name: name.to_string(),
                content,
            });
        }
    }
    files
}
