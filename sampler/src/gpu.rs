use crate::util::{
    bounded_text, kill_process_group, list_dir, opt_f64, read_bounded_line, read_f64, read_text,
    run, system_command, which, EXTERNAL_TEXT_LIMIT, STREAM_LINE_LIMIT,
};
use serde_json::{json, Value};
use std::io::BufReader;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const NVIDIA_QUERY: &str =
    "name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.gr,clocks.max.gr,fan.speed";

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Nvidia,
    Amd,
    Intel,
}

pub struct GpuSampler {
    kind: Option<Kind>,
    card: Option<String>,
    hwmon: Option<String>,
    name: String,
    latest: Arc<Mutex<Option<Value>>>,
    child: Option<Child>,
}

impl GpuSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            kind: None,
            card: None,
            hwmon: None,
            name: String::new(),
            latest: Arc::new(Mutex::new(None)),
            child: None,
        };
        sampler.detect();
        sampler
    }

    fn detect(&mut self) {
        for card in list_dir("/sys/class/drm") {
            let is_card = card.starts_with("card")
                && card[4..].bytes().all(|b| b.is_ascii_digit())
                && card.len() > 4;
            if !is_card {
                continue;
            }
            let device = format!("/sys/class/drm/{card}/device");
            let vendor = read_text(format!("{device}/vendor"))
                .unwrap_or_default()
                .to_lowercase();
            match vendor.as_str() {
                "0x1002" => {
                    self.kind = Some(Kind::Amd);
                    self.card = Some(device);
                    break;
                }
                "0x8086" => {
                    self.kind = Some(Kind::Intel);
                    self.card = Some(device);
                }
                "0x10de" if self.kind.is_none() => {
                    self.kind = Some(Kind::Nvidia);
                    self.card = Some(device);
                }
                _ => {}
            }
        }
        if self.kind == Some(Kind::Nvidia) {
            if which("nvidia-smi") {
                self.start_nvidia();
            } else {
                self.kind = None;
            }
        }
        if let Some(card) = self.card.clone() {
            if let Some(hw) = list_dir(format!("{card}/hwmon")).into_iter().next() {
                self.hwmon = Some(format!("{card}/hwmon/{hw}"));
            }
            self.name = bounded_text(&Self::pci_name(&card), EXTERNAL_TEXT_LIMIT);
        }
    }

    fn pci_name(device: &str) -> String {
        let slot = match std::fs::canonicalize(device) {
            Ok(p) => p
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            Err(_) => return String::new(),
        };
        if !which("lspci") {
            return String::new();
        }
        let out = run("lspci", &["-mm", "-s", &slot], Duration::from_secs(2));
        for line in out.lines() {
            let fields: Vec<&str> = line.split('"').filter(|s| !s.trim().is_empty()).collect();
            // lspci -mm quotes: slot "class" "vendor" "device" ...
            let quoted: Vec<&str> = line
                .split('"')
                .enumerate()
                .filter(|(i, _)| i % 2 == 1)
                .map(|(_, s)| s)
                .collect();
            let _ = fields;
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
                self.kind = None;
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
                self.kind = None;
                return;
            }
        };
        let stdout = match child.stdout.take() {
            Some(s) => s,
            None => {
                kill_process_group(child.id());
                let _ = child.wait();
                self.kind = None;
                return;
            }
        };
        let latest = Arc::clone(&self.latest);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            while let Ok(Some(line)) = read_bounded_line(&mut reader, STREAM_LINE_LIMIT) {
                if line.is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split(',').map(|p| p.trim()).collect();
                if parts.len() < 9 {
                    continue;
                }
                let num = |s: &str| s.parse::<f64>().ok();
                let mem_used = num(parts[2]).map(|v| v * 1024.0 * 1024.0);
                let mem_total = num(parts[3]).map(|v| v * 1024.0 * 1024.0);
                let snapshot = json!({
                    "name": bounded_text(parts[0], EXTERNAL_TEXT_LIMIT),
                    "vendor": "nvidia",
                    "util": opt_f64(num(parts[1])),
                    "memUsed": opt_f64(mem_used),
                    "memTotal": opt_f64(mem_total),
                    "temp": opt_f64(num(parts[4])),
                    "power": opt_f64(num(parts[5])),
                    "mhz": opt_f64(num(parts[6])),
                    "maxMhz": opt_f64(num(parts[7])),
                    "fan": opt_f64(num(parts[8])),
                });
                if let Ok(mut slot) = latest.lock() {
                    *slot = Some(snapshot);
                }
            }
        });
        self.child = Some(child);
    }

    fn hwmon_value(&self, prefix: &str, labels: &[&str]) -> Option<f64> {
        let hwmon = self.hwmon.as_ref()?;
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

    pub fn sample(&self) -> Value {
        match self.kind {
            Some(Kind::Nvidia) => {
                if let Ok(slot) = self.latest.lock() {
                    if let Some(v) = slot.as_ref() {
                        return v.clone();
                    }
                }
                json!({
                    "name": if self.name.is_empty() { "NVIDIA" } else { self.name.as_str() },
                    "vendor": "nvidia",
                    "util": Value::Null,
                })
            }
            Some(kind) => {
                let card = match &self.card {
                    Some(c) => c.clone(),
                    None => return Value::Null,
                };
                let parent = std::path::Path::new(&card)
                    .parent()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_default();
                let util = read_f64(format!("{card}/gpu_busy_percent"));
                let mem_used = read_f64(format!("{card}/mem_info_vram_used"));
                let mem_total = read_f64(format!("{card}/mem_info_vram_total"));
                let temp = self
                    .hwmon_value("temp", &["edge", "junction"])
                    .map(|t| t / 1000.0);
                let power = self
                    .hwmon_value("power", &["ppt", "power"])
                    .map(|p| p / 1_000_000.0);
                let mhz = self
                    .hwmon_value("freq", &["sclk"])
                    .map(|f| f / 1_000_000.0)
                    .or_else(|| read_f64(format!("{parent}/gt_cur_freq_mhz")))
                    .or_else(|| read_f64(format!("{parent}/gt/gt0/rps_cur_freq_mhz")));
                let max_mhz = read_f64(format!("{parent}/gt_max_freq_mhz"));
                let fallback = if kind == Kind::Amd { "AMD" } else { "Intel" };
                json!({
                    "name": if self.name.is_empty() { fallback } else { self.name.as_str() },
                    "vendor": if kind == Kind::Amd { "amd" } else { "intel" },
                    "util": opt_f64(util),
                    "memUsed": opt_f64(mem_used),
                    "memTotal": opt_f64(mem_total),
                    "temp": opt_f64(temp),
                    "power": opt_f64(power),
                    "mhz": opt_f64(mhz),
                    "maxMhz": opt_f64(max_mhz),
                    "fan": Value::Null,
                })
            }
            None => Value::Null,
        }
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            kill_process_group(child.id());
            let _ = child.wait();
        }
    }
}
