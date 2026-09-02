use crate::util::{hwmon_dirs, list_dir, read_i64, read_text, round1};
use serde_json::{json, Value};

const TEMP_PREFERENCE: [&str; 6] = ["k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal", "acpitz"];

pub struct CpuSampler {
    prev_total: Option<Vec<u64>>,
    prev_cores: Option<Vec<Vec<u64>>>,
    model: String,
    cores: usize,
    threads: usize,
    efficiency: Vec<usize>,
    max_mhz: i64,
    temp_source: Option<String>,
    freq_paths: Vec<String>,
}

fn cpu_list(raw: &str) -> Vec<usize> {
    let mut out = Vec::new();
    for part in raw.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((lo, hi)) = part.split_once('-') {
            if let (Ok(lo), Ok(hi)) = (lo.parse::<usize>(), hi.parse::<usize>()) {
                out.extend(lo..=hi);
            }
        } else if let Ok(v) = part.parse::<usize>() {
            out.push(v);
        }
    }
    out
}

fn split(now: &[u64], prev: Option<&Vec<u64>>) -> (f64, f64, f64, f64) {
    let prev = match prev {
        Some(p) if now.len() >= 8 && p.len() >= 8 => p,
        _ => return (0.0, 0.0, 0.0, 0.0),
    };
    let delta: Vec<f64> = now.iter().zip(prev.iter()).map(|(n, p)| n.saturating_sub(*p) as f64).collect();
    let total: f64 = delta[..8].iter().sum();
    if total <= 0.0 {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let user = (delta[0] + delta[1]) / total * 100.0;
    let system = (delta[2] + delta[5] + delta[6] + delta[7]) / total * 100.0;
    let iowait = delta[4] / total * 100.0;
    let idle = delta[3] / total * 100.0;
    (user, system, iowait, 100.0 - idle - iowait)
}

impl CpuSampler {
    pub fn new() -> Self {
        let cpuinfo = read_text("/proc/cpuinfo").unwrap_or_default();
        let mut model = String::new();
        for line in cpuinfo.lines() {
            if line.to_lowercase().starts_with("model name") {
                if let Some((_, rest)) = line.split_once(':') {
                    model = rest.trim().to_string();
                }
                break;
            }
        }
        model = model
            .replace("(R)", "")
            .replace("(TM)", "")
            .replace("(tm)", "")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");

        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        let mut core_ids = std::collections::HashSet::new();
        for i in 0..threads {
            let core = read_text(format!("/sys/devices/system/cpu/cpu{i}/topology/core_id"));
            let pkg = read_text(format!("/sys/devices/system/cpu/cpu{i}/topology/physical_package_id"));
            if let Some(core) = core {
                if !core.is_empty() {
                    core_ids.insert((pkg.unwrap_or_default(), core));
                }
            }
        }
        let cores = if core_ids.is_empty() { threads } else { core_ids.len() };
        let efficiency = cpu_list(&read_text("/sys/devices/cpu_atom/cpus").unwrap_or_default());
        let max_mhz = read_i64("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
            .map(|khz| (khz as f64 / 1000.0).round() as i64)
            .unwrap_or(0);
        let freq_paths: Vec<String> = (0..threads)
            .map(|i| format!("/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq"))
            .filter(|p| std::path::Path::new(p).exists())
            .collect();

        Self {
            prev_total: None,
            prev_cores: None,
            model,
            cores,
            threads,
            efficiency,
            max_mhz,
            temp_source: Self::find_temp_source(),
            freq_paths,
        }
    }

    fn find_temp_source() -> Option<String> {
        let mut found: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for hw in hwmon_dirs() {
            let base = format!("/sys/class/hwmon/{hw}");
            let name = match read_text(format!("{base}/name")) {
                Some(n) if !n.is_empty() => n,
                _ => continue,
            };
            for entry in list_dir(&base) {
                if !(entry.starts_with("temp") && entry.ends_with("_input")) {
                    continue;
                }
                let key = &entry[..entry.len() - 6];
                let label = read_text(format!("{base}/{key}_label")).unwrap_or_default().to_lowercase();
                let path = format!("{base}/{entry}");
                let slot = if (name == "k10temp" || name == "zenpower") && (label == "tctl" || label == "tdie" || label.is_empty()) {
                    Some(name.clone())
                } else if name == "coretemp" && label.starts_with("package") {
                    Some(name.clone())
                } else if name == "cpu_thermal" || name == "soc_thermal" || name == "acpitz" {
                    Some(name.clone())
                } else if label == "cpu" {
                    Some("labelled".to_string())
                } else {
                    None
                };
                if let Some(slot) = slot {
                    found.entry(slot).or_insert(path);
                }
            }
        }
        for pref in TEMP_PREFERENCE {
            if let Some(path) = found.get(pref) {
                return Some(path.clone());
            }
        }
        if let Some(path) = found.get("labelled") {
            return Some(path.clone());
        }
        for zone in list_dir("/sys/class/thermal") {
            if !zone.starts_with("thermal_zone") {
                continue;
            }
            let ztype = read_text(format!("/sys/class/thermal/{zone}/type")).unwrap_or_default().to_lowercase();
            if ztype.contains("cpu") || ztype.contains("x86_pkg") || ztype.contains("soc") {
                return Some(format!("/sys/class/thermal/{zone}/temp"));
            }
        }
        None
    }

    pub fn sample(&mut self) -> Value {
        let stat = read_text("/proc/stat").unwrap_or_default();
        let mut totals: Option<Vec<u64>> = None;
        let mut cores: Vec<Vec<u64>> = Vec::new();
        for line in stat.lines() {
            if !line.starts_with("cpu") {
                continue;
            }
            let mut parts = line.split_whitespace();
            let head = parts.next().unwrap_or("");
            let values: Vec<u64> = parts.filter_map(|v| v.parse().ok()).collect();
            if head == "cpu" {
                totals = Some(values);
            } else {
                cores.push(values);
            }
        }
        let empty = Vec::new();
        let (user, system, iowait, busy) = split(totals.as_ref().unwrap_or(&empty), self.prev_total.as_ref());
        let per_core: Vec<f64> = match &self.prev_cores {
            Some(prev) if prev.len() == cores.len() => cores
                .iter()
                .zip(prev.iter())
                .map(|(now, p)| round1(split(now, Some(p)).3))
                .collect(),
            _ => cores.iter().map(|_| 0.0).collect(),
        };
        self.prev_total = totals;
        self.prev_cores = Some(cores);

        let mut mhz: i64 = 0;
        if !self.freq_paths.is_empty() {
            let values: Vec<i64> = self.freq_paths.iter().filter_map(|p| read_i64(p)).filter(|v| *v > 0).collect();
            if !values.is_empty() {
                mhz = (values.iter().sum::<i64>() as f64 / values.len() as f64 / 1000.0).round() as i64;
            }
        }
        if mhz == 0 {
            let cpuinfo = read_text("/proc/cpuinfo").unwrap_or_default();
            let speeds: Vec<f64> = cpuinfo
                .lines()
                .filter(|l| l.starts_with("cpu MHz"))
                .filter_map(|l| l.split_once(':').and_then(|(_, v)| v.trim().parse::<f64>().ok()))
                .collect();
            if !speeds.is_empty() {
                mhz = (speeds.iter().sum::<f64>() / speeds.len() as f64).round() as i64;
            }
        }

        let loadavg = read_text("/proc/loadavg").unwrap_or_default();
        let load: Vec<f64> = loadavg.split_whitespace().take(3).filter_map(|v| v.parse().ok()).collect();
        let load = if load.len() == 3 { load } else { vec![0.0, 0.0, 0.0] };
        let uptime = read_text("/proc/uptime")
            .and_then(|s| s.split_whitespace().next().and_then(|v| v.parse::<f64>().ok()))
            .unwrap_or(0.0);
        let temp = self
            .temp_source
            .as_ref()
            .and_then(|p| read_i64(p))
            .map(|raw| round1(raw as f64 / 1000.0));

        json!({
            "total": round1(busy),
            "user": round1(user),
            "system": round1(system),
            "iowait": round1(iowait),
            "cores": per_core,
            "mhz": mhz,
            "maxMhz": self.max_mhz,
            "load": load,
            "uptime": uptime,
            "model": self.model,
            "coreCount": self.cores,
            "threadCount": self.threads,
            "efficiency": self.efficiency,
            "temp": temp,
        })
    }
}
