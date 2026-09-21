use crate::util::{
    bounded_text, kill_process_group, list_dir, opt_f64, read_bounded_line, read_f64, read_text,
    run, system_command, which, EXTERNAL_TEXT_LIMIT, STREAM_LINE_LIMIT,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::BufReader;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const NVIDIA_QUERY: &str =
    "pci.bus_id,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.gr,clocks.max.gr,fan.speed";

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Nvidia,
    Amd,
    Intel,
}

impl Kind {
    fn vendor(self) -> &'static str {
        match self {
            Kind::Nvidia => "nvidia",
            Kind::Amd => "amd",
            Kind::Intel => "intel",
        }
    }

    fn fallback_name(self) -> &'static str {
        match self {
            Kind::Nvidia => "NVIDIA",
            Kind::Amd => "AMD",
            Kind::Intel => "Intel",
        }
    }
}

/// One detected GPU: where its readings come from and what to call it.
struct GpuCard {
    kind: Kind,
    device: String,
    slot: String,
    name: String,
    hwmon: Option<String>,
    /// The firmware's boot display, which may be integrated or discrete.
    boot_vga: bool,
}

impl GpuCard {
    fn new(kind: Kind, device: String) -> Self {
        let slot = match std::fs::canonicalize(&device) {
            Ok(p) => p
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            Err(_) => String::new(),
        };
        let hwmon = list_dir(format!("{device}/hwmon"))
            .into_iter()
            .next()
            .map(|hw| format!("{device}/hwmon/{hw}"));
        let boot_vga = read_text(format!("{device}/boot_vga"))
            .unwrap_or_default()
            .trim()
            == "1";
        Self {
            kind,
            device,
            slot,
            name: String::new(),
            hwmon,
            boot_vga,
        }
    }
}

/// Boot display first, then stable PCI order without guessing GPU type.
fn order_cards(mut cards: Vec<GpuCard>) -> Vec<GpuCard> {
    cards.sort_by(|a, b| {
        b.boot_vga
            .cmp(&a.boot_vga)
            .then_with(|| a.slot.cmp(&b.slot))
    });
    cards
}

/// nvidia-smi prints an eight-digit PCI domain; sysfs uses four.
fn normalize_slot(bus: &str) -> String {
    let lower = bus.trim().to_lowercase();
    let parts: Vec<&str> = lower.split(':').collect();
    if parts.len() == 3 && parts[0].len() > 4 {
        format!(
            "{}:{}:{}",
            &parts[0][parts[0].len() - 4..],
            parts[1],
            parts[2]
        )
    } else {
        lower
    }
}

/// One nvidia-smi CSV row: its PCI address and the reading it carries.
fn parse_nvidia_line(line: &str) -> Option<(String, Value)> {
    let parts: Vec<&str> = line.split(',').map(|p| p.trim()).collect();
    if parts.len() < 10 {
        return None;
    }
    let num = |s: &str| s.parse::<f64>().ok();
    let mem_used = num(parts[3]).map(|v| v * 1024.0 * 1024.0);
    let mem_total = num(parts[4]).map(|v| v * 1024.0 * 1024.0);
    let snapshot = json!({
        "name": bounded_text(parts[1], EXTERNAL_TEXT_LIMIT),
        "vendor": "nvidia",
        "util": opt_f64(num(parts[2])),
        "memUsed": opt_f64(mem_used),
        "memTotal": opt_f64(mem_total),
        "temp": opt_f64(num(parts[5])),
        "power": opt_f64(num(parts[6])),
        "mhz": opt_f64(num(parts[7])),
        "maxMhz": opt_f64(num(parts[8])),
        "fan": opt_f64(num(parts[9])),
    });
    Some((normalize_slot(parts[0]), snapshot))
}

pub struct GpuSampler {
    cards: Vec<GpuCard>,
    latest: Arc<Mutex<HashMap<String, Value>>>,
    child: Option<Child>,
}

impl GpuSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            cards: Vec::new(),
            latest: Arc::new(Mutex::new(HashMap::new())),
            child: None,
        };
        sampler.detect();
        sampler
    }

    fn detect(&mut self) {
        let mut found: Vec<GpuCard> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for card in list_dir("/sys/class/drm") {
            let is_card = card.starts_with("card")
                && card.len() > 4
                && card[4..].bytes().all(|b| b.is_ascii_digit());
            if !is_card {
                continue;
            }
            let device = format!("/sys/class/drm/{card}/device");
            let vendor = read_text(format!("{device}/vendor"))
                .unwrap_or_default()
                .to_lowercase();
            let kind = match vendor.as_str() {
                "0x1002" => Kind::Amd,
                "0x10de" => Kind::Nvidia,
                "0x8086" => Kind::Intel,
                _ => continue,
            };
            let entry = GpuCard::new(kind, device);
            if entry.slot.is_empty() || seen.contains(&entry.slot) {
                continue;
            }
            seen.push(entry.slot.clone());
            found.push(entry);
        }
        // Detection survives unavailable telemetry helpers.
        self.cards = order_cards(found);
        for card in &mut self.cards {
            card.name = bounded_text(&Self::pci_name(&card.slot), EXTERNAL_TEXT_LIMIT);
        }
        if self.cards.iter().any(|card| card.kind == Kind::Nvidia) {
            self.start_nvidia();
        }
    }

    fn pci_name(slot: &str) -> String {
        if slot.is_empty() || !which("lspci") {
            return String::new();
        }
        let out = run("lspci", &["-mm", "-s", slot], Duration::from_secs(2));
        for line in out.lines() {
            // lspci -mm quotes: slot "class" "vendor" "device" ...
            let quoted: Vec<&str> = line
                .split('"')
                .enumerate()
                .filter(|(i, _)| i % 2 == 1)
                .map(|(_, s)| s)
                .collect();
            if quoted.len() >= 3 {
                let name = quoted[2];
                if let (Some(open), Some(close)) = (name.rfind('['), name.rfind(']')) {
                    if close > open {
                        return bounded_text(&name[open + 1..close], EXTERNAL_TEXT_LIMIT);
                    }
                }
                return bounded_text(name, EXTERNAL_TEXT_LIMIT);
            }
        }
        String::new()
    }

    fn start_nvidia(&mut self) {
        let mut command = match system_command("nvidia-smi") {
            Some(command) => command,
            None => {
                return;
            }
        };
        let child = command
            .arg(format!("--query-gpu={NVIDIA_QUERY}"))
            .arg("--format=csv,noheader,nounits")
            .arg("-l")
            .arg("1")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(_) => {
                return;
            }
        };
        let stdout = match child.stdout.take() {
            Some(s) => s,
            None => {
                kill_process_group(child.id());
                let _ = child.wait();
                return;
            }
        };
        let latest = Arc::clone(&self.latest);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            while let Ok(Some(line)) = read_bounded_line(&mut reader, STREAM_LINE_LIMIT) {
                // One line per GPU per tick, so key each by its PCI address.
                if let Some((slot, snapshot)) = parse_nvidia_line(&line) {
                    if let Ok(mut map) = latest.lock() {
                        map.insert(slot, snapshot);
                    }
                }
            }
        });
        self.child = Some(child);
    }

    fn hwmon_value(hwmon: Option<&String>, prefix: &str, labels: &[&str]) -> Option<f64> {
        let hwmon = hwmon?;
        let mut chosen: Option<String> = None;
        for entry in list_dir(hwmon) {
            if entry.starts_with(prefix) && entry.ends_with("_input") {
                let key = &entry[..entry.len() - 6];
                let label = read_text(format!("{hwmon}/{key}_label"))
                    .unwrap_or_default()
                    .to_lowercase();
                let preferred = labels.contains(&label.as_str());
                if preferred || chosen.is_none() {
                    chosen = Some(entry.clone());
                    if preferred {
                        break;
                    }
                }
            }
        }
        read_f64(format!("{hwmon}/{}", chosen?))
    }

    fn sample_card(&self, card: &GpuCard) -> Value {
        if card.kind == Kind::Nvidia {
            let reading = self
                .latest
                .lock()
                .ok()
                .and_then(|map| map.get(&card.slot).cloned());
            let mut snapshot = reading.unwrap_or_else(|| {
                json!({
                    "name": if card.name.is_empty() { Kind::Nvidia.fallback_name() } else { card.name.as_str() },
                    "vendor": "nvidia",
                    "util": Value::Null,
                })
            });
            snapshot["id"] = Value::String(card.slot.clone());
            return snapshot;
        }
        // AMD reports utilisation and VRAM through sysfs; i915/xe report
        // neither, so an Intel card carries only its clock and temperature.
        let device = &card.device;
        let parent = std::path::Path::new(device)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let temp = Self::hwmon_value(card.hwmon.as_ref(), "temp", &["edge", "junction"])
            .map(|t| t / 1000.0);
        let power = Self::hwmon_value(card.hwmon.as_ref(), "power", &["ppt", "power"])
            .map(|p| p / 1_000_000.0);
        let mhz = Self::hwmon_value(card.hwmon.as_ref(), "freq", &["sclk"])
            .map(|f| f / 1_000_000.0)
            .or_else(|| read_f64(format!("{parent}/gt_cur_freq_mhz")))
            .or_else(|| read_f64(format!("{parent}/gt/gt0/rps_cur_freq_mhz")));
        json!({
            "id": card.slot,
            "name": if card.name.is_empty() { card.kind.fallback_name() } else { card.name.as_str() },
            "vendor": card.kind.vendor(),
            "util": opt_f64(read_f64(format!("{device}/gpu_busy_percent"))),
            "memUsed": opt_f64(read_f64(format!("{device}/mem_info_vram_used"))),
            "memTotal": opt_f64(read_f64(format!("{device}/mem_info_vram_total"))),
            "temp": opt_f64(temp),
            "power": opt_f64(power),
            "mhz": opt_f64(mhz),
            "maxMhz": opt_f64(read_f64(format!("{parent}/gt_max_freq_mhz"))),
            "fan": Value::Null,
        })
    }

    /// Every detected GPU, boot display first.
    pub fn sample_all(&self) -> Vec<Value> {
        self.cards.iter().map(|c| self.sample_card(c)).collect()
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            kill_process_group(child.id());
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nvidia_bus_ids_match_the_sysfs_spelling() {
        // nvidia-smi pads the PCI domain to eight digits; sysfs uses four.
        assert_eq!(normalize_slot("00000000:01:00.0"), "0000:01:00.0");
        assert_eq!(normalize_slot("0000:01:00.0"), "0000:01:00.0");
        assert_eq!(normalize_slot(" 00000000:2F:00.0 "), "0000:2f:00.0");
    }

    #[test]
    fn nvidia_rows_are_keyed_by_address() {
        let line = "00000000:01:00.0, NVIDIA GeForce RTX 4070 Laptop GPU, 12, 512, 8192, 46, 21.5, 810, 3105, 30";
        let (slot, value) = parse_nvidia_line(line).expect("row parses");
        assert_eq!(slot, "0000:01:00.0");
        assert_eq!(value["name"], "NVIDIA GeForce RTX 4070 Laptop GPU");
        assert_eq!(value["vendor"], "nvidia");
        assert_eq!(value["util"], 12.0);
        assert_eq!(value["memUsed"], 512.0 * 1024.0 * 1024.0);
        assert_eq!(value["memTotal"], 8192.0 * 1024.0 * 1024.0);
        assert_eq!(value["fan"], 30.0);
    }

    #[test]
    fn unreadable_fields_become_null_without_dropping_the_row() {
        // nvidia-smi prints [N/A] for anything the card does not report.
        let line = "00000000:01:00.0, Card, [N/A], 0, 4096, [N/A], [N/A], 300, 1500, [N/A]";
        let (slot, value) = parse_nvidia_line(line).expect("row parses");
        assert_eq!(slot, "0000:01:00.0");
        assert!(value["util"].is_null());
        assert!(value["temp"].is_null());
        assert!(value["fan"].is_null());
        assert_eq!(value["mhz"], 300.0);
    }

    fn card(kind: Kind, slot: &str, boot_vga: bool) -> GpuCard {
        GpuCard {
            kind,
            device: format!("/sys/class/drm/card0/device/{slot}"),
            slot: slot.to_string(),
            name: String::new(),
            hwmon: None,
            boot_vga,
        }
    }

    fn slots(cards: &[GpuCard]) -> Vec<&str> {
        cards.iter().map(|c| c.slot.as_str()).collect()
    }

    #[test]
    fn boot_display_can_be_discrete_or_integrated() {
        let desktop = order_cards(vec![
            card(Kind::Amd, "0000:10:00.0", false),
            card(Kind::Nvidia, "0000:01:00.0", true),
        ]);
        assert_eq!(slots(&desktop), ["0000:01:00.0", "0000:10:00.0"]);
        let laptop = order_cards(vec![
            card(Kind::Nvidia, "0000:01:00.0", false),
            card(Kind::Intel, "0000:00:02.0", true),
        ]);
        assert_eq!(slots(&laptop), ["0000:00:02.0", "0000:01:00.0"]);
    }

    #[test]
    fn cards_without_a_boot_display_use_pci_order() {
        let ordered = order_cards(vec![
            card(Kind::Nvidia, "0000:02:00.0", false),
            card(Kind::Intel, "0000:00:02.0", false),
            card(Kind::Amd, "0000:01:00.0", false),
        ]);
        assert_eq!(
            slots(&ordered),
            ["0000:00:02.0", "0000:01:00.0", "0000:02:00.0"]
        );
    }

    #[test]
    fn unavailable_nvidia_still_has_an_identity() {
        let sampler = GpuSampler {
            cards: vec![card(Kind::Nvidia, "0000:01:00.0", true)],
            latest: Arc::new(Mutex::new(HashMap::new())),
            child: None,
        };
        let readings = sampler.sample_all();
        assert_eq!(readings.len(), 1);
        assert_eq!(readings[0]["id"], "0000:01:00.0");
        assert_eq!(readings[0]["vendor"], "nvidia");
        assert!(readings[0]["util"].is_null());
    }

    #[test]
    fn short_rows_are_ignored() {
        assert!(parse_nvidia_line("").is_none());
        assert!(parse_nvidia_line("00000000:01:00.0, Card, 5").is_none());
    }
}
