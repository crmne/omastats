use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

/// Read a small text file and trim it. Missing or unreadable files yield None.
pub fn read_text<P: AsRef<Path>>(path: P) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub fn read_i64<P: AsRef<Path>>(path: P) -> Option<i64> {
    let raw = read_text(path)?;
    if raw.is_empty() {
        return None;
    }
    raw.parse::<i64>()
        .ok()
        .or_else(|| raw.parse::<f64>().ok().map(|f| f as i64))
}

pub fn read_f64<P: AsRef<Path>>(path: P) -> Option<f64> {
    let raw = read_text(path)?;
    if raw.is_empty() {
        return None;
    }
    raw.parse::<f64>().ok()
}

/// Run a command with a timeout and return its stdout, or an empty string.
pub fn run(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return String::new(),
    };
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if start.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return String::new();
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return String::new(),
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        use std::io::Read;
        let _ = stdout.read_to_string(&mut out);
    }
    out
}

pub fn which(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|dir| {
                let candidate = dir.join(program);
                candidate.is_file()
            })
        })
        .unwrap_or(false)
}

pub fn rate(now: Option<f64>, prev: Option<f64>, elapsed: f64) -> f64 {
    match (now, prev) {
        (Some(n), Some(p)) if elapsed > 0.0 => ((n - p) / elapsed).max(0.0),
        _ => 0.0,
    }
}

pub fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

pub fn round2(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

/// Sorted directory entry names, or empty when the directory is missing.
pub fn list_dir<P: AsRef<Path>>(path: P) -> Vec<String> {
    let mut names: Vec<String> = match fs::read_dir(path) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect(),
        Err(_) => Vec::new(),
    };
    names.sort();
    names
}

/// hwmonN names sorted numerically so hwmon10 lands after hwmon9.
pub fn hwmon_dirs() -> Vec<String> {
    let mut names = list_dir("/sys/class/hwmon");
    names.sort_by_key(|n| n.trim_start_matches("hwmon").parse::<u32>().unwrap_or(0));
    names
}

pub fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn opt_f64(value: Option<f64>) -> serde_json::Value {
    match value {
        Some(v) if v.is_finite() => serde_json::json!(v),
        _ => serde_json::Value::Null,
    }
}

pub fn is_whole_disk(name: &str) -> bool {
    let bytes = name.as_bytes();
    let all_alpha_suffix = |prefix: &str| {
        name.starts_with(prefix)
            && name.len() > prefix.len()
            && name[prefix.len()..].bytes().all(|b| b.is_ascii_lowercase())
    };
    if all_alpha_suffix("sd") || all_alpha_suffix("vd") || all_alpha_suffix("hd") || all_alpha_suffix("xvd") {
        return true;
    }
    if let Some(rest) = name.strip_prefix("nvme") {
        // nvme0n1 but not nvme0n1p1
        let mut parts = rest.splitn(2, 'n');
        let ctrl = parts.next().unwrap_or("");
        let ns = parts.next().unwrap_or("");
        return !ctrl.is_empty()
            && ctrl.bytes().all(|b| b.is_ascii_digit())
            && !ns.is_empty()
            && ns.bytes().all(|b| b.is_ascii_digit());
    }
    if let Some(rest) = name.strip_prefix("mmcblk") {
        return !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit());
    }
    let _ = bytes;
    false
}
