//! System sampler for the Omarchy Dials plugin.
//!
//! Emits one JSON object per line on stdout at a fixed interval, reading
//! procfs and sysfs directly. The output contract is shared with the Python
//! fallback (`sampler.py`), so the QML side never needs to know which one is
//! running.
//!
//! Control lines on stdin:
//!     detail 0|1|2    0 = none, 1 = top processes, 2 = every process
//!     focus <page>    page the panel shows; "network" adds per-process traffic
//!     interval <sec>  change the sampling interval (0.1 – 30)
//!     pubip           refresh the public IP address in the background
//!     quit            exit
//!
//! Cheap counters (CPU, memory, network and disk rates) follow the interval.
//! Everything that walks many files (processes, sensors, battery, socket
//! mapping) is sampled at most once a second whatever the interval.

mod battery;
mod cpu;
mod disks;
mod gpu;
mod mem;
mod net;
mod procs;
mod sensors;
mod util;

use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Control {
    interval: f64,
    detail: u8,
    focus: String,
    public_ip_requested: bool,
    stop: bool,
}

fn listen(control: Arc<Mutex<Control>>) {
    let stdin = std::io::stdin();
    for line in stdin.lock().lines().map_while(Result::ok) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.is_empty() {
            continue;
        }
        let mut state = match control.lock() {
            Ok(s) => s,
            Err(_) => return,
        };
        match parts[0] {
            "detail" if parts.len() > 1 => {
                state.detail = match parts[1] {
                    "2" | "full" | "all" => 2,
                    "1" | "true" | "on" => 1,
                    _ => 0,
                }
            }
            "focus" if parts.len() > 1 => state.focus = parts[1].to_string(),
            "interval" if parts.len() > 1 => {
                if let Ok(v) = parts[1].parse::<f64>() {
                    state.interval = v.clamp(0.1, 30.0);
                }
            }
            "pubip" => state.public_ip_requested = true,
            "quit" => state.stop = true,
            _ => {}
        }
    }
    // stdin closing is not a stop signal: the shell keeps it open for control
    // lines, and a broken stdout is what ends the sampler.
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Lets sampler.sh check that this build runs on this machine before
    // committing to it; a binary for another architecture fails here and
    // the Python sampler takes over.
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("omastats-sampler {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let mut interval = 1.0;
    if let Some(pos) = args.iter().position(|a| a == "--interval") {
        if let Some(v) = args.get(pos + 1).and_then(|v| v.parse::<f64>().ok()) {
            interval = v.clamp(0.1, 30.0);
        }
    }
    let once = args.iter().any(|a| a == "--once");
    let detail_flag: u8 = if args.iter().any(|a| a == "--full") {
        2
    } else if args.iter().any(|a| a == "--detail") {
        1
    } else {
        0
    };
    let focus_flag = args
        .iter()
        .position(|a| a == "--focus")
        .and_then(|p| args.get(p + 1).cloned())
        .unwrap_or_default();

    let control = Arc::new(Mutex::new(Control {
        interval,
        detail: detail_flag,
        focus: focus_flag,
        public_ip_requested: false,
        stop: false,
    }));
    if !once {
        let shared = Arc::clone(&control);
        std::thread::spawn(move || listen(shared));
    }

    let mut cpu = cpu::CpuSampler::new();
    let mut gpu = gpu::GpuSampler::new();
    let mut disks = disks::DiskSampler::new();
    let mut net = net::NetworkSampler::new();
    let mut sensors = sensors::SensorSampler::new();
    let mut procs = procs::ProcessSampler::new();

    // Prime the delta-based samplers so the first line already carries rates.
    let mut last = Instant::now();
    let _ = cpu.sample();
    let _ = disks.sample(1.0, util::now_secs());
    let _ = net.sample(1.0, util::now_secs(), detail_flag > 0);
    if detail_flag > 0 {
        let _ = procs.sample(1.0, detail_flag >= 2);
    }
    std::thread::sleep(Duration::from_secs_f64(if once { 0.5 } else { interval.min(1.0) }));

    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut seq: u64 = 0;

    // Slow sections are refreshed at most once a second and reused between.
    let mut last_slow: Option<Instant> = None;
    let mut last_procs: Option<Instant> = None;
    let mut sensors_cache = Value::Null;
    let mut battery_cache = Value::Null;
    let mut procs_cache = Value::Null;
    let mut connections_cache = Value::Null;

    loop {
        let (detail, focus, want_public, current_interval, stop) = {
            let mut state = match control.lock() {
                Ok(s) => s,
                Err(_) => break,
            };
            let want = state.public_ip_requested;
            state.public_ip_requested = false;
            (state.detail, state.focus.clone(), want, state.interval, state.stop)
        };
        if stop {
            break;
        }
        let tick_start = Instant::now();
        let elapsed = tick_start.duration_since(last).as_secs_f64().max(0.02);
        last = tick_start;
        let now = util::now_secs();
        if want_public {
            net.fetch_public_ip();
        }

        let slow_due = last_slow.map_or(true, |t| tick_start.duration_since(t).as_secs_f64() >= 0.95);
        if slow_due {
            sensors_cache = sensors.sample(now);
            battery_cache = battery::sample_battery();
            if detail > 0 {
                let since = last_procs.map_or(elapsed, |t| tick_start.duration_since(t).as_secs_f64().max(0.05));
                procs_cache = procs.sample(since, detail >= 2);
                last_procs = Some(tick_start);
            } else {
                procs.reset();
                procs_cache = Value::Null;
                last_procs = None;
            }
            connections_cache = if detail > 0 && focus == "network" {
                procs.network_usage(detail >= 2)
            } else {
                Value::Null
            };
            last_slow = Some(tick_start);
        }

        let mut payload = json!({
            "seq": seq,
            "t": now,
            "elapsed": (elapsed * 1000.0).round() / 1000.0,
            "interval": current_interval,
            "errors": [],
        });
        payload["cpu"] = cpu.sample();
        payload["gpu"] = gpu.sample();
        payload["mem"] = mem::sample_memory();
        payload["disks"] = disks.sample(elapsed, now);
        let mut network = net.sample(elapsed, now, detail > 0);
        if let Value::Object(map) = &mut network {
            map.insert("procs".to_string(), connections_cache.clone());
        }
        payload["net"] = network;
        payload["sensors"] = sensors_cache.clone();
        payload["battery"] = battery_cache.clone();
        payload["procs"] = procs_cache.clone();

        let line = match serde_json::to_string(&payload) {
            Ok(l) => l,
            Err(_) => continue,
        };
        if writeln!(out, "{line}").is_err() || out.flush().is_err() {
            break;
        }
        seq += 1;
        if once {
            break;
        }
        let spent = tick_start.elapsed().as_secs_f64();
        std::thread::sleep(Duration::from_secs_f64((current_interval - spent).max(0.02)));
    }

    gpu.stop();
}
