use crate::gpu::NvidiaProcess;
use crate::util::{bounded_text, rate, read_text, round1, run, EXTERNAL_TEXT_LIMIT};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::time::{Duration, Instant};

const PROC_LIMIT: usize = 6;
const FULL_LIMIT: usize = 400;
const CONNECTION_LIMIT: usize = 12;
const PROCESS_SCAN_LIMIT: usize = 16_384;
const FD_SCAN_LIMIT: usize = 4096;
const PROC_FILE_LIMIT: u64 = 64 * 1024;
const SOCKET_SCAN_LIMIT: usize = 16_384;
/// Open files read per process when tying its I/O to drives.
const DRIVE_FD_LIMIT: usize = 256;

#[derive(Clone, Copy)]
struct Prev {
    ticks: u64,
    read_bytes: u64,
    write_bytes: u64,
}

struct Group {
    name: String,
    pid: u32,
    cpu: f64,
    mem: u64,
    read: f64,
    write: f64,
    count: u32,
    /// Drives this group has files open on, when drives were asked for.
    drives: HashSet<String>,
}

pub struct ProcessSampler {
    prev: HashMap<u32, Prev>,
    threads: f64,
    clk_tck: f64,
    page_size: u64,
    buffer: Vec<u8>,
    names: HashMap<u32, String>,
    sockets_prev: HashMap<String, (u64, u64)>,
    sockets_time: Option<Instant>,
    /// Busy counters of each DRM client, by (card, client id) and engine.
    gpu_prev: HashMap<(String, String), HashMap<String, EngineCounter>>,
    gpu_time: Option<Instant>,
}

/// An engine's busy counter. Most drivers count busy nanoseconds; xe counts
/// busy cycles against a total cycle counter instead.
#[derive(Clone, Copy, Default)]
struct EngineCounter {
    busy: u64,
    total: Option<u64>,
    capacity: u64,
}

/// One DRM client read from fdinfo.
#[derive(Default)]
struct DrmClient {
    pdev: String,
    id: String,
    engines: HashMap<String, EngineCounter>,
    /// Resident bytes by memory region (vram, gtt, local0, system0, ...).
    regions: HashMap<String, u64>,
}

/// "12 KiB", "2 MiB" or a bare byte count.
fn fdinfo_size(raw: &str) -> Option<u64> {
    let mut parts = raw.split_whitespace();
    let value: u64 = parts.next()?.parse().ok()?;
    let scale = match parts.next() {
        None => 1,
        Some("KiB") => 1 << 10,
        Some("MiB") => 1 << 20,
        Some("GiB") => 1 << 30,
        Some(_) => return None,
    };
    Some(value.saturating_mul(scale))
}

/// The DRM usage stats a driver writes into /proc/<pid>/fdinfo/<fd>, as
/// documented in the kernel's drm-usage-stats.
fn parse_drm_fdinfo(text: &str) -> Option<DrmClient> {
    let mut client = DrmClient::default();
    let mut legacy: HashMap<String, u64> = HashMap::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if key == "drm-pdev" {
            client.pdev = value.to_string();
        } else if key == "drm-client-id" {
            client.id = value.to_string();
        } else if let Some(engine) = key.strip_prefix("drm-engine-capacity-") {
            let capacity = value.parse().unwrap_or(1).max(1);
            client
                .engines
                .entry(engine.to_string())
                .or_default()
                .capacity = capacity;
        } else if let Some(engine) = key.strip_prefix("drm-engine-") {
            let busy = value.trim_end_matches("ns").trim().parse().unwrap_or(0);
            client.engines.entry(engine.to_string()).or_default().busy = busy;
        } else if let Some(engine) = key.strip_prefix("drm-total-cycles-") {
            let total = value.parse().ok();
            client.engines.entry(engine.to_string()).or_default().total = total;
        } else if let Some(engine) = key.strip_prefix("drm-cycles-") {
            let busy = value.parse().unwrap_or(0);
            client.engines.entry(engine.to_string()).or_default().busy = busy;
        } else if let Some(region) = key.strip_prefix("drm-resident-") {
            if let Some(bytes) = fdinfo_size(value) {
                client.regions.insert(region.to_string(), bytes);
            }
        } else if let Some(region) = key.strip_prefix("drm-memory-") {
            if let Some(bytes) = fdinfo_size(value) {
                legacy.insert(region.to_string(), bytes);
            }
        }
    }
    if client.pdev.is_empty() || client.id.is_empty() {
        return None;
    }
    if client.regions.is_empty() {
        client.regions = legacy;
    }
    Some(client)
}

/// The graphics memory a client holds: its dedicated video memory, plus the
/// system memory it maps when the card has no memory of its own.
fn client_memory(client: &DrmClient, integrated: bool) -> u64 {
    client
        .regions
        .iter()
        .filter(|(region, _)| {
            region.starts_with("vram")
                || region.starts_with("local")
                || (integrated
                    && (region.starts_with("gtt")
                        || region.starts_with("system")
                        || region.starts_with("stolen")))
        })
        .map(|(_, bytes)| *bytes)
        .sum()
}

/// How busy a client kept its busiest engine, in percent.
fn client_busy(
    now: &HashMap<String, EngineCounter>,
    before: Option<&HashMap<String, EngineCounter>>,
    elapsed: f64,
) -> f64 {
    let Some(before) = before else { return 0.0 };
    let mut busiest: f64 = 0.0;
    for (engine, counter) in now {
        let Some(prev) = before.get(engine) else {
            continue;
        };
        let busy = counter.busy.saturating_sub(prev.busy) as f64;
        let share = match (counter.total, prev.total) {
            (Some(total), Some(prev_total)) if total > prev_total => {
                busy / (total - prev_total) as f64
            }
            (None, None) if elapsed > 0.0 => busy / (elapsed * 1e9),
            _ => 0.0,
        };
        busiest = busiest.max(share / counter.capacity.max(1) as f64 * 100.0);
    }
    busiest.min(100.0)
}

/// A readable name for a process: the kernel's 15-character comm, or the
/// executable's basename when comm looks truncated.
/// The mount id line of /proc/<pid>/fdinfo/<fd>.
fn parse_mnt_id(fdinfo: &str) -> Option<u64> {
    fdinfo
        .lines()
        .find_map(|line| line.strip_prefix("mnt_id:"))
        .and_then(|v| v.trim().parse().ok())
}

pub fn display_name(pid: u32, comm: &str) -> String {
    if comm.len() < 15 {
        return comm.to_string();
    }
    let cmdline = read_text(format!("/proc/{pid}/cmdline"));
    name_from_cmdline(comm, cmdline.as_deref())
}

/// Pick between a truncated comm and the executable's basename. Both come
/// from another process, so the prefix check compares bytes: a multibyte
/// character may cross any byte offset.
fn name_from_cmdline(comm: &str, cmdline: Option<&str>) -> String {
    if let Some(cmdline) = cmdline {
        let first = cmdline.split('\0').next().unwrap_or("");
        let base = first.rsplit('/').next().unwrap_or("");
        let prefix = &comm.as_bytes()[..8.min(comm.len())];
        if !base.is_empty() && (base.as_bytes().starts_with(prefix) || base.len() > comm.len()) {
            return bounded_text(base, EXTERNAL_TEXT_LIMIT);
        }
    }
    bounded_text(comm, EXTERNAL_TEXT_LIMIT)
}

impl ProcessSampler {
    pub fn new() -> Self {
        let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as u64;
        Self {
            prev: HashMap::new(),
            threads: std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1) as f64,
            clk_tck: if clk_tck > 0.0 { clk_tck } else { 100.0 },
            page_size: if page_size > 0 { page_size } else { 4096 },
            buffer: Vec::with_capacity(4096),
            names: HashMap::new(),
            sockets_prev: HashMap::new(),
            sockets_time: None,
            gpu_prev: HashMap::new(),
            gpu_time: None,
        }
    }

    pub fn reset(&mut self) {
        self.prev.clear();
        self.names.clear();
    }

    pub fn reset_gpu(&mut self) {
        self.gpu_prev.clear();
        self.gpu_time = None;
    }

    fn process_name(&self, pid: u32) -> String {
        if let Some(name) = self.names.get(&pid) {
            return name.clone();
        }
        let stat = read_text(format!("/proc/{pid}/stat")).unwrap_or_default();
        match (stat.find('('), stat.rfind(')')) {
            (Some(o), Some(c)) if c > o => display_name(pid, &stat[o + 1..c]),
            _ => format!("pid {pid}"),
        }
    }

    /// What each process uses of every GPU, by the card's PCI address. DRM
    /// drivers (amdgpu, i915, xe, nouveau and others) publish each client's
    /// engine time and memory in /proc/<pid>/fdinfo, readable for the user's
    /// own processes; NVIDIA's rows come from nvidia-smi instead. A client
    /// shared between processes counts once, for the first one found.
    pub fn gpu_usage(
        &mut self,
        integrated: &[String],
        nvidia: Vec<NvidiaProcess>,
    ) -> HashMap<String, Vec<Value>> {
        let now = Instant::now();
        let elapsed = self
            .gpu_time
            .map(|t| now.duration_since(t).as_secs_f64())
            .unwrap_or(0.0);
        // Client ids are recycled, so a long gap starts over.
        let usable = elapsed > 0.0 && elapsed < 5.0;

        // (card, pid) -> (load, memory)
        let mut usage: HashMap<(String, u32), (f64, u64)> = HashMap::new();
        let mut counters: HashMap<(String, String), HashMap<String, EngineCounter>> =
            HashMap::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            let mut scanned = 0usize;
            for entry in entries.filter_map(Result::ok) {
                let pid: u32 = match entry.file_name().to_string_lossy().parse() {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                scanned += 1;
                if scanned > PROCESS_SCAN_LIMIT {
                    break;
                }
                let fds = match fs::read_dir(format!("/proc/{pid}/fd")) {
                    Ok(f) => f,
                    Err(_) => continue,
                };
                for fd in fds.filter_map(Result::ok).take(FD_SCAN_LIMIT) {
                    let is_drm = fs::read_link(fd.path())
                        .is_ok_and(|t| t.to_string_lossy().starts_with("/dev/dri/"));
                    if !is_drm {
                        continue;
                    }
                    let path = format!("/proc/{pid}/fdinfo/{}", fd.file_name().to_string_lossy());
                    let Some(text) = self.read_small(&path) else {
                        continue;
                    };
                    let Some(client) = parse_drm_fdinfo(&String::from_utf8_lossy(text)) else {
                        continue;
                    };
                    let key = (client.pdev.clone(), client.id.clone());
                    if counters.contains_key(&key) {
                        continue;
                    }
                    let busy = if usable {
                        client_busy(&client.engines, self.gpu_prev.get(&key), elapsed)
                    } else {
                        0.0
                    };
                    let memory = client_memory(&client, integrated.contains(&client.pdev));
                    let total = usage.entry((client.pdev.clone(), pid)).or_default();
                    total.0 += busy;
                    total.1 += memory;
                    counters.insert(key, client.engines);
                }
            }
        }
        self.gpu_prev = counters;
        self.gpu_time = Some(now);

        struct Usage {
            name: String,
            pid: u32,
            count: u32,
            util: f64,
            mem: f64,
        }
        let mut groups: HashMap<String, HashMap<String, Usage>> = HashMap::new();
        let mut add = |slot: String, pid: u32, name: String, util: f64, mem: f64| {
            let group = groups
                .entry(slot)
                .or_default()
                .entry(name.clone())
                .or_insert(Usage {
                    name,
                    pid,
                    count: 0,
                    util: 0.0,
                    mem: 0.0,
                });
            group.count += 1;
            group.util = (group.util + util).min(100.0);
            group.mem += mem;
        };
        for ((slot, pid), (util, mem)) in usage {
            add(slot, pid, self.process_name(pid), util, mem as f64);
        }
        for row in nvidia {
            let name = if fs::metadata(format!("/proc/{}", row.pid)).is_ok() {
                self.process_name(row.pid)
            } else {
                row.name
            };
            add(row.slot, row.pid, name, row.util, row.mem);
        }

        groups
            .into_iter()
            .map(|(slot, by_name)| {
                let mut list: Vec<Usage> = by_name
                    .into_values()
                    .filter(|g| g.util > 0.0 || g.mem > 0.0)
                    .collect();
                list.sort_by(|a, b| {
                    b.util
                        .partial_cmp(&a.util)
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then(
                            b.mem
                                .partial_cmp(&a.mem)
                                .unwrap_or(std::cmp::Ordering::Equal),
                        )
                        .then(a.name.cmp(&b.name))
                });
                let rows = list
                    .iter()
                    .take(PROC_LIMIT)
                    .map(|g| {
                        json!({
                            "name": g.name, "pid": g.pid, "count": g.count,
                            "util": round1(g.util), "mem": g.mem,
                        })
                    })
                    .collect();
                (slot, rows)
            })
            .collect()
    }

    fn read_small(&mut self, path: &str) -> Option<&[u8]> {
        self.buffer.clear();
        let file = fs::File::open(path).ok()?;
        file.take(PROC_FILE_LIMIT + 1)
            .read_to_end(&mut self.buffer)
            .ok()?;
        if self.buffer.len() as u64 > PROC_FILE_LIMIT {
            return None;
        }
        Some(&self.buffer)
    }

    /// Mount ids of the files a process has open, read from fdinfo so the
    /// files themselves are never touched: stat on a file on a dead network
    /// mount would block.
    fn open_mounts(&mut self, pid: u32) -> HashSet<u64> {
        let mut mounts = HashSet::new();
        let Ok(entries) = fs::read_dir(format!("/proc/{pid}/fdinfo")) else {
            return mounts;
        };
        for entry in entries.filter_map(Result::ok).take(DRIVE_FD_LIMIT) {
            let path = entry.path();
            let Some(text) = path.to_str().and_then(|p| self.read_small(p)) else {
                continue;
            };
            if let Some(id) = parse_mnt_id(&String::from_utf8_lossy(text)) {
                mounts.insert(id);
            }
        }
        mounts
    }

    /// Top processes by disk I/O and, given each mount's drive, the top
    /// processes with files open on each drive under "ioByDrive".
    pub fn sample(
        &mut self,
        elapsed: f64,
        full: bool,
        drives: Option<&HashMap<u64, String>>,
    ) -> Value {
        let mut current: HashMap<u32, Prev> = HashMap::new();
        let mut groups: HashMap<String, Group> = HashMap::new();
        let mut names: HashMap<u32, String> = HashMap::new();
        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(_) => return json!({ "cpu": [], "mem": [], "io": [] }),
        };
        let mut scanned = 0usize;
        for entry in entries.filter_map(Result::ok) {
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            let pid: u32 = match name.parse() {
                Ok(p) => p,
                Err(_) => continue,
            };
            scanned += 1;
            if scanned > PROCESS_SCAN_LIMIT {
                break;
            }
            let stat = match self.read_small(&format!("/proc/{pid}/stat")) {
                Some(s) => String::from_utf8_lossy(s).to_string(),
                None => continue,
            };
            let close = match stat.rfind(')') {
                Some(c) => c,
                None => continue,
            };
            let open = match stat.find('(') {
                Some(o) => o,
                None => continue,
            };
            let comm = stat[open + 1..close].to_string();
            let fields: Vec<&str> = stat
                .get(close + 2..)
                .unwrap_or("")
                .split_whitespace()
                .collect();
            if fields.len() < 22 || fields[0] == "Z" {
                continue;
            }
            let utime: u64 = fields[11].parse().unwrap_or(0);
            let stime: u64 = fields[12].parse().unwrap_or(0);
            let rss_pages: u64 = fields[21].parse().unwrap_or(0);
            let ticks = utime + stime;
            let rss = rss_pages * self.page_size;

            let mut read_bytes = 0u64;
            let mut write_bytes = 0u64;
            if let Some(io) = self.read_small(&format!("/proc/{pid}/io")) {
                let text = String::from_utf8_lossy(io);
                for line in text.lines() {
                    if let Some(v) = line.strip_prefix("read_bytes:") {
                        read_bytes = v.trim().parse().unwrap_or(0);
                    } else if let Some(v) = line.strip_prefix("write_bytes:") {
                        write_bytes = v.trim().parse().unwrap_or(0);
                        break;
                    }
                }
            }
            current.insert(
                pid,
                Prev {
                    ticks,
                    read_bytes,
                    write_bytes,
                },
            );

            let prev = self.prev.get(&pid).copied();
            let (cpu, io_read, io_write) = match prev {
                Some(p) if elapsed > 0.0 => (
                    ticks.saturating_sub(p.ticks) as f64 / self.clk_tck / elapsed * 100.0
                        / self.threads,
                    rate(Some(read_bytes as f64), Some(p.read_bytes as f64), elapsed),
                    rate(
                        Some(write_bytes as f64),
                        Some(p.write_bytes as f64),
                        elapsed,
                    ),
                ),
                _ => (0.0, 0.0, 0.0),
            };

            // Names are stable per pid; resolve cmdline once.
            let display = match self.names.get(&pid) {
                Some(n) => n.clone(),
                None => display_name(pid, &comm),
            };
            names.insert(pid, display.clone());
            let mut on_drives = HashSet::new();
            if let Some(drives) = drives.filter(|_| io_read + io_write > 0.0) {
                for mount in self.open_mounts(pid) {
                    if let Some(key) = drives.get(&mount) {
                        on_drives.insert(key.clone());
                    }
                }
            }
            let group = groups.entry(display.clone()).or_insert_with(|| Group {
                name: display,
                pid,
                cpu: 0.0,
                mem: 0,
                read: 0.0,
                write: 0.0,
                count: 0,
                drives: HashSet::new(),
            });
            group.drives.extend(on_drives);
            group.cpu += cpu.max(0.0);
            group.mem += rss;
            group.read += io_read;
            group.write += io_write;
            group.count += 1;
        }
        self.prev = current;
        self.names = names;

        let mut list: Vec<&Group> = groups.values().collect();
        let to_json = |g: &Group| {
            json!({
                "name": g.name, "pid": g.pid, "count": g.count,
                "cpu": round1(g.cpu), "mem": g.mem, "read": g.read, "write": g.write,
            })
        };

        list.sort_by(|a, b| {
            b.cpu
                .partial_cmp(&a.cpu)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let all: Option<Vec<Value>> = if full {
            Some(list.iter().take(FULL_LIMIT).map(|g| to_json(g)).collect())
        } else {
            None
        };
        let cpu: Vec<Value> = list
            .iter()
            .take(PROC_LIMIT)
            .take_while(|g| g.cpu > 0.0)
            .map(|g| to_json(g))
            .collect();
        list.sort_by_key(|group| std::cmp::Reverse(group.mem));
        let mem: Vec<Value> = list
            .iter()
            .take(PROC_LIMIT)
            .take_while(|g| g.mem > 0)
            .map(|g| to_json(g))
            .collect();
        list.sort_by(|a, b| {
            (b.read + b.write)
                .partial_cmp(&(a.read + a.write))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let io: Vec<Value> = list
            .iter()
            .take(PROC_LIMIT)
            .take_while(|g| g.read + g.write > 0.0)
            .map(|g| to_json(g))
            .collect();

        let mut out = json!({ "cpu": cpu, "mem": mem, "io": io, "total": groups.len() });
        if drives.is_some() {
            let mut by_drive: HashMap<&str, Vec<Value>> = HashMap::new();
            for group in list.iter().take_while(|g| g.read + g.write > 0.0) {
                for drive in &group.drives {
                    let rows = by_drive.entry(drive.as_str()).or_default();
                    if rows.len() < PROC_LIMIT {
                        rows.push(to_json(group));
                    }
                }
            }
            out["ioByDrive"] = json!(by_drive);
        }
        if let Some(all) = all {
            out["all"] = Value::Array(all);
        }
        out
    }

    /// Network traffic per process. The kernel keeps cumulative bytes_sent /
    /// bytes_received on every TCP socket and hands them to any user through
    /// socket diagnostics (`ss -ti`); differencing them per socket between
    /// calls gives real per-process rates without root. Sockets are tied to
    /// processes through /proc/<pid>/fd (own processes) or, failing that,
    /// named after their cgroup (system services). UDP, and so QUIC, carries
    /// no such counters and is not attributed.
    pub fn network_usage(&mut self, full: bool) -> Value {
        struct Sock {
            sent: u64,
            recv: u64,
            cgroup: String,
            established: bool,
        }
        let out = run("ss", &["-tineH"], Duration::from_secs(2));
        let mut sockets: HashMap<String, Sock> = HashMap::new();
        let mut current: Option<(String, Sock)> = None;
        for line in out.lines() {
            if line.starts_with(' ') || line.starts_with('\t') {
                if let Some((_, sock)) = current.as_mut() {
                    for tok in line.split_whitespace() {
                        if let Some(v) = tok.strip_prefix("bytes_sent:") {
                            sock.sent = v.parse().unwrap_or(0);
                        } else if let Some(v) = tok.strip_prefix("bytes_received:") {
                            sock.recv = v.parse().unwrap_or(0);
                        }
                    }
                }
                continue;
            }
            if let Some((ino, sock)) = current.take() {
                if sockets.len() >= SOCKET_SCAN_LIMIT {
                    self.sockets_prev.clear();
                    self.sockets_time = None;
                    return json!([]);
                }
                sockets.insert(ino, sock);
            }
            let mut ino = String::new();
            let mut cgroup = String::new();
            for tok in line.split_whitespace() {
                if let Some(v) = tok.strip_prefix("ino:") {
                    ino = v.to_string();
                } else if let Some(v) = tok.strip_prefix("cgroup:") {
                    cgroup = v.to_string();
                }
            }
            if !ino.is_empty() {
                current = Some((
                    ino,
                    Sock {
                        sent: 0,
                        recv: 0,
                        cgroup,
                        established: line.starts_with("ESTAB"),
                    },
                ));
            }
        }
        if let Some((ino, sock)) = current.take() {
            if sockets.len() >= SOCKET_SCAN_LIMIT {
                self.sockets_prev.clear();
                self.sockets_time = None;
                return json!([]);
            }
            sockets.insert(ino, sock);
        }
        if sockets.is_empty() {
            self.sockets_prev.clear();
            self.sockets_time = None;
            return json!([]);
        }

        // Socket inode -> owning process, for the processes we may inspect.
        let mut owner: HashMap<String, (u32, String)> = HashMap::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            let mut scanned = 0usize;
            for entry in entries.filter_map(Result::ok) {
                let pid: u32 = match entry.file_name().to_string_lossy().parse() {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                scanned += 1;
                if scanned > PROCESS_SCAN_LIMIT {
                    break;
                }
                let fds = match fs::read_dir(format!("/proc/{pid}/fd")) {
                    Ok(f) => f,
                    Err(_) => continue,
                };
                let mut name: Option<String> = None;
                for fd in fds.filter_map(Result::ok).take(FD_SCAN_LIMIT) {
                    let target = match fs::read_link(fd.path()) {
                        Ok(t) => t.to_string_lossy().to_string(),
                        Err(_) => continue,
                    };
                    let inode = match target
                        .strip_prefix("socket:[")
                        .and_then(|s| s.strip_suffix(']'))
                    {
                        Some(i) if sockets.contains_key(i) => i.to_string(),
                        _ => continue,
                    };
                    if name.is_none() {
                        name = Some(match self.names.get(&pid) {
                            Some(n) => n.clone(),
                            None => {
                                let stat =
                                    read_text(format!("/proc/{pid}/stat")).unwrap_or_default();
                                match (stat.find('('), stat.rfind(')')) {
                                    (Some(o), Some(c)) if c > o => {
                                        display_name(pid, &stat[o + 1..c])
                                    }
                                    _ => format!("pid {pid}"),
                                }
                            }
                        });
                    }
                    owner.insert(inode, (pid, name.clone().unwrap_or_default()));
                }
            }
        }

        let now = Instant::now();
        let elapsed = self
            .sockets_time
            .map(|t| now.duration_since(t).as_secs_f64())
            .unwrap_or(0.0);
        // A long gap means inode numbers may have been recycled; start over.
        let usable = elapsed > 0.0 && elapsed < 5.0;

        struct Usage {
            name: String,
            pid: u32,
            pids: HashSet<u32>,
            connections: u32,
            rx: f64,
            tx: f64,
        }
        let mut groups: HashMap<String, Usage> = HashMap::new();
        for (ino, sock) in &sockets {
            let (pid, name) = match owner.get(ino) {
                Some((p, n)) => (*p, n.clone()),
                None => (0, cgroup_label(&sock.cgroup)),
            };
            let group = groups.entry(name.clone()).or_insert(Usage {
                name,
                pid,
                pids: HashSet::new(),
                connections: 0,
                rx: 0.0,
                tx: 0.0,
            });
            group.pids.insert(pid);
            if sock.established {
                group.connections += 1;
            }
            if usable {
                if let Some((prev_sent, prev_recv)) = self.sockets_prev.get(ino) {
                    group.tx += sock.sent.saturating_sub(*prev_sent) as f64 / elapsed;
                    group.rx += sock.recv.saturating_sub(*prev_recv) as f64 / elapsed;
                }
            }
        }
        self.sockets_prev = sockets
            .iter()
            .map(|(k, s)| (k.clone(), (s.sent, s.recv)))
            .collect();
        self.sockets_time = Some(now);

        let mut list: Vec<&Usage> = groups
            .values()
            .filter(|g| g.connections > 0 || g.rx + g.tx > 0.0)
            .collect();
        list.sort_by(|a, b| {
            (b.rx + b.tx)
                .partial_cmp(&(a.rx + a.tx))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.connections.cmp(&a.connections))
                .then(a.name.cmp(&b.name))
        });
        let out: Vec<Value> = list
            .iter()
            .take(if full { FULL_LIMIT } else { CONNECTION_LIMIT })
            .map(|g| {
                json!({
                    "name": g.name, "pid": g.pid, "count": g.pids.len(),
                    "connections": g.connections, "rx": g.rx, "tx": g.tx,
                })
            })
            .collect();
        json!(out)
    }
}

/// Human label for a socket whose owner we cannot inspect, from its cgroup:
/// app-<launcher>-<name>-<id>.scope -> name, <name>.service -> name.
fn cgroup_label(cgroup: &str) -> String {
    let last = cgroup
        .rsplit('/')
        .next()
        .unwrap_or("")
        .replace("\\x2d", "-");
    if last.is_empty() {
        return "other".to_string();
    }
    let stem = last
        .trim_end_matches(".scope")
        .trim_end_matches(".service")
        .trim_end_matches(".mount")
        .trim_end_matches(".slice");
    if let Some(rest) = stem.strip_prefix("app-") {
        let parts: Vec<&str> = rest.split('-').collect();
        if parts.len() >= 3 {
            return bounded_text(&parts[1..parts.len() - 1].join("-"), EXTERNAL_TEXT_LIMIT);
        }
        if parts.len() == 2 {
            return bounded_text(parts[1], EXTERNAL_TEXT_LIMIT);
        }
    }
    if stem.is_empty() {
        "other".to_string()
    } else {
        bounded_text(stem, EXTERNAL_TEXT_LIMIT)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const AMDGPU: &str = "pos:\t0\nflags:\t02100002\ndrm-driver:\tamdgpu\ndrm-client-id:\t20516\n\
drm-pdev:\t0000:11:00.0\ndrm-total-vram:\t12 KiB\ndrm-resident-vram:\t12 KiB\n\
drm-resident-gtt:\t2 MiB\ndrm-resident-cpu:\t0\ndrm-memory-vram:\t12 KiB\n\
drm-engine-gfx:\t6438199656611 ns\ndrm-engine-compute:\t99404265 ns\n";

    #[test]
    fn fdinfo_names_the_mount_a_file_lives_on() {
        assert_eq!(
            parse_mnt_id("pos:\t0\nflags:\t0100002\nmnt_id:\t32\nino:\t1234\n"),
            Some(32)
        );
        assert_eq!(parse_mnt_id("pos:\t0\n"), None);
    }

    #[test]
    fn amdgpu_fdinfo_gives_engines_and_regions() {
        let client = parse_drm_fdinfo(AMDGPU).expect("a DRM client");
        assert_eq!(client.pdev, "0000:11:00.0");
        assert_eq!(client.id, "20516");
        assert_eq!(client.engines["gfx"].busy, 6_438_199_656_611);
        assert_eq!(client.regions["vram"], 12 * 1024);
        assert_eq!(client_memory(&client, false), 12 * 1024);
        assert_eq!(client_memory(&client, true), 12 * 1024 + 2 * 1024 * 1024);
    }

    #[test]
    fn a_file_without_a_client_is_not_a_drm_client() {
        assert!(parse_drm_fdinfo("pos:\t0\nflags:\t02\n").is_none());
        assert!(parse_drm_fdinfo("drm-driver:\tamdgpu\ndrm-pdev:\t0000:11:00.0\n").is_none());
    }

    #[test]
    fn busy_time_becomes_the_busiest_engines_share() {
        let counter = |busy| EngineCounter {
            busy,
            total: None,
            capacity: 1,
        };
        let before = HashMap::from([
            ("gfx".to_string(), counter(1_000_000_000)),
            ("compute".to_string(), counter(0)),
        ]);
        let now = HashMap::from([
            ("gfx".to_string(), counter(1_250_000_000)),
            ("compute".to_string(), counter(100_000_000)),
        ]);
        assert_eq!(client_busy(&now, Some(&before), 1.0), 25.0);
        assert_eq!(client_busy(&now, None, 1.0), 0.0);
    }

    #[test]
    fn xe_cycles_are_measured_against_total_cycles() {
        let text = "drm-client-id:\t3\ndrm-pdev:\t0000:00:02.0\n\
drm-cycles-rcs:\t500\ndrm-total-cycles-rcs:\t1000\ndrm-engine-capacity-rcs:\t1\n";
        let before = parse_drm_fdinfo(text).unwrap().engines;
        let later = "drm-client-id:\t3\ndrm-pdev:\t0000:00:02.0\n\
drm-cycles-rcs:\t800\ndrm-total-cycles-rcs:\t2000\n";
        let now = parse_drm_fdinfo(later).unwrap().engines;
        assert_eq!(client_busy(&now, Some(&before), 1.0), 30.0);
    }

    #[test]
    fn engine_capacity_divides_the_share() {
        let before = HashMap::from([(
            "vcn".to_string(),
            EngineCounter {
                busy: 0,
                total: None,
                capacity: 2,
            },
        )]);
        let now = HashMap::from([(
            "vcn".to_string(),
            EngineCounter {
                busy: 1_000_000_000,
                total: None,
                capacity: 2,
            },
        )]);
        assert_eq!(client_busy(&now, Some(&before), 1.0), 50.0);
    }

    #[test]
    fn fdinfo_sizes_carry_their_unit() {
        assert_eq!(fdinfo_size("0"), Some(0));
        assert_eq!(fdinfo_size("12 KiB"), Some(12 * 1024));
        assert_eq!(fdinfo_size("3 MiB"), Some(3 << 20));
        assert_eq!(fdinfo_size("1 GiB"), Some(1 << 30));
        assert_eq!(fdinfo_size("lots"), None);
    }

    #[test]
    fn truncated_comm_with_multibyte_character_at_prefix_end() {
        // 15 bytes, with "é" occupying bytes 7 and 8: byte 8 is not a boundary.
        let comm = "abcdefgé123456";
        assert_eq!(comm.len(), 15);
        assert!(!comm.is_char_boundary(8));
        assert_eq!(name_from_cmdline(comm, None), comm);
        assert_eq!(name_from_cmdline(comm, Some("")), comm);
        assert_eq!(
            name_from_cmdline(comm, Some("/usr/bin/other\0--flag")),
            comm
        );
        assert_eq!(
            name_from_cmdline(comm, Some("/opt/abcdefgé1234567890\0--flag")),
            "abcdefgé1234567890"
        );
        assert_eq!(
            name_from_cmdline(comm, Some("/opt/abcdefg\u{e9}\0")),
            "abcdefgé"
        );
    }

    #[test]
    fn truncated_comm_prefers_longer_executable_name() {
        let comm = "longprocessname";
        assert_eq!(
            name_from_cmdline(comm, Some("/usr/bin/longprocessname-helper\0x")),
            "longprocessname-helper"
        );
        assert_eq!(name_from_cmdline(comm, Some("/usr/bin/sh\0x")), comm);
    }
}
