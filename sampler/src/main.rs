//! System sampler for the Omarchy Dials plugin.
//!
//! Emits one JSON object per line on stdout at a fixed interval, reading
//! procfs and sysfs directly. The output contract is shared with the Python
//! fallback (`sampler.py`), so the QML side never needs to know which one is
//! running.
//!
//! Control lines on stdin:
//!     detail 0|1|2    0 = none, 1 = top processes, 2 = every process
//!     focus <page>    page the panel shows; "network" adds per-process
//!                     traffic, "gpu" what each process uses of every card,
//!                     and "disks" the processes with files on each drive
//!     interval <sec>  change the sampling interval (0.1 – 30)
//!     pubip           refresh the public IP address in the background
//!     quit            exit
//!
//! Cheap counters (CPU, memory, network and disk rates) follow the interval.
//! Everything that walks many files (processes, sensors, battery, socket
//! mapping) is sampled at most once a second whatever the interval.
//!
//! Per-process figures are differences between two readings. When the panel
//! opens, the first reading is taken and the second follows after
//! `WARM_UP`, so the lists show real figures at once instead of zeros.

mod battery;
mod cpu;
mod disks;
mod gpu;
mod mem;
mod net;
mod pm;
mod power;
mod procs;
mod sensors;
mod util;

use serde_json::{json, Value};
use std::io::{BufReader, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

struct Control {
    interval: f64,
    detail: u8,
    focus: String,
    public_ip_requested: bool,
    stop: bool,
    /// Set by a control line that should take effect before the next tick.
    wake: bool,
}

/// Control state shared with the stdin listener, which wakes the sampling
/// loop so a new interval or detail level applies at once instead of after
/// the rest of the old interval.
type Shared = Arc<(Mutex<Control>, Condvar)>;

/// Gap between the two readings that start per-process figures.
const WARM_UP: Duration = Duration::from_millis(250);

fn bounded_output_line(
    payload: &Value,
    seq: u64,
    now: f64,
    elapsed: f64,
    interval: f64,
) -> Option<String> {
    let line = serde_json::to_string(payload).ok()?;
    if line.len() <= util::OUTPUT_LINE_LIMIT {
        return Some(line);
    }
    Some(
        json!({
            "seq": seq,
            "t": now,
            "elapsed": (elapsed * 1000.0).round() / 1000.0,
            "interval": interval,
            "errors": [format!(
                "sample exceeded {}-byte output limit",
                util::OUTPUT_LINE_LIMIT
            )],
        })
        .to_string(),
    )
}

fn listen(shared: Shared) {
    let (control, wake) = &*shared;
    let stdin = std::io::stdin();
    let mut input = BufReader::new(stdin.lock());
    while let Ok(Some(line)) = util::read_bounded_line(&mut input, util::CONTROL_LINE_LIMIT) {
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
            _ => continue,
        }
        state.wake = true;
        wake.notify_one();
    }
    // stdin closing is not a stop signal: the shell keeps it open for control
    // lines, and a broken stdout is what ends the sampler.
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Lets the Python entry point verify this build directly when requested.
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

    let shared: Shared = Arc::new((
        Mutex::new(Control {
            interval,
            detail: detail_flag,
            focus: focus_flag,
            public_ip_requested: false,
            stop: false,
            wake: false,
        }),
        Condvar::new(),
    ));
    if !once {
        let listener = Arc::clone(&shared);
        std::thread::spawn(move || listen(listener));
    }
    let (control, woken) = &*shared;

    let mut cpu = cpu::CpuSampler::new();
    let mut gpu = gpu::GpuSampler::new();
    let mut disks = disks::DiskSampler::new();
    let mut net = net::NetworkSampler::new();
    let mut sensors = sensors::SensorSampler::new();
    let mut power = power::PowerSampler::new();
    let mut procs = procs::ProcessSampler::new();

    // Prime the delta-based samplers so the first line already carries rates.
    let mut last = Instant::now();
    let _ = cpu.sample();
    let _ = disks.sample(1.0, util::now_secs());
    let _ = net.sample(1.0, util::now_secs(), detail_flag > 0);
    if detail_flag > 0 {
        let _ = procs.sample(1.0, detail_flag >= 2, None);
    }
    std::thread::sleep(Duration::from_secs_f64(if once {
        0.5
    } else {
        interval.min(1.0)
    }));

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
    let mut gpu_procs_cache: Option<std::collections::HashMap<String, Vec<Value>>> = None;
    let mut network_primed = false;
    let mut gpu_primed = false;

    loop {
        let (detail, focus, want_public, current_interval, stop) = {
            let mut state = match control.lock() {
                Ok(s) => s,
                Err(_) => break,
            };
            let want = state.public_ip_requested;
            state.public_ip_requested = false;
            (
                state.detail,
                state.focus.clone(),
                want,
                state.interval,
                state.stop,
            )
        };
        if stop {
            break;
        }
        let want_network = detail > 0 && focus == "network";
        let want_gpu = detail > 0 && focus == "gpu";
        let cold_procs = detail > 0 && last_procs.is_none();
        let cold_network = want_network && !network_primed;
        let cold_gpu = want_gpu && !gpu_primed;
        if cold_procs || cold_network || cold_gpu {
            if cold_procs {
                let _ = procs.sample(1.0, false, None);
                last_procs = Some(Instant::now());
            }
            if cold_network {
                let _ = procs.network_usage(false);
            }
            if cold_gpu {
                let _ = procs.gpu_usage(&gpu.integrated_slots(), Vec::new());
            }
            std::thread::sleep(WARM_UP);
        }
        let tick_start = Instant::now();
        let elapsed = tick_start.duration_since(last).as_secs_f64().max(0.02);
        last = tick_start;
        let now = util::now_secs();
        if want_public {
            net.fetch_public_ip();
        }

        // A freshly opened panel or page reads at once rather than waiting
        // for the next once-a-second pass.
        let slow_due = cold_procs
            || cold_network
            || cold_gpu
            || last_slow.is_none_or(|t| tick_start.duration_since(t).as_secs_f64() >= 0.95);
        if slow_due {
            sensors_cache = sensors.sample(now);
            battery_cache = battery::sample_battery();
            if detail > 0 {
                let read_at = Instant::now();
                let since = last_procs.map_or(elapsed, |t| {
                    read_at.duration_since(t).as_secs_f64().max(0.05)
                });
                // The Disks page lists the processes on each drive.
                let drives = (focus == "disks").then(|| disks.mount_keys());
                procs_cache = procs.sample(since, detail >= 2, drives);
                last_procs = Some(read_at);
            } else {
                procs.reset();
                procs_cache = Value::Null;
                last_procs = None;
            }
            connections_cache = if want_network {
                network_primed = true;
                procs.network_usage(detail >= 2)
            } else {
                network_primed = false;
                Value::Null
            };
            gpu_procs_cache = if want_gpu {
                gpu_primed = true;
                let nvidia = gpu.nvidia_processes();
                Some(procs.gpu_usage(&gpu.integrated_slots(), nvidia))
            } else {
                if gpu_primed {
                    procs.reset_gpu();
                }
                gpu_primed = false;
                None
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
        // "gpu" stays the primary card so older consumers keep working; the
        // full list travels alongside it.
        let mut gpus = gpu.sample_all();
        if let Some(lists) = &gpu_procs_cache {
            for card in &mut gpus {
                let id = card["id"].as_str().unwrap_or("").to_string();
                card["procs"] = Value::Array(lists.get(&id).cloned().unwrap_or_default());
            }
        }
        payload["gpu"] = gpus.first().cloned().unwrap_or(Value::Null);
        payload["gpus"] = Value::Array(gpus);
        payload["mem"] = mem::sample_memory();
        payload["disks"] = disks.sample(elapsed, now);
        let mut network = net.sample(elapsed, now, detail > 0);
        if let Value::Object(map) = &mut network {
            map.insert("procs".to_string(), connections_cache.clone());
        }
        payload["net"] = network;
        payload["sensors"] = sensors_cache.clone();
        payload["battery"] = battery_cache.clone();
        payload["power"] = power.sample();
        payload["procs"] = procs_cache.clone();

        let line = match bounded_output_line(&payload, seq, now, elapsed, current_interval) {
            Some(l) => l,
            None => continue,
        };
        if writeln!(out, "{line}").is_err() || out.flush().is_err() {
            break;
        }
        seq += 1;
        if once {
            break;
        }
        let spent = tick_start.elapsed().as_secs_f64();
        let pause = Duration::from_secs_f64((current_interval - spent).max(0.02));
        let Ok(state) = control.lock() else { break };
        let Ok((mut state, _)) = woken.wait_timeout_while(state, pause, |s| !s.wake) else {
            break;
        };
        state.wake = false;
    }

    gpu.stop();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_output_is_replaced_by_a_bounded_error_record() {
        let payload = json!({"blob": "x".repeat(util::OUTPUT_LINE_LIMIT + 1)});
        let line = bounded_output_line(&payload, 7, 1.0, 1.0, 1.0).unwrap();
        assert!(line.len() <= util::OUTPUT_LINE_LIMIT);
        assert!(line.contains("output limit"));
        assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["seq"], 7);
    }
}
