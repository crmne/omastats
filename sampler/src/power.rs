//! Power readings beyond the CPU package and each GPU: the RAPL zones inside
//! and beside the package, and the whole machine's draw when its power supply
//! reports it.

use crate::util::{hwmon_dirs, list_dir, read_text, round1};
use serde_json::{json, Map, Value};
use std::time::Instant;

/// hwmon drivers of power supplies that report their output over USB.
const PSU_HWMON: [&str; 1] = ["corsairpsu"];

/// One RAPL zone that is not a package: core, uncore (integrated graphics),
/// dram or psys (the platform, on Intel laptops the whole SoC and more).
struct Zone {
    name: String,
    energy: String,
    range: u64,
}

pub struct PowerSampler {
    zones: Vec<Zone>,
    prev: Option<(Vec<Option<u64>>, Instant)>,
    psu: Option<String>,
}

impl PowerSampler {
    pub fn new() -> Self {
        let mut zones = Vec::new();
        for zone in list_dir("/sys/class/powercap") {
            let base = format!("/sys/class/powercap/{zone}");
            let Some(name) = read_text(format!("{base}/name")) else { continue };
            // Packages are the CPU's own reading; the energy counters are
            // root-only unless a udev rule opens them.
            let energy = format!("{base}/energy_uj");
            if name.starts_with("package") || std::fs::File::open(&energy).is_err() {
                continue;
            }
            let range = read_text(format!("{base}/max_energy_range_uj"))
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            zones.push(Zone { name: zone_kind(&name).to_string(), energy, range });
        }
        zones.sort_by(|a, b| a.energy.cmp(&b.energy));
        Self { zones, prev: None, psu: find_psu() }
    }

    pub fn sample(&mut self) -> Value {
        let now = Instant::now();
        let energy: Vec<Option<u64>> = self
            .zones
            .iter()
            .map(|z| read_text(&z.energy).and_then(|v| v.parse().ok()))
            .collect();
        let mut zones = Map::new();
        if let Some((before, at)) = &self.prev {
            let seconds = now.duration_since(*at).as_secs_f64();
            if seconds > 0.0 {
                // Zones sharing a kind (one per package) add up.
                for ((zone, now), before) in self.zones.iter().zip(&energy).zip(before) {
                    let (Some(now), Some(before)) = (now, before) else { continue };
                    let watts = delta(*now, *before, zone.range) as f64 / 1e6 / seconds;
                    let total = zones.get(&zone.name).and_then(Value::as_f64).unwrap_or(0.0) + watts;
                    zones.insert(zone.name.clone(), json!(total));
                }
            }
        }
        for value in zones.values_mut() {
            *value = json!(round1(value.as_f64().unwrap_or(0.0)));
        }
        self.prev = Some((energy, now));
        let psu = self
            .psu
            .as_ref()
            .and_then(read_text)
            .and_then(|v| v.parse::<f64>().ok())
            .map(|uw| round1(uw / 1e6));
        json!({ "zones": zones, "psu": psu })
    }
}

/// RAPL names its zones "core", "uncore", "dram" and "psys"; anything else
/// keeps its own name.
fn zone_kind(name: &str) -> &str {
    name.split('-').next().unwrap_or(name)
}

/// Microjoules used between two counter readings, across one wraparound.
fn delta(now: u64, before: u64, range: u64) -> u64 {
    if now >= before {
        now - before
    } else if range > before {
        range - before + now
    } else {
        0
    }
}

/// The power supply's total output: its input labelled "power total", or
/// its first power reading.
fn find_psu() -> Option<String> {
    for hw in hwmon_dirs() {
        let path = format!("/sys/class/hwmon/{hw}");
        let name = read_text(format!("{path}/name")).unwrap_or_default();
        if !PSU_HWMON.contains(&name.as_str()) {
            continue;
        }
        let mut inputs: Vec<String> = list_dir(&path)
            .into_iter()
            .filter(|e| e.starts_with("power") && e.ends_with("_input"))
            .collect();
        inputs.sort();
        let total = inputs.iter().find(|e| {
            read_text(format!("{path}/{}_label", &e[..e.len() - 6]))
                .is_some_and(|l| l.eq_ignore_ascii_case("power total"))
        });
        if let Some(entry) = total.or(inputs.first()) {
            return Some(format!("{path}/{entry}"));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zones_are_named_by_kind() {
        assert_eq!(zone_kind("core"), "core");
        assert_eq!(zone_kind("dram"), "dram");
        assert_eq!(zone_kind("psys"), "psys");
        assert_eq!(zone_kind("package-0"), "package");
    }

    #[test]
    fn counters_survive_one_wraparound() {
        assert_eq!(delta(150, 100, 1000), 50);
        assert_eq!(delta(20, 980, 1000), 40);
        assert_eq!(delta(20, 980, 0), 0);
    }
}
