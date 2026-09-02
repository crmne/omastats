use crate::util::{hwmon_dirs, list_dir, read_i64, read_text, round1};
use serde_json::{json, Value};
use std::collections::HashMap;

const GPU_HWMON: [&str; 5] = ["amdgpu", "nouveau", "i915", "xe", "radeon"];

#[derive(Clone)]
struct Temp {
    key: String,
    label: String,
    path: String,
    max: i64,
}

#[derive(Clone)]
struct Fan {
    key: String,
    label: String,
    path: String,
}

#[derive(Clone)]
struct Chip {
    name: String,
    temps: Vec<Temp>,
    fans: Vec<Fan>,
}

pub struct SensorSampler {
    chips: Vec<Chip>,
    stamp: f64,
    gpu_temp_path: Option<String>,
}

fn pretty_chip(name: &str) -> String {
    let table: [(&str, &str); 17] = [
        ("k10temp", "CPU"),
        ("zenpower", "CPU"),
        ("coretemp", "CPU"),
        ("nvme", "NVMe"),
        ("drivetemp", "Drive"),
        ("amdgpu", "GPU"),
        ("nouveau", "GPU"),
        ("i915", "GPU"),
        ("xe", "GPU"),
        ("acpitz", "ACPI"),
        ("spd5118", "Memory"),
        ("jc42", "Memory"),
        ("thinkpad", "ThinkPad"),
        ("BAT0", "Battery"),
        ("BAT1", "Battery"),
        ("dell_smm", "Dell"),
        ("asus", "ASUS"),
    ];
    for (key, value) in table {
        if name == key {
            return value.to_string();
        }
    }
    if name.starts_with("r8169") || name.starts_with("igc") || name.starts_with("e1000") || name.starts_with("ixgbe") {
        return "Ethernet".to_string();
    }
    if name.starts_with("mt79") || name.starts_with("iwl") || name.starts_with("ath") || name.starts_with("rtw") {
        return "Wi-Fi".to_string();
    }
    if name.starts_with("nct") || name.starts_with("it87") || name.starts_with("f71") || name.starts_with("w83") {
        return "Board".to_string();
    }
    name.to_string()
}

/// Super-IO monitoring chips, which some boards expose through two drivers
/// at once (an in-tree one and a vendor one).
fn is_board_chip(name: &str) -> bool {
    ["nct", "it87", "f71", "w83", "asus_ec", "nct6687d"].iter().any(|p| name.starts_with(p))
}

fn score(chip: &Chip) -> usize {
    chip.fans.iter().filter(|f| !f.label.is_empty()).count() * 2
        + chip.temps.iter().filter(|t| !t.label.is_empty()).count()
}

/// Some boards register the same super-IO chip under two drivers, each with
/// its own labels and slightly different read timing. A board chip is one
/// physical device, so keep only the better-labelled copy of each name.
/// Everything else (one hwmon per DIMM, per drive, per GPU) is kept as is.
fn dedupe(chips: Vec<Chip>) -> Vec<Chip> {
    let mut kept: Vec<Chip> = Vec::new();
    for chip in chips {
        let duplicate = if is_board_chip(&chip.name) {
            kept.iter().position(|other| other.name == chip.name)
        } else {
            None
        };
        match duplicate {
            None => kept.push(chip),
            Some(index) => {
                if score(&chip) > score(&kept[index]) {
                    kept[index] = chip;
                }
            }
        }
    }
    kept
}

impl SensorSampler {
    pub fn new() -> Self {
        Self { chips: Vec::new(), stamp: 0.0, gpu_temp_path: None }
    }

    fn scan(&mut self) {
        let mut chips: Vec<Chip> = Vec::new();
        for hw in hwmon_dirs() {
            let path = format!("/sys/class/hwmon/{hw}");
            let name = match read_text(format!("{path}/name")) {
                Some(n) if !n.is_empty() => n,
                _ => continue,
            };
            let mut temps = Vec::new();
            let mut fans = Vec::new();
            for entry in list_dir(&path) {
                if entry.starts_with("temp") && entry.ends_with("_input") {
                    let key = entry[..entry.len() - 6].to_string();
                    let max = read_i64(format!("{path}/{key}_max"))
                        .filter(|v| *v > 0)
                        .or_else(|| read_i64(format!("{path}/{key}_crit")))
                        .unwrap_or(0);
                    temps.push(Temp {
                        label: read_text(format!("{path}/{key}_label")).unwrap_or_default(),
                        path: format!("{path}/{entry}"),
                        max,
                        key,
                    });
                } else if entry.starts_with("fan") && entry.ends_with("_input") {
                    let key = entry[..entry.len() - 6].to_string();
                    fans.push(Fan {
                        label: read_text(format!("{path}/{key}_label")).unwrap_or_default(),
                        path: format!("{path}/{entry}"),
                        key,
                    });
                }
            }
            if temps.is_empty() && fans.is_empty() {
                continue;
            }
            chips.push(Chip { name, temps, fans });
        }
        self.chips = dedupe(chips);
        self.gpu_temp_path = None;
        for chip in &self.chips {
            if GPU_HWMON.contains(&chip.name.as_str()) && !chip.temps.is_empty() {
                let preferred = chip
                    .temps
                    .iter()
                    .find(|t| matches!(t.label.to_lowercase().as_str(), "edge" | "junction"))
                    .or(chip.temps.first());
                self.gpu_temp_path = preferred.map(|t| t.path.clone());
                break;
            }
        }
    }

    pub fn sample(&mut self, now: f64) -> Value {
        if now - self.stamp > 30.0 {
            self.scan();
            self.stamp = now;
        }
        let mut name_counts: HashMap<String, usize> = HashMap::new();
        for chip in &self.chips {
            *name_counts.entry(chip.name.clone()).or_insert(0) += 1;
        }
        let mut name_seen: HashMap<String, usize> = HashMap::new();
        let mut temps: Vec<Value> = Vec::new();
        let mut fans: Vec<Value> = Vec::new();
        for chip in &self.chips {
            let mut chip_label = pretty_chip(&chip.name);
            if name_counts.get(&chip.name).copied().unwrap_or(0) > 1 {
                let n = name_seen.entry(chip.name.clone()).or_insert(0);
                *n += 1;
                chip_label = format!("{chip_label} {n}");
            }
            for temp in &chip.temps {
                let raw = match read_i64(&temp.path) {
                    Some(v) if v > 0 && v < 200_000 => v,
                    _ => continue,
                };
                let label = if !temp.label.is_empty() {
                    temp.label.clone()
                } else if chip.temps.len() == 1 {
                    chip_label.clone()
                } else {
                    format!("{chip_label} {}", &temp.key[4..])
                };
                temps.push(json!({
                    "chip": chip_label,
                    "id": format!("{}/{}", chip.name, temp.key),
                    "label": label,
                    "value": round1(raw as f64 / 1000.0),
                    "max": if temp.max > 0 && temp.max < 200_000 { (temp.max as f64 / 1000.0).round() as i64 } else { 0 },
                }));
            }
            for fan in &chip.fans {
                let raw = match read_i64(&fan.path) {
                    Some(v) => v,
                    None => continue,
                };
                fans.push(json!({
                    "chip": chip_label,
                    "id": format!("{}/{}", chip.name, fan.key),
                    "label": if fan.label.is_empty() { format!("Fan {}", &fan.key[3..]) } else { fan.label.clone() },
                    "rpm": raw,
                }));
            }
        }
        let gpu_temp = self
            .gpu_temp_path
            .as_ref()
            .and_then(|p| read_i64(p))
            .filter(|v| *v > 0)
            .map(|v| round1(v as f64 / 1000.0));
        json!({ "temps": temps, "fans": fans, "gpuTemp": gpu_temp })
    }
}
