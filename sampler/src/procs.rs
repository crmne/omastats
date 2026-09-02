use crate::util::{rate, read_text, round1, run};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::time::{Duration, Instant};

const PROC_LIMIT: usize = 6;
const FULL_LIMIT: usize = 400;
const CONNECTION_LIMIT: usize = 12;

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
}

/// A readable name for a process: the kernel's 15-character comm, or the
/// executable's basename when comm looks truncated.
pub fn display_name(pid: u32, comm: &str) -> String {
    if comm.len() < 15 {
        return comm.to_string();
    }
    if let Some(cmdline) = read_text(format!("/proc/{pid}/cmdline")) {
        let first = cmdline.split('\0').next().unwrap_or("");
        let base = first.rsplit('/').next().unwrap_or("");
        if !base.is_empty() && (base.starts_with(&comm[..8.min(comm.len())]) || base.len() > comm.len()) {
            return base.to_string();
        }
    }
    comm.to_string()
}

impl ProcessSampler {
    pub fn new() -> Self {
        let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as u64;
        Self {
            prev: HashMap::new(),
            threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) as f64,
            clk_tck: if clk_tck > 0.0 { clk_tck } else { 100.0 },
            page_size: if page_size > 0 { page_size } else { 4096 },
            buffer: Vec::with_capacity(4096),
            names: HashMap::new(),
            sockets_prev: HashMap::new(),
            sockets_time: None,
        }
    }

    pub fn reset(&mut self) {
        self.prev.clear();
        self.names.clear();
    }

    fn read_small(&mut self, path: &str) -> Option<&[u8]> {
        self.buffer.clear();
        let mut file = fs::File::open(path).ok()?;
        file.read_to_end(&mut self.buffer).ok()?;
        Some(&self.buffer)
    }

    pub fn sample(&mut self, elapsed: f64, full: bool) -> Value {
        let mut current: HashMap<u32, Prev> = HashMap::new();
        let mut groups: HashMap<String, Group> = HashMap::new();
        let mut names: HashMap<u32, String> = HashMap::new();
        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(_) => return json!({ "cpu": [], "mem": [], "io": [] }),
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            let pid: u32 = match name.parse() {
                Ok(p) => p,
                Err(_) => continue,
            };
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
            let fields: Vec<&str> = stat[close + 2..].split_whitespace().collect();
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
            current.insert(pid, Prev { ticks, read_bytes, write_bytes });

            let prev = self.prev.get(&pid).copied();
            let (cpu, io_read, io_write) = match prev {
                Some(p) if elapsed > 0.0 => (
                    ticks.saturating_sub(p.ticks) as f64 / self.clk_tck / elapsed * 100.0 / self.threads,
                    rate(Some(read_bytes as f64), Some(p.read_bytes as f64), elapsed),
                    rate(Some(write_bytes as f64), Some(p.write_bytes as f64), elapsed),
                ),
                _ => (0.0, 0.0, 0.0),
            };

            // Names are stable per pid; resolve cmdline once.
            let display = match self.names.get(&pid) {
                Some(n) => n.clone(),
                None => display_name(pid, &comm),
            };
            names.insert(pid, display.clone());
            let group = groups.entry(display.clone()).or_insert_with(|| Group {
                name: display,
                pid,
                cpu: 0.0,
                mem: 0,
                read: 0.0,
                write: 0.0,
                count: 0,
            });
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

        list.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        let all: Option<Vec<Value>> = if full { Some(list.iter().take(FULL_LIMIT).map(|g| to_json(g)).collect()) } else { None };
        let cpu: Vec<Value> = list.iter().take(PROC_LIMIT).take_while(|g| g.cpu > 0.0).map(|g| to_json(g)).collect();
        list.sort_by(|a, b| b.mem.cmp(&a.mem));
        let mem: Vec<Value> = list.iter().take(PROC_LIMIT).take_while(|g| g.mem > 0).map(|g| to_json(g)).collect();
        list.sort_by(|a, b| (b.read + b.write).partial_cmp(&(a.read + a.write)).unwrap_or(std::cmp::Ordering::Equal));
        let io: Vec<Value> = list
            .iter()
            .take(PROC_LIMIT)
            .take_while(|g| g.read + g.write > 0.0)
            .map(|g| to_json(g))
            .collect();

        let mut out = json!({ "cpu": cpu, "mem": mem, "io": io, "total": groups.len() });
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
                current = Some((ino, Sock { sent: 0, recv: 0, cgroup, established: line.starts_with("ESTAB") }));
            }
        }
        if let Some((ino, sock)) = current.take() {
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
            for entry in entries.filter_map(|e| e.ok()) {
                let pid: u32 = match entry.file_name().to_string_lossy().parse() {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                let fds = match fs::read_dir(format!("/proc/{pid}/fd")) {
                    Ok(f) => f,
                    Err(_) => continue,
                };
                let mut name: Option<String> = None;
                for fd in fds.filter_map(|f| f.ok()) {
                    let target = match fs::read_link(fd.path()) {
                        Ok(t) => t.to_string_lossy().to_string(),
                        Err(_) => continue,
                    };
                    let inode = match target.strip_prefix("socket:[").and_then(|s| s.strip_suffix(']')) {
                        Some(i) if sockets.contains_key(i) => i.to_string(),
                        _ => continue,
                    };
                    if name.is_none() {
                        name = Some(match self.names.get(&pid) {
                            Some(n) => n.clone(),
                            None => {
                                let stat = read_text(format!("/proc/{pid}/stat")).unwrap_or_default();
                                match (stat.find('('), stat.rfind(')')) {
                                    (Some(o), Some(c)) if c > o => display_name(pid, &stat[o + 1..c]),
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
        let elapsed = self.sockets_time.map(|t| now.duration_since(t).as_secs_f64()).unwrap_or(0.0);
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
            let group = groups.entry(name.clone()).or_insert(Usage { name, pid, pids: HashSet::new(), connections: 0, rx: 0.0, tx: 0.0 });
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
        self.sockets_prev = sockets.iter().map(|(k, s)| (k.clone(), (s.sent, s.recv))).collect();
        self.sockets_time = Some(now);

        let mut list: Vec<&Usage> = groups.values().filter(|g| g.connections > 0 || g.rx + g.tx > 0.0).collect();
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
    let last = cgroup.rsplit('/').next().unwrap_or("").replace("\\x2d", "-");
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
            return parts[1..parts.len() - 1].join("-");
        }
        if parts.len() == 2 {
            return parts[1].to_string();
        }
    }
    if stem.is_empty() { "other".to_string() } else { stem.to_string() }
}
