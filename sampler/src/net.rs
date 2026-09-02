use crate::util::{rate, read_i64, read_text, run, which};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Default, Clone)]
struct Addresses {
    ipv4: Vec<String>,
    ipv6: Vec<String>,
}

#[derive(Default, Clone)]
struct Wifi {
    ssid: Option<String>,
    dbm: Option<i64>,
    freq: Option<f64>,
    bitrate: Option<f64>,
}

struct PublicIp {
    value: String,
    stamp: f64,
    inflight: bool,
}

pub struct NetworkSampler {
    prev: HashMap<String, (u64, u64)>,
    addresses: HashMap<String, Addresses>,
    addr_stamp: f64,
    wifi: HashMap<String, Wifi>,
    wifi_stamp: f64,
    public: Arc<Mutex<PublicIp>>,
}

fn default_iface() -> String {
    for line in read_text("/proc/net/route").unwrap_or_default().lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 4 && parts[1] == "00000000" {
            if let Ok(flags) = i64::from_str_radix(parts[3], 16) {
                if flags & 2 != 0 {
                    return parts[0].to_string();
                }
            }
        }
    }
    for line in read_text("/proc/net/ipv6_route").unwrap_or_default().lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 10 && parts[0].bytes().all(|b| b == b'0') && parts[0].len() == 32 && parts[1] == "00" {
            return parts[9].to_string();
        }
    }
    String::new()
}

impl NetworkSampler {
    pub fn new() -> Self {
        Self {
            prev: HashMap::new(),
            addresses: HashMap::new(),
            addr_stamp: 0.0,
            wifi: HashMap::new(),
            wifi_stamp: 0.0,
            public: Arc::new(Mutex::new(PublicIp { value: String::new(), stamp: 0.0, inflight: false })),
        }
    }

    fn refresh_addresses(&mut self) {
        self.addresses.clear();
        if !which("ip") {
            return;
        }
        let raw = run("ip", &["-j", "addr"], Duration::from_secs(2));
        let parsed: Value = serde_json::from_str(&raw).unwrap_or(Value::Array(Vec::new()));
        for iface in parsed.as_array().cloned().unwrap_or_default() {
            let name = iface["ifname"].as_str().unwrap_or("").to_string();
            let mut addrs = Addresses::default();
            for addr in iface["addr_info"].as_array().cloned().unwrap_or_default() {
                if addr["scope"].as_str() != Some("global") {
                    continue;
                }
                let local = addr["local"].as_str().unwrap_or("").to_string();
                match addr["family"].as_str() {
                    Some("inet") => addrs.ipv4.push(local),
                    Some("inet6") if !addr["temporary"].as_bool().unwrap_or(false) => addrs.ipv6.push(local),
                    _ => {}
                }
            }
            self.addresses.insert(name, addrs);
        }
    }

    fn refresh_wifi(&mut self, ifaces: &[String]) {
        self.wifi.clear();
        if !which("iw") {
            return;
        }
        for name in ifaces {
            let out = run("iw", &["dev", name, "link"], Duration::from_secs(2));
            let mut info = Wifi::default();
            for line in out.lines() {
                let line = line.trim();
                if let Some(ssid) = line.strip_prefix("SSID:") {
                    info.ssid = Some(ssid.trim().to_string());
                } else if let Some(rest) = line.strip_prefix("signal:") {
                    info.dbm = rest.split_whitespace().next().and_then(|v| v.parse().ok());
                } else if let Some(rest) = line.strip_prefix("freq:") {
                    info.freq = rest.split_whitespace().next().and_then(|v| v.parse().ok());
                } else if let Some(rest) = line.strip_prefix("tx bitrate:") {
                    info.bitrate = rest.split_whitespace().next().and_then(|v| v.parse().ok());
                }
            }
            self.wifi.insert(name.clone(), info);
        }
    }

    pub fn fetch_public_ip(&self) {
        {
            let mut state = match self.public.lock() {
                Ok(s) => s,
                Err(_) => return,
            };
            if state.inflight {
                return;
            }
            state.inflight = true;
        }
        let shared = Arc::clone(&self.public);
        std::thread::spawn(move || {
            let mut result = String::new();
            if which("curl") {
                for url in ["https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"] {
                    let out = run("curl", &["-s", "--max-time", "5", url], Duration::from_secs(7));
                    let candidate = out.trim();
                    if !candidate.is_empty()
                        && candidate.len() <= 64
                        && candidate.bytes().all(|b| b.is_ascii_hexdigit() || b == b'.' || b == b':')
                    {
                        result = candidate.to_string();
                        break;
                    }
                }
            }
            if let Ok(mut state) = shared.lock() {
                state.value = result;
                state.stamp = crate::util::now_secs();
                state.inflight = false;
            }
        });
    }

    pub fn sample(&mut self, elapsed: f64, now: f64, detail: bool) -> Value {
        let mut current: HashMap<String, (u64, u64)> = HashMap::new();
        for line in read_text("/proc/net/dev").unwrap_or_default().lines().skip(2) {
            let (name, rest) = match line.split_once(':') {
                Some(v) => v,
                None => continue,
            };
            let name = name.trim();
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if name == "lo" || parts.len() < 16 {
                continue;
            }
            let rx: u64 = parts[0].parse().unwrap_or(0);
            let tx: u64 = parts[8].parse().unwrap_or(0);
            current.insert(name.to_string(), (rx, tx));
        }
        if now - self.addr_stamp > if detail { 10.0 } else { 30.0 } {
            self.refresh_addresses();
            self.addr_stamp = now;
        }
        let wireless: Vec<String> = current
            .keys()
            .filter(|n| Path::new(&format!("/sys/class/net/{n}/wireless")).is_dir())
            .cloned()
            .collect();
        if !wireless.is_empty() && now - self.wifi_stamp > if detail { 10.0 } else { 30.0 } {
            self.refresh_wifi(&wireless);
            self.wifi_stamp = now;
        }
        let default = default_iface();
        let mut ifaces: Vec<Value> = Vec::new();
        let mut order: Vec<(bool, bool, String)> = Vec::new();
        let mut total_rx = 0.0;
        let mut total_tx = 0.0;
        let mut default_rx = 0.0;
        let mut default_tx = 0.0;
        let mut online = false;
        let mut any_up = false;

        for (name, (rx_total, tx_total)) in &current {
            let prev = self.prev.get(name);
            let rx = rate(Some(*rx_total as f64), prev.map(|p| p.0 as f64), elapsed);
            let tx = rate(Some(*tx_total as f64), prev.map(|p| p.1 as f64), elapsed);
            let state = read_text(format!("/sys/class/net/{name}/operstate")).unwrap_or_default();
            let up = state == "up" || (state == "unknown" && *rx_total > 0);
            let is_default = *name == default;
            if !is_default
                && ["veth", "docker", "br-", "virbr", "vmnet", "tap"].iter().any(|p| name.starts_with(p))
            {
                continue;
            }
            let speed = read_i64(format!("/sys/class/net/{name}/speed")).filter(|s| *s > 0).unwrap_or(0);
            let addrs = self.addresses.get(name).cloned().unwrap_or_default();
            let wifi = self.wifi.get(name).cloned().unwrap_or_default();
            let mut entry = json!({
                "name": name,
                "up": up,
                "default": is_default,
                "wireless": wireless.contains(name),
                "speed": speed,
                "rx": rx,
                "tx": tx,
                "rxTotal": rx_total,
                "txTotal": tx_total,
                "ipv4": addrs.ipv4,
                "ipv6": addrs.ipv6,
            });
            if let Some(ssid) = wifi.ssid {
                entry["ssid"] = json!(ssid);
            }
            if let Some(dbm) = wifi.dbm {
                entry["dbm"] = json!(dbm);
            }
            if let Some(freq) = wifi.freq {
                entry["freq"] = json!(freq);
            }
            if let Some(bitrate) = wifi.bitrate {
                entry["bitrate"] = json!(bitrate);
            }
            if up {
                total_rx += rx;
                total_tx += tx;
                any_up = true;
            }
            if is_default {
                default_rx = rx;
                default_tx = tx;
                online = up;
            }
            order.push((!is_default, !up, name.clone()));
            ifaces.push(entry);
        }
        self.prev = current;

        let mut indexed: Vec<(usize, &(bool, bool, String))> = order.iter().enumerate().collect();
        indexed.sort_by(|a, b| a.1.cmp(b.1));
        let sorted: Vec<Value> = indexed.iter().map(|(i, _)| ifaces[*i].clone()).collect();

        let public_ip = self.public.lock().map(|p| p.value.clone()).unwrap_or_default();
        json!({
            "ifaces": sorted,
            "default": default,
            "rx": if default.is_empty() { total_rx } else { default_rx },
            "tx": if default.is_empty() { total_tx } else { default_tx },
            "online": online || any_up,
            "publicIp": public_ip,
        })
    }
}
