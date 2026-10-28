use crate::cpu;
use crate::pm;
use crate::util::{
    bounded_text, kill_process_group, list_dir, opt_f64, read_bounded_line, read_f64, read_text,
    run, system_command, which, EXTERNAL_TEXT_LIMIT, STREAM_LINE_LIMIT,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::BufReader;
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
    /// Built into the processor, sharing system memory.
    integrated: bool,
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
        // An AMD APU reports a northbridge voltage; Intel's integrated
        // graphics always sit on the root bus.
        let integrated = match kind {
            Kind::Amd => hwmon.as_deref().is_some_and(cpu::is_apu_hwmon),
            Kind::Intel => slot.starts_with("0000:00:"),
            Kind::Nvidia => false,
        };
        Self {
            kind,
            device,
            slot,
            name: String::new(),
            hwmon,
            boot_vga,
            integrated,
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

/// One process's share of an NVIDIA card, from `nvidia-smi pmon`.
pub struct NvidiaProcess {
    pub slot: String,
    pub pid: u32,
    pub name: String,
    pub util: f64,
    pub mem: f64,
}

/// `nvidia-smi pmon` rows. Columns differ between driver versions, so they
/// are found by the header; "-" means the process did not use that part.
fn parse_pmon(out: &str, slots: &HashMap<String, String>) -> Vec<NvidiaProcess> {
    let mut columns: Vec<String> = Vec::new();
    let mut rows = Vec::new();
    for line in out.lines() {
        if let Some(header) = line.strip_prefix('#') {
            if columns.is_empty() {
                columns = header.split_whitespace().map(str::to_string).collect();
            }
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        let at = |name: &str| {
            columns
                .iter()
                .position(|c| c == name)
                .and_then(|i| parts.get(i).copied())
        };
        let (Some(index), Some(pid)) = (at("gpu"), at("pid").and_then(|p| p.parse().ok())) else {
            continue;
        };
        let Some(slot) = slots.get(index) else { continue };
        let num = |name: &str| at(name).and_then(|v| v.parse::<f64>().ok());
        rows.push(NvidiaProcess {
            slot: slot.clone(),
            pid,
            name: bounded_text(at("command").unwrap_or(""), EXTERNAL_TEXT_LIMIT),
            util: num("sm").unwrap_or(0.0),
            mem: num("fb").unwrap_or(0.0) * 1024.0 * 1024.0,
        });
    }
    rows
}

/// How the NVIDIA cards may be asked for readings this tick.
#[derive(Clone, Copy, Debug, PartialEq)]
enum NvidiaAccess {
    /// None of them can runtime-suspend, so one `nvidia-smi -l 1` streams.
    Stream,
    /// One may suspend and is awake: a query now opens a read window.
    Query,
    /// A card is asleep, or awake and left alone so it can fall asleep.
    /// nvidia-smi opens every card, so nothing is asked.
    Rest,
}

/// Every nvidia-smi call wakes all NVIDIA cards and restarts their idle
/// timers. A card that can suspend is queried once, in a window that the
/// GPU and process samplers share, then left alone for its delay.
fn nvidia_access(states: &[pm::Runtime], opened: Option<Instant>, now: Instant) -> (NvidiaAccess, bool) {
    if states.contains(&pm::Runtime::Suspended) {
        return (NvidiaAccess::Rest, false);
    }
    let delay = states
        .iter()
        .filter_map(|state| match state {
            pm::Runtime::Awake(delay) => Some(*delay),
            _ => None,
        })
        .min();
    let Some(delay) = delay else {
        return (NvidiaAccess::Stream, false);
    };
    match pm::decide(opened, delay, now) {
        (true, reopen) => (NvidiaAccess::Query, reopen),
        (false, _) => (NvidiaAccess::Rest, false),
    }
}

pub struct GpuSampler {
    cards: Vec<GpuCard>,
    latest: Arc<Mutex<HashMap<String, Value>>>,
    /// The `nvidia-smi -l 1` stream, while no NVIDIA card can suspend.
    child: Option<Child>,
    /// nvidia-smi's card index to PCI address, looked up on first use.
    nvidia_slots: Option<HashMap<String, String>>,
    /// When the current read window of the suspendable cards opened.
    opened: Option<Instant>,
    /// A one-shot query is still running.
    querying: Arc<AtomicBool>,
    /// NVIDIA cards found asleep this tick, by PCI address.
    asleep: Vec<String>,
}

impl GpuSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            cards: Vec::new(),
            latest: Arc::new(Mutex::new(HashMap::new())),
            child: None,
            nvidia_slots: None,
            opened: None,
            querying: Arc::new(AtomicBool::new(false)),
            asleep: Vec::new(),
        };
        sampler.detect();
        // Start NVIDIA readings now, so the first sample already has them.
        if sampler.nvidia_gate(Instant::now()) == NvidiaAccess::Query {
            sampler.query_nvidia();
        }
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
    }

    fn has_nvidia(&self) -> bool {
        self.cards.iter().any(|card| card.kind == Kind::Nvidia) && which("nvidia-smi")
    }

    /// Whether nvidia-smi may run now, opening a read window if it starts
    /// one. TLP and friends switch power/control between AC and battery, so
    /// it is decided again every tick.
    fn nvidia_gate(&mut self, now: Instant) -> NvidiaAccess {
        if !self.has_nvidia() {
            return NvidiaAccess::Rest;
        }
        let nvidia: Vec<&GpuCard> = self.cards.iter().filter(|c| c.kind == Kind::Nvidia).collect();
        let states: Vec<pm::Runtime> = nvidia.iter().map(|c| pm::runtime(&c.device)).collect();
        self.asleep = nvidia
            .iter()
            .zip(&states)
            .filter(|(_, state)| **state == pm::Runtime::Suspended)
            .map(|(card, _)| card.slot.clone())
            .collect();
        let (access, reopen) = nvidia_access(&states, self.opened, now);
        if reopen {
            self.opened = Some(now);
        }
        if access == NvidiaAccess::Stream {
            if self.child.is_none() {
                self.start_nvidia();
            }
        } else {
            self.stop();
        }
        access
    }

    /// One reading of every NVIDIA card, in the background so a slow
    /// nvidia-smi never holds up the sampler.
    fn query_nvidia(&self) {
        if self.querying.swap(true, Ordering::SeqCst) {
            return;
        }
        let latest = Arc::clone(&self.latest);
        let querying = Arc::clone(&self.querying);
        std::thread::spawn(move || {
            let out = run(
                "nvidia-smi",
                &[&format!("--query-gpu={NVIDIA_QUERY}"), "--format=csv,noheader,nounits"],
                Duration::from_secs(2),
            );
            if let Ok(mut map) = latest.lock() {
                for (slot, snapshot) in out.lines().filter_map(parse_nvidia_line) {
                    map.insert(slot, snapshot);
                }
            }
            querying.store(false, Ordering::SeqCst);
        });
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
        pm::read_hwmon_f64(&format!("{hwmon}/{}", chosen?))
    }

    /// The `prefix` input labelled exactly `label`, with no fallback.
    fn hwmon_labelled(hwmon: Option<&String>, prefix: &str, label: &str) -> Option<f64> {
        let hwmon = hwmon?;
        let entry = list_dir(hwmon).into_iter().find(|entry| {
            entry.starts_with(prefix)
                && entry.ends_with("_input")
                && read_text(format!("{hwmon}/{}_label", &entry[..entry.len() - 6]))
                    .is_some_and(|l| l.eq_ignore_ascii_case(label))
        })?;
        pm::read_hwmon_f64(&format!("{hwmon}/{entry}"))
    }

    fn sample_card(&self, card: &GpuCard) -> Value {
        if card.kind == Kind::Nvidia {
            let reading = self
                .latest
                .lock()
                .ok()
                .and_then(|map| map.get(&card.slot).cloned());
            if self.asleep.contains(&card.slot) {
                // Asleep cards report nothing; the last reading is stale.
                return json!({
                    "id": card.slot,
                    "name": reading.as_ref().and_then(|r| r["name"].as_str().map(str::to_string))
                        .unwrap_or_else(|| if card.name.is_empty() { Kind::Nvidia.fallback_name().to_string() } else { card.name.clone() }),
                    "vendor": "nvidia",
                    "asleep": true,
                    "util": Value::Null,
                });
            }
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
        // An APU's PPT is the whole package's power, shown as CPU power.
        let power = if card.integrated {
            None
        } else {
            Self::hwmon_value(card.hwmon.as_ref(), "power", &["ppt", "power"])
                .map(|p| p / 1_000_000.0)
        };
        let mhz = Self::hwmon_value(card.hwmon.as_ref(), "freq", &["sclk"])
            .map(|f| f / 1_000_000.0)
            .or_else(|| read_f64(format!("{parent}/gt_cur_freq_mhz")))
            .or_else(|| read_f64(format!("{parent}/gt/gt0/rps_cur_freq_mhz")));
        // amdgpu's VRAM clock: one stuck at its top level at idle (several
        // monitors, high refresh) is a common cause of high idle power.
        let mem_mhz = Self::hwmon_labelled(card.hwmon.as_ref(), "freq", "mclk").map(|f| f / 1_000_000.0);
        json!({
            "id": card.slot,
            "name": if card.name.is_empty() { card.kind.fallback_name() } else { card.name.as_str() },
            "vendor": card.kind.vendor(),
            "integrated": card.integrated,
            "util": opt_f64(pm::read_f64(device, &format!("{device}/gpu_busy_percent"))),
            "memUsed": opt_f64(read_f64(format!("{device}/mem_info_vram_used"))),
            "memTotal": opt_f64(read_f64(format!("{device}/mem_info_vram_total"))),
            "temp": opt_f64(temp),
            "power": opt_f64(power),
            "mhz": opt_f64(mhz),
            "memMhz": opt_f64(mem_mhz),
            "maxMhz": opt_f64(read_f64(format!("{parent}/gt_max_freq_mhz"))),
            "fan": Value::Null,
        })
    }

    /// PCI addresses of the cards built into the processor.
    pub fn integrated_slots(&self) -> Vec<String> {
        self.cards
            .iter()
            .filter(|c| c.integrated)
            .map(|c| c.slot.clone())
            .collect()
    }

    /// What each process uses of every NVIDIA card. The proprietary driver
    /// publishes no per-client counters in fdinfo, so this asks nvidia-smi.
    pub fn nvidia_processes(&mut self) -> Vec<NvidiaProcess> {
        if self.nvidia_gate(Instant::now()) == NvidiaAccess::Rest {
            return Vec::new();
        }
        let slots = self.nvidia_slots.get_or_insert_with(|| {
            run(
                "nvidia-smi",
                &["--query-gpu=index,pci.bus_id", "--format=csv,noheader"],
                Duration::from_secs(2),
            )
            .lines()
            .filter_map(|line| {
                let (index, bus) = line.split_once(',')?;
                Some((index.trim().to_string(), normalize_slot(bus)))
            })
            .collect()
        });
        let out = run(
            "nvidia-smi",
            &["pmon", "-c", "1", "-s", "um"],
            Duration::from_secs(2),
        );
        parse_pmon(&out, slots)
    }

    /// Every detected GPU, boot display first.
    pub fn sample_all(&mut self) -> Vec<Value> {
        if self.nvidia_gate(Instant::now()) == NvidiaAccess::Query {
            self.query_nvidia();
        }
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
            integrated: false,
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
            nvidia_slots: None,
            opened: None,
            querying: Arc::new(AtomicBool::new(false)),
            asleep: Vec::new(),
        };
        // sample_card, not sample_all, so the test never starts nvidia-smi.
        let readings: Vec<Value> = sampler.cards.iter().map(|c| sampler.sample_card(c)).collect();
        assert_eq!(readings.len(), 1);
        assert_eq!(readings[0]["id"], "0000:01:00.0");
        assert_eq!(readings[0]["vendor"], "nvidia");
        assert!(readings[0]["util"].is_null());
    }

    #[test]
    fn a_sleeping_card_reports_only_its_identity() {
        let sampler = GpuSampler {
            cards: vec![card(Kind::Nvidia, "0000:01:00.0", false)],
            latest: Arc::new(Mutex::new(HashMap::from([(
                "0000:01:00.0".to_string(),
                json!({"name": "RTX", "vendor": "nvidia", "util": 40.0, "temp": 60.0}),
            )]))),
            child: None,
            nvidia_slots: None,
            opened: None,
            querying: Arc::new(AtomicBool::new(false)),
            asleep: vec!["0000:01:00.0".to_string()],
        };
        let reading = sampler.sample_card(&sampler.cards[0]);
        assert_eq!(reading["asleep"], true);
        assert_eq!(reading["name"], "RTX");
        assert!(reading["util"].is_null());
        assert!(reading["temp"].is_null());
    }

    #[test]
    fn pmon_rows_follow_the_header_and_card_index() {
        let out = "\
# gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command
# Idx           #    C/G      %      %      %      %      %      %     MB     MB    name
    0      37129     C      -      -      -      -      -      -   6196      0    llama-server
    0    1904057     G     30      1      -      -      -      -      6      0    Hyprland
    1        812     G      4      0      -      -      -      -     12      0    other-card
";
        let slots = HashMap::from([("0".to_string(), "0000:01:00.0".to_string())]);
        let rows = parse_pmon(out, &slots);
        assert_eq!(rows.len(), 2, "rows on an unknown card are dropped");
        assert_eq!(rows[0].pid, 37129);
        assert_eq!(rows[0].util, 0.0);
        assert_eq!(rows[0].mem, 6196.0 * 1024.0 * 1024.0);
        assert_eq!(rows[1].name, "Hyprland");
        assert_eq!(rows[1].util, 30.0);
        assert_eq!(rows[1].slot, "0000:01:00.0");
    }

    #[test]
    fn always_on_cards_stream() {
        let now = Instant::now();
        assert_eq!(nvidia_access(&[pm::Runtime::AlwaysOn], None, now), (NvidiaAccess::Stream, false));
    }

    #[test]
    fn a_sleeping_card_is_never_asked() {
        let now = Instant::now();
        let states = [pm::Runtime::AlwaysOn, pm::Runtime::Suspended];
        assert_eq!(nvidia_access(&states, None, now), (NvidiaAccess::Rest, false));
    }

    #[test]
    fn an_awake_card_that_can_suspend_is_queried_then_left_alone() {
        let start = Instant::now();
        let states = [pm::Runtime::Awake(Duration::from_secs(5))];
        assert_eq!(nvidia_access(&states, None, start), (NvidiaAccess::Query, true));
        // The process list in the same tick shares the window.
        let soon = start + Duration::from_millis(100);
        assert_eq!(nvidia_access(&states, Some(start), soon), (NvidiaAccess::Query, false));
        let cooling = start + Duration::from_secs(3);
        assert_eq!(nvidia_access(&states, Some(start), cooling), (NvidiaAccess::Rest, false));
        let later = start + Duration::from_secs(6);
        assert_eq!(nvidia_access(&states, Some(start), later), (NvidiaAccess::Query, true));
    }

    #[test]
    fn mclk_is_read_by_its_label_only() {
        let dir = std::env::temp_dir().join(format!("omastats-mclk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("freq1_input"), "2400000000\n").unwrap();
        std::fs::write(dir.join("freq1_label"), "sclk\n").unwrap();
        let hwmon = dir.to_string_lossy().to_string();
        assert_eq!(GpuSampler::hwmon_labelled(Some(&hwmon), "freq", "mclk"), None);
        std::fs::write(dir.join("freq2_input"), "96000000\n").unwrap();
        std::fs::write(dir.join("freq2_label"), "mclk\n").unwrap();
        assert_eq!(GpuSampler::hwmon_labelled(Some(&hwmon), "freq", "mclk"), Some(96_000_000.0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn short_rows_are_ignored() {
        assert!(parse_nvidia_line("").is_none());
        assert!(parse_nvidia_line("00000000:01:00.0, Card, 5").is_none());
    }
}
