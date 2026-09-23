//! amdgpu restarts a card's runtime-suspend timer on every sysfs read that
//! reaches the hardware (utilisation, temperature, clock, power). Sampled
//! every second, an awake card that could suspend never would. Reads of such
//! a card are batched instead: the first read opens a short window that every
//! sampler shares, then the card is left alone for its autosuspend delay and
//! callers get the value it last returned.
//!
//! Reads never wake a suspended card, so one that is asleep is read normally.

use crate::util::{parse_f64, parse_i64, read_text};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Long enough for one sampling pass to read everything it wants.
const READ_WINDOW: Duration = Duration::from_millis(500);
/// Headroom past the autosuspend delay, so the timer can always expire.
const MARGIN: Duration = Duration::from_secs(1);

#[derive(Default)]
struct Gate {
    /// When each card's current read window opened, by canonical device path.
    opened: HashMap<String, Instant>,
    /// The last value read from each gated attribute.
    held: HashMap<String, Option<String>>,
}

static GATE: LazyLock<Mutex<Gate>> = LazyLock::new(Mutex::default);

/// How long an amdgpu card must go unread to runtime-suspend, when it is
/// awake and the kernel is allowed to suspend it.
fn awake_delay(device: &str) -> Option<Duration> {
    let driver = std::fs::read_link(format!("{device}/driver")).ok()?;
    if driver.file_name()? != "amdgpu" {
        return None;
    }
    if read_text(format!("{device}/power/control"))? != "auto"
        || read_text(format!("{device}/power/runtime_status"))? != "active"
    {
        return None;
    }
    let ms = read_text(format!("{device}/power/autosuspend_delay_ms"))?
        .parse::<u64>()
        .ok()?;
    Some(Duration::from_millis(ms))
}

/// Whether a card whose window opened at `opened` may be read at `now`, and
/// whether that read opens a new window.
fn decide(opened: Option<Instant>, delay: Duration, now: Instant) -> (bool, bool) {
    match opened.map(|at| now.saturating_duration_since(at)) {
        Some(age) if age < READ_WINDOW => (true, false),
        Some(age) if age < delay + MARGIN => (false, false),
        _ => (true, true),
    }
}

/// Read `path`, an attribute of the PCI `device`, unless that would keep the
/// card awake; then return the value it last read.
pub fn read(device: &str, path: &str) -> Option<String> {
    read_at(device, path, Instant::now())
}

fn read_at(device: &str, path: &str, now: Instant) -> Option<String> {
    let delay = match awake_delay(device) {
        Some(delay) => delay,
        None => return read_text(path),
    };
    let key = std::fs::canonicalize(device)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| device.to_string());
    let mut gate = GATE.lock().unwrap_or_else(|e| e.into_inner());
    let (allowed, reopen) = decide(gate.opened.get(&key).copied(), delay, now);
    if !allowed {
        if let Some(value) = gate.held.get(path) {
            return value.clone();
        }
    }
    if reopen {
        gate.opened.insert(key, now);
    }
    let value = read_text(path);
    gate.held.insert(path.to_string(), value.clone());
    value
}

/// The PCI device behind an hwmon attribute such as `.../hwmon3/temp1_input`.
pub fn hwmon_device(path: &str) -> String {
    let dir = Path::new(path).parent().unwrap_or(Path::new(""));
    format!("{}/device", dir.to_string_lossy())
}

pub fn read_f64(device: &str, path: &str) -> Option<f64> {
    parse_f64(&read(device, path)?)
}

pub fn read_hwmon_f64(path: &str) -> Option<f64> {
    read_f64(&hwmon_device(path), path)
}

pub fn read_hwmon_i64(path: &str) -> Option<i64> {
    parse_i64(&read(&hwmon_device(path), path)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DELAY: Duration = Duration::from_secs(5);

    #[test]
    fn one_pass_shares_a_window() {
        let start = Instant::now();
        assert_eq!(decide(None, DELAY, start), (true, true));
        let later = start + Duration::from_millis(100);
        assert_eq!(decide(Some(start), DELAY, later), (true, false));
    }

    #[test]
    fn the_card_is_left_alone_until_it_could_have_suspended() {
        let start = Instant::now();
        assert_eq!(decide(Some(start), DELAY, start + Duration::from_secs(1)), (false, false));
        assert_eq!(decide(Some(start), DELAY, start + Duration::from_millis(5999)), (false, false));
        assert_eq!(decide(Some(start), DELAY, start + Duration::from_secs(6)), (true, true));
    }

    /// A fake amdgpu PCI device with runtime PM files and one attribute.
    fn fake_card(name: &str, control: &str, status: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("omastats-pm-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let device = root.join("0000:3b:00.0");
        std::fs::create_dir_all(device.join("power")).unwrap();
        std::fs::create_dir_all(root.join("amdgpu")).unwrap();
        std::os::unix::fs::symlink(root.join("amdgpu"), device.join("driver")).unwrap();
        std::fs::write(device.join("power/control"), format!("{control}\n")).unwrap();
        std::fs::write(device.join("power/runtime_status"), format!("{status}\n")).unwrap();
        std::fs::write(device.join("power/autosuspend_delay_ms"), "5000\n").unwrap();
        std::fs::write(device.join("gpu_busy_percent"), "37\n").unwrap();
        device
    }

    fn busy(device: &std::path::Path, now: Instant) -> Option<String> {
        let dev = device.to_string_lossy();
        read_at(&dev, &format!("{dev}/gpu_busy_percent"), now)
    }

    #[test]
    fn an_awake_card_repeats_its_last_reading() {
        let device = fake_card("awake", "auto", "active");
        let start = Instant::now();
        assert_eq!(busy(&device, start).as_deref(), Some("37"));
        std::fs::write(device.join("gpu_busy_percent"), "80\n").unwrap();
        assert_eq!(busy(&device, start + Duration::from_secs(1)).as_deref(), Some("37"));
        assert_eq!(busy(&device, start + Duration::from_secs(6)).as_deref(), Some("80"));
        let _ = std::fs::remove_dir_all(device.parent().unwrap());
    }

    #[test]
    fn a_suspended_or_always_on_card_is_read_every_time() {
        for (name, control, status) in [("asleep", "auto", "suspended"), ("on", "on", "active")] {
            let device = fake_card(name, control, status);
            let start = Instant::now();
            assert_eq!(busy(&device, start).as_deref(), Some("37"));
            std::fs::write(device.join("gpu_busy_percent"), "80\n").unwrap();
            assert_eq!(busy(&device, start + Duration::from_secs(1)).as_deref(), Some("80"));
            let _ = std::fs::remove_dir_all(device.parent().unwrap());
        }
    }
}
