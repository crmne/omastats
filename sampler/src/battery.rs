use crate::util::{
    bounded_text, list_dir, now_secs, read_i64, read_text, round2, EXTERNAL_TEXT_LIMIT,
};
use serde_json::{json, Value};

const PERIPHERAL_LIMIT: usize = 256;

pub fn sample_battery() -> Value {
    if std::env::var_os("ISTAT_FAKE_BATTERY").is_some() {
        let t = now_secs();
        let phase = (t / 4.0) % 100.0;
        let charging = ((t / 40.0) as i64) % 2 == 1;
        return json!({
            "present": true, "name": "BAT0", "percent": ((35.0 + phase / 2.0) * 10.0).round() / 10.0,
            "status": if charging { "Charging" } else { "Discharging" },
            "energyNow": 32.1, "energyFull": 56.0, "energyDesign": 57.0, "power": 12.4,
            "voltage": 11.9, "timeToEmpty": 142, "timeToFull": 0, "cycles": 212,
            "health": 98.2, "acOnline": charging, "model": "Demo Cell",
            "peripherals": [{ "name": "MX Master 3S", "percent": 70, "status": "Discharging" }],
        });
    }

    let base = "/sys/class/power_supply";
    let entries = list_dir(base);
    if entries.is_empty() {
        return Value::Null;
    }
    let mut system: Option<Value> = None;
    let mut peripherals: Vec<Value> = Vec::new();
    let mut ac_online: Option<bool> = None;

    for entry in entries {
        let path = format!("{base}/{entry}");
        let ptype = read_text(format!("{path}/type")).unwrap_or_default();
        if matches!(ptype.as_str(), "Mains" | "USB" | "USB_PD" | "USB_C") {
            if let Some(online) = read_i64(format!("{path}/online")) {
                ac_online = Some(ac_online.unwrap_or(false) || online != 0);
            }
            continue;
        }
        if ptype != "Battery" {
            continue;
        }
        let scope = read_text(format!("{path}/scope")).unwrap_or_default();
        let capacity = read_i64(format!("{path}/capacity"));
        let status = bounded_text(
            &read_text(format!("{path}/status"))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "Unknown".into()),
            EXTERNAL_TEXT_LIMIT,
        );
        let model = bounded_text(
            &read_text(format!("{path}/model_name")).unwrap_or_default(),
            EXTERNAL_TEXT_LIMIT,
        );
        let has_energy = read_i64(format!("{path}/energy_full")).is_some()
            || read_i64(format!("{path}/charge_full")).is_some();
        let is_device = scope == "Device"
            || entry.starts_with("hid")
            || entry.starts_with("wacom")
            || (!entry.starts_with("BAT") && !has_energy);
        if is_device {
            if let Some(cap) = capacity.filter(|_| peripherals.len() < PERIPHERAL_LIMIT) {
                peripherals.push(json!({
                    "name": if model.is_empty() { entry.clone() } else { model.clone() },
                    "percent": cap,
                    "status": status,
                }));
            }
            continue;
        }
        if system.is_some() {
            continue;
        }
        let present = read_i64(format!("{path}/present")).unwrap_or(1) == 1;
        let voltage = read_i64(format!("{path}/voltage_now")).unwrap_or(0) as f64 / 1_000_000.0;
        let mut energy_now = read_i64(format!("{path}/energy_now")).map(|v| v as f64);
        let mut energy_full = read_i64(format!("{path}/energy_full")).map(|v| v as f64);
        let mut energy_design = read_i64(format!("{path}/energy_full_design")).map(|v| v as f64);
        let mut power_now = read_i64(format!("{path}/power_now")).map(|v| v as f64);
        if energy_now.is_none() {
            energy_now = read_i64(format!("{path}/charge_now")).map(|v| v as f64 * voltage);
            energy_full = read_i64(format!("{path}/charge_full")).map(|v| v as f64 * voltage);
            energy_design =
                read_i64(format!("{path}/charge_full_design")).map(|v| v as f64 * voltage);
            power_now = read_i64(format!("{path}/current_now")).map(|v| (v as f64).abs() * voltage);
        }
        let health = match (energy_full, energy_design) {
            (Some(full), Some(design)) if full > 0.0 && design > 0.0 => {
                Some(((full / design * 100.0).min(100.0) * 10.0).round() / 10.0)
            }
            _ => None,
        };
        let power_w = power_now.unwrap_or(0.0) / 1_000_000.0;
        let mut time_to_empty = read_i64(format!("{path}/time_to_empty_now"));
        let mut time_to_full = read_i64(format!("{path}/time_to_full_now"));
        if time_to_empty.is_none() && status == "Discharging" && power_w > 0.0 {
            if let Some(now) = energy_now {
                time_to_empty = Some((now / 1_000_000.0 / power_w * 60.0).round() as i64);
            }
        }
        if time_to_full.is_none() && status == "Charging" && power_w > 0.0 {
            if let (Some(now), Some(full)) = (energy_now, energy_full) {
                time_to_full = Some(((full - now) / 1_000_000.0 / power_w * 60.0).round() as i64);
            }
        }
        let percent = capacity.or_else(|| match (energy_now, energy_full) {
            (Some(now), Some(full)) if full > 0.0 => Some((now / full * 100.0).round() as i64),
            _ => None,
        });
        system = Some(json!({
            "present": present,
            "name": entry,
            "percent": percent.unwrap_or(0),
            "status": status,
            "energyNow": round2(energy_now.unwrap_or(0.0) / 1_000_000.0),
            "energyFull": round2(energy_full.unwrap_or(0.0) / 1_000_000.0),
            "energyDesign": round2(energy_design.unwrap_or(0.0) / 1_000_000.0),
            "power": round2(power_w),
            "voltage": round2(voltage),
            "timeToEmpty": time_to_empty.unwrap_or(0),
            "timeToFull": time_to_full.unwrap_or(0),
            "cycles": read_i64(format!("{path}/cycle_count")).unwrap_or(0),
            "health": health,
            "acOnline": ac_online,
            "model": model,
            "technology": bounded_text(
                &read_text(format!("{path}/technology")).unwrap_or_default(),
                EXTERNAL_TEXT_LIMIT,
            ),
        }));
    }

    match system {
        None => {
            if peripherals.is_empty() {
                Value::Null
            } else {
                json!({ "present": false, "peripherals": peripherals })
            }
        }
        Some(mut sys) => {
            if sys["acOnline"].is_null() {
                let status = sys["status"].as_str().unwrap_or("");
                sys["acOnline"] = json!(matches!(status, "Charging" | "Full" | "Not charging"));
            }
            sys["peripherals"] = json!(peripherals);
            sys
        }
    }
}
