use crate::util::{list_dir, read_pressure, read_text};
use serde_json::{json, Value};
use std::collections::HashMap;

pub fn sample_memory() -> Value {
    let mut info: HashMap<String, u64> = HashMap::new();
    for line in read_text("/proc/meminfo").unwrap_or_default().lines() {
        if let Some((key, rest)) = line.split_once(':') {
            if let Some(v) = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<u64>().ok())
            {
                info.insert(key.to_string(), v * 1024);
            }
        }
    }
    let get = |k: &str| info.get(k).copied().unwrap_or(0);
    let total = get("MemTotal");
    let free = get("MemFree");
    let available = info.get("MemAvailable").copied().unwrap_or(free);
    let buffers = get("Buffers");
    let cached = get("Cached") + get("SReclaimable");
    let shmem = get("Shmem");
    let swap_total = get("SwapTotal");
    let swap_used = swap_total.saturating_sub(get("SwapFree"));
    let apps = total
        .saturating_sub(free)
        .saturating_sub(buffers)
        .saturating_sub(cached);

    let mut zram_orig: u64 = 0;
    let mut zram_compr: u64 = 0;
    for dev in list_dir("/sys/block") {
        if dev.starts_with("zram") {
            let fields: Vec<u64> = read_text(format!("/sys/block/{dev}/mm_stat"))
                .unwrap_or_default()
                .split_whitespace()
                .filter_map(|v| v.parse().ok())
                .collect();
            if fields.len() >= 3 {
                zram_orig += fields[0];
                zram_compr += fields[1];
            }
        }
    }

    let (pressure_some, pressure_full) = read_pressure("memory");

    json!({
        "total": total,
        "free": free,
        "available": available,
        "used": total.saturating_sub(available),
        "apps": apps,
        "cached": (cached + buffers).saturating_sub(shmem),
        "shared": shmem,
        "swapTotal": swap_total,
        "swapUsed": swap_used,
        "compressed": zram_orig,
        "compressedSize": zram_compr,
        "pressureSome": pressure_some,
        "pressureFull": pressure_full,
    })
}
