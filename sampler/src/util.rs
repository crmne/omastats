use std::fs;
use std::io::{self, BufRead, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub const CONTROL_LINE_LIMIT: usize = 4 * 1024;
pub const EXTERNAL_TEXT_LIMIT: usize = 512;
pub const STREAM_LINE_LIMIT: usize = 64 * 1024;

const FILE_READ_LIMIT: u64 = 1024 * 1024;
const COMMAND_OUTPUT_LIMIT: usize = 1024 * 1024;
const DIRECTORY_ENTRY_LIMIT: usize = 4096;
const TOOL_DIRS: [&str; 2] = ["/usr/bin", "/bin"];

/// Read a procfs/sysfs-sized text file with an explicit allocation bound.
/// Missing, invalid UTF-8, and oversized inputs yield None.
pub fn read_text<P: AsRef<Path>>(path: P) -> Option<String> {
    let file = fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take(FILE_READ_LIMIT + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > FILE_READ_LIMIT {
        return None;
    }
    String::from_utf8(bytes).ok().map(|s| s.trim().to_string())
}

/// Return at most `limit` UTF-8 bytes without splitting a character.
pub fn bounded_text(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_string();
    }
    let mut end = limit;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

/// Read and drain one line while retaining at most `limit` bytes.
/// Oversized or invalid UTF-8 lines become an empty line, allowing callers to
/// ignore them without leaving attacker-controlled data buffered in the pipe.
pub fn read_bounded_line<R: BufRead>(reader: &mut R, limit: usize) -> io::Result<Option<String>> {
    let mut bytes = Vec::with_capacity(limit.min(4096));
    let mut oversized = false;
    let mut saw_input = false;

    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if !saw_input {
                return Ok(None);
            }
            break;
        }
        saw_input = true;
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if !oversized {
            let remaining = limit.saturating_add(2).saturating_sub(bytes.len());
            bytes.extend_from_slice(&available[..consumed.min(remaining)]);
            if consumed > remaining {
                oversized = true;
            }
        }
        let ended = available[consumed - 1] == b'\n';
        reader.consume(consumed);
        if ended {
            break;
        }
    }

    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if oversized || bytes.len() > limit {
        return Ok(Some(String::new()));
    }
    Ok(Some(String::from_utf8(bytes).unwrap_or_default()))
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

/// Resolve optional system helpers only from root-owned system directories.
/// Plugin behavior therefore cannot be replaced through a user-controlled PATH.
pub fn command_path(program: &str) -> Option<PathBuf> {
    if program.is_empty() || program.contains('/') {
        return None;
    }
    for directory in TOOL_DIRS {
        let candidate = Path::new(directory).join(program);
        let metadata = fs::metadata(&candidate).ok();
        if metadata
            .as_ref()
            .is_some_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        {
            return Some(candidate);
        }
    }
    None
}

/// Construct a fixed-identity helper in its own process group.
pub fn system_command(program: &str) -> Option<Command> {
    let mut command = Command::new(command_path(program)?);
    command.process_group(0);
    Some(command)
}

pub fn which(program: &str) -> bool {
    command_path(program).is_some()
}

pub fn kill_process_group(pid: u32) {
    if let Ok(group) = i32::try_from(pid) {
        // SAFETY: every child passed here is spawned with process_group(0), so
        // the negative id targets only that child's process group.
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
}

/// Run a fixed system helper with time and output bounds.
pub fn run(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut command = match system_command(program) {
        Some(command) => command,
        None => return String::new(),
    };
    let mut child = match command
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return String::new(),
    };
    let pid = child.id();
    let mut stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            kill_process_group(pid);
            let _ = child.wait();
            return String::new();
        }
    };

    let fd = stdout.as_raw_fd();
    // SAFETY: fd belongs to the live ChildStdout above; F_GETFL/F_SETFL do not
    // take ownership, and their return values are checked.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        kill_process_group(pid);
        let _ = child.wait();
        return String::new();
    }

    let started = Instant::now();
    let mut output = Vec::with_capacity(16 * 1024);
    let mut buffer = [0u8; 16 * 1024];
    let mut eof = false;
    let mut exited = false;

    loop {
        loop {
            match stdout.read(&mut buffer) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(count) => {
                    if output.len().saturating_add(count) > COMMAND_OUTPUT_LIMIT {
                        kill_process_group(pid);
                        let _ = child.wait();
                        return String::new();
                    }
                    output.extend_from_slice(&buffer[..count]);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    kill_process_group(pid);
                    let _ = child.wait();
                    return String::new();
                }
            }
        }

        if !exited {
            match child.try_wait() {
                Ok(Some(_)) => {
                    exited = true;
                    // A descendant must not keep the captured pipe open after
                    // the requested helper itself has exited.
                    kill_process_group(pid);
                }
                Ok(None) => {}
                Err(_) => {
                    kill_process_group(pid);
                    let _ = child.wait();
                    return String::new();
                }
            }
        }
        if exited && eof {
            break;
        }
        if started.elapsed() >= timeout {
            kill_process_group(pid);
            let _ = child.wait();
            return String::new();
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    String::from_utf8(output).unwrap_or_default()
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

/// Sorted directory entry names, or empty when the directory is missing or
/// exceeds the explicit cardinality bound.
pub fn list_dir<P: AsRef<Path>>(path: P) -> Vec<String> {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };
    let mut names = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        if names.len() >= DIRECTORY_ENTRY_LIMIT {
            return Vec::new();
        }
        names.push(entry.file_name().to_string_lossy().to_string());
    }
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
    let all_alpha_suffix = |prefix: &str| {
        name.starts_with(prefix)
            && name.len() > prefix.len()
            && name[prefix.len()..].bytes().all(|b| b.is_ascii_lowercase())
    };
    if all_alpha_suffix("sd")
        || all_alpha_suffix("vd")
        || all_alpha_suffix("hd")
        || all_alpha_suffix("xvd")
    {
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
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn bounded_text_preserves_utf8_boundaries() {
        assert_eq!(bounded_text("abcé", 4), "abc");
        assert_eq!(bounded_text("abc", 4), "abc");
    }

    #[test]
    fn bounded_line_drains_oversized_input() {
        let mut input = Cursor::new(b"123456\nok\n");
        assert_eq!(
            read_bounded_line(&mut input, 4).unwrap(),
            Some(String::new())
        );
        assert_eq!(
            read_bounded_line(&mut input, 4).unwrap(),
            Some("ok".to_string())
        );
        assert_eq!(read_bounded_line(&mut input, 4).unwrap(), None);
    }

    #[test]
    fn disk_names_are_classified_without_partitions() {
        assert!(is_whole_disk("nvme0n1"));
        assert!(is_whole_disk("sda"));
        assert!(!is_whole_disk("nvme0n1p1"));
        assert!(!is_whole_disk("sda1"));
    }
}
