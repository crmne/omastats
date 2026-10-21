use crate::util::{
    bounded_text, hwmon_dirs, is_whole_disk, list_dir, rate, read_i64, read_pressure, read_text,
    round1, round2, run, EXTERNAL_TEXT_LIMIT,
};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::path::Path;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

const REAL_FS: [&str; 22] = [
    "ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk",
    "zfs", "jfs", "reiserfs", "apfs", "hfsplus", "bcachefs", "udf", "iso9660", "msdos", "erofs",
    "squashfs",
];
/// Filesystems served over the network. Their source is `host:/path`,
/// `//host/share` or a remote name, never a block device.
const NETWORK_FS: [&str; 11] = [
    "nfs",
    "nfs4",
    "cifs",
    "smb3",
    "smbfs",
    "ceph",
    "glusterfs",
    "9p",
    "fuse.sshfs",
    "fuse.rclone",
    "davfs",
];
/// Filesystems that can be trimmed. FAT and exFAT take discards too, but
/// fstrim skips nothing there, so they count.
const TRIM_FS: [&str; 9] = [
    "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs3", "bcachefs", "jfs",
];
const VOLUME_LIMIT: usize = 256;
const PATH_TEXT_LIMIT: usize = 4096;
/// How long a network filesystem may take to report its space before it is
/// treated as unreachable. A hung NFS server blocks statvfs indefinitely.
const NETWORK_STATVFS_TIMEOUT: Duration = Duration::from_millis(800);

#[derive(Clone)]
struct Volume {
    mount: String,
    device: String,
    fstype: String,
    size: u64,
    used: u64,
    avail: u64,
    disk: String,
    model: String,
    rotational: bool,
    removable: bool,
    /// "internal", "external" or "network".
    kind: &'static str,
    /// The drive a click selects: the disk, or the source for a network mount.
    key: String,
    checks: Vec<Value>,
}

/// Cumulative counters for one disk from /proc/diskstats.
#[derive(Clone, Copy, Default)]
struct Counters {
    read_bytes: u64,
    write_bytes: u64,
    /// Requests completed: reads, writes, discards and flushes.
    ios: u64,
    /// Milliseconds those requests spent from issue to completion.
    ticks: u64,
    /// Milliseconds with at least one request in flight.
    busy: u64,
    /// Milliseconds spent by every request in flight, summed: its rate is the
    /// average queue length.
    queued: u64,
}

/// One line of /proc/self/mountinfo.
#[derive(Clone, Debug, PartialEq)]
struct MountEntry {
    id: u64,
    mount: String,
    fstype: String,
    source: String,
    /// Per-mount options, then the filesystem's own.
    options: Vec<String>,
}

pub struct DiskSampler {
    prev: HashMap<String, Counters>,
    ids: HashMap<String, String>,
    volumes: Vec<Volume>,
    volumes_stamp: f64,
    drive_temps: HashMap<String, String>,
    /// Mount id -> the key of the drive it lives on.
    mount_keys: HashMap<u64, String>,
    /// Network mounts whose statvfs has not returned yet.
    stuck: Arc<Mutex<HashSet<String>>>,
}

fn statvfs(path: &str) -> Option<(u64, u64, u64)> {
    let c_path = CString::new(path).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };
    if rc != 0 {
        return None;
    }
    let frsize = stat.f_frsize as u64;
    let size = stat.f_blocks as u64 * frsize;
    let free = stat.f_bfree as u64 * frsize;
    let avail = stat.f_bavail as u64 * frsize;
    Some((size, size.saturating_sub(free), avail))
}

/// Space and first leaf vdev for each imported ZFS pool.
#[derive(Default)]
struct ZfsPools {
    space: HashMap<String, (u64, u64)>,
    leaves: HashMap<String, String>,
}

impl ZfsPools {
    fn query() -> Self {
        Self {
            space: parse_zfs_space(&run(
                "zfs",
                &["list", "-Hp", "-d", "0", "-o", "name,used,avail"],
                Duration::from_secs(2),
            )),
            leaves: parse_zpool_leaves(&run(
                "zpool",
                &["list", "-HPv", "-o", "name"],
                Duration::from_secs(2),
            )),
        }
    }
}

/// Vdev classes `zpool list -v` lists after a pool's data vdevs. None of them
/// holds the pool's data, so their devices never stand for the pool.
const ZPOOL_CLASSES: [&str; 5] = ["logs", "cache", "spare", "special", "dedup"];

/// The pool behind a ZFS mount, or None for any other mount. A ZFS mount names
/// a dataset such as `tank/home`, not a device. Snapshot mounts have no pool.
fn zfs_pool<'a>(fstype: &str, device: &'a str) -> Option<&'a str> {
    if fstype != "zfs" || device.contains('@') {
        return None;
    }
    device.split('/').next().filter(|pool| !pool.is_empty())
}

/// Parse a byte count the way `zfs list -p` prints it: plain ASCII digits.
fn parse_bytes(raw: &str) -> Option<u64> {
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    raw.parse().ok()
}

/// Parse `zfs list -Hp -d 0 -o name,used,avail` into pool -> (used, avail).
fn parse_zfs_space(raw: &str) -> HashMap<String, (u64, u64)> {
    raw.lines()
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let name = fields
                .next()
                .filter(|n| !n.is_empty() && n.len() <= PATH_TEXT_LIMIT)?;
            let used = parse_bytes(fields.next()?)?;
            let avail = parse_bytes(fields.next()?)?;
            Some((name.to_string(), (used, avail)))
        })
        .collect()
}

/// Parse `zpool list -HPv -o name` into pool -> the path of its first data
/// device. Pools are unindented and their vdevs indented.
fn parse_zpool_leaves(raw: &str) -> HashMap<String, String> {
    let mut leaves = HashMap::new();
    let mut pool: Option<&str> = None;
    for line in raw.lines() {
        let name = line.trim();
        if name.is_empty() || name.len() > PATH_TEXT_LIMIT {
            continue;
        }
        if ZPOOL_CLASSES.contains(&name) {
            pool = None;
        } else if !line.starts_with(char::is_whitespace) {
            pool = Some(name);
        } else if let (Some(pool), true) = (pool, name.starts_with('/')) {
            leaves
                .entry(pool.to_string())
                .or_insert_with(|| name.to_string());
        }
    }
    leaves
}

/// Rank of a `/dev/disk/by-id` link as a disk's saved identity: links built
/// from the model and serial first, then bus-level identifiers such as a WWN
/// or EUI. Links to partitions and to stacked devices never name a disk.
fn by_id_rank(link: &str) -> Option<usize> {
    if link.contains("-part") || ["dm-", "md-", "lvm-"].iter().any(|p| link.starts_with(p)) {
        return None;
    }
    if link.starts_with("nvme-eui.") || link.starts_with("nvme-nvme.") {
        return Some(6);
    }
    Some(
        ["nvme-", "ata-", "usb-", "mmc-", "virtio-", "scsi-"]
            .iter()
            .position(|p| link.starts_with(p))
            .unwrap_or(7),
    )
}

/// Pick each disk's identity from its by-id links. The kernel names disks in
/// the order their controllers probe, so `nvme0n1` can be a different drive
/// after a reboot; the model-and-serial link stays with the drive.
fn pick_disk_ids(links: &[(String, String)]) -> HashMap<String, String> {
    let mut best: HashMap<String, (usize, usize, String)> = HashMap::new();
    for (link, disk) in links {
        let Some(rank) = by_id_rank(link) else {
            continue;
        };
        let candidate = (rank, link.len(), link.clone());
        match best.get(disk) {
            Some(current) if *current <= candidate => {}
            _ => {
                best.insert(disk.clone(), candidate);
            }
        }
    }
    best.into_iter()
        .map(|(disk, (_, _, link))| (disk, link))
        .collect()
}

fn scan_disk_ids() -> HashMap<String, String> {
    let dir = "/dev/disk/by-id";
    let links: Vec<(String, String)> = list_dir(dir)
        .into_iter()
        .filter(|link| link.len() <= EXTERNAL_TEXT_LIMIT)
        .filter_map(|link| {
            let target = std::fs::read_link(format!("{dir}/{link}")).ok()?;
            let disk = target.file_name()?.to_string_lossy().to_string();
            Some((link, disk))
        })
        .collect();
    pick_disk_ids(&links)
}

fn parent_disk(device: &str) -> String {
    let real = std::fs::canonicalize(device)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| device.to_string());
    let mut name = Path::new(&real)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    for _ in 0..4 {
        let slaves = format!("/sys/block/{name}/slaves");
        let entries = list_dir(&slaves);
        if let Some(first) = entries.into_iter().next() {
            name = first;
            continue;
        }
        break;
    }
    if Path::new(&format!("/sys/block/{name}")).is_dir() {
        return name;
    }
    // Strip a partition suffix: nvme0n1p2 -> nvme0n1, mmcblk0p1 -> mmcblk0, sda1 -> sda.
    if let Some(pos) = name.rfind('p') {
        if (name.starts_with("nvme") || name.starts_with("mmcblk"))
            && name[pos + 1..].bytes().all(|b| b.is_ascii_digit())
        {
            let candidate = &name[..pos];
            if Path::new(&format!("/sys/block/{candidate}")).is_dir() {
                return candidate.to_string();
            }
        }
    }
    let trimmed = name.trim_end_matches(|c: char| c.is_ascii_digit());
    if !trimmed.is_empty() && Path::new(&format!("/sys/block/{trimmed}")).is_dir() {
        return trimmed.to_string();
    }
    for disk in list_dir("/sys/block") {
        if Path::new(&format!("/sys/block/{disk}/{name}")).is_dir() {
            return disk;
        }
    }
    name
}

/// Undo the octal escapes mountinfo uses for space, tab, newline and backslash.
fn unescape_mount(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let code = bytes.get(i + 1..i + 4).unwrap_or_default();
        if bytes[i] == b'\\'
            && code.len() == 3
            && code[0] <= b'3'
            && code.iter().all(|b| (b'0'..=b'7').contains(b))
        {
            out.push((code[0] - b'0') << 6 | (code[1] - b'0') << 3 | (code[2] - b'0'));
            i += 4;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn parse_mountinfo(raw: &str) -> Vec<MountEntry> {
    raw.lines()
        .filter_map(|line| {
            let (head, tail) = line.split_once(" - ")?;
            let head: Vec<&str> = head.split(' ').collect();
            let mut tail = tail.split(' ');
            if head.len() < 6 {
                return None;
            }
            let fstype = tail.next()?.to_string();
            let source = unescape_mount(tail.next()?);
            let super_options = tail.next().unwrap_or("");
            let options = head[5]
                .split(',')
                .chain(super_options.split(','))
                .filter(|o| !o.is_empty())
                .map(str::to_string)
                .collect();
            Some(MountEntry {
                id: head[0].parse().ok()?,
                mount: unescape_mount(head[4]),
                fstype,
                source,
                options,
            })
        })
        .collect()
}

fn is_network_fs(fstype: &str) -> bool {
    NETWORK_FS.contains(&fstype)
}

/// Whether a disk sits outside the machine: on USB, marked removable, or
/// behind a PCIe port the firmware marks external (Thunderbolt and USB4
/// enclosures).
fn is_external(disk: &str) -> bool {
    if read_i64(format!("/sys/block/{disk}/removable")) == Some(1) {
        return true;
    }
    let Ok(real) = std::fs::canonicalize(format!("/sys/block/{disk}")) else {
        return false;
    };
    let path = real.to_string_lossy();
    if path.contains("/usb") {
        return true;
    }
    real.ancestors()
        .take_while(|dir| dir.starts_with("/sys/devices/"))
        .any(|dir| read_text(dir.join("removable")).as_deref() == Some("removable"))
}

/// statvfs for a network mount on a helper thread, so a dead server costs
/// one stuck thread instead of the sampler. A mount still stuck from an
/// earlier call is skipped rather than given another thread.
fn statvfs_bounded(path: &str, stuck: &Arc<Mutex<HashSet<String>>>) -> Option<(u64, u64, u64)> {
    if stuck.lock().ok()?.contains(path) {
        return None;
    }
    let (tx, rx) = mpsc::channel();
    let owned = path.to_string();
    let pending = Arc::clone(stuck);
    pending.lock().ok()?.insert(owned.clone());
    std::thread::spawn(move || {
        let result = statvfs(&owned);
        if let Ok(mut set) = pending.lock() {
            set.remove(&owned);
        }
        let _ = tx.send(result);
    });
    rx.recv_timeout(NETWORK_STATVFS_TIMEOUT).ok().flatten()
}

/// The device-mapper devices a volume sits on, top first, with the device
/// each one passes requests to.
fn dm_chain(device: &str) -> Vec<(String, String)> {
    let real = std::fs::canonicalize(device)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| device.to_string());
    let mut name = Path::new(&real)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut chain = Vec::new();
    for _ in 0..4 {
        if !name.starts_with("dm-") {
            break;
        }
        let Some(lower) = list_dir(format!("/sys/block/{name}/slaves"))
            .into_iter()
            .next()
        else {
            break;
        };
        chain.push((name.clone(), lower.clone()));
        name = lower;
    }
    chain
}

/// Largest discard a block device accepts, from its queue (a partition reads
/// its disk's).
fn discard_max(name: &str) -> Option<u64> {
    let own = format!("/sys/block/{name}/queue/discard_max_bytes");
    let value = read_text(&own).or_else(|| {
        read_text(format!(
            "/sys/class/block/{name}/../queue/discard_max_bytes"
        ))
    })?;
    value.trim().parse().ok()
}

/// The filesystem UUID of a block device, from /dev/disk/by-uuid.
fn device_uuid(device: &str) -> Option<String> {
    let real = std::fs::canonicalize(device).ok()?;
    let dir = "/dev/disk/by-uuid";
    list_dir(dir)
        .into_iter()
        .find(|uuid| std::fs::canonicalize(format!("{dir}/{uuid}")).ok().as_ref() == Some(&real))
}

/// A name that is safe to hand to a fix as one argument.
fn plain_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.:/".contains(&b))
        && !value.contains("..")
}

/// Problems the volume has that slow it down, each with what a fix needs.
/// `trim_timer` is whether fstrim.timer is enabled, None when unknown.
fn volume_checks(volume: &Volume, options: &[String], trim_timer: Option<bool>) -> Vec<Value> {
    let mut checks = Vec::new();
    if volume.kind == "network" {
        return checks;
    }
    let mut trim_blocked = false;
    for (dm, lower) in dm_chain(&volume.device) {
        let (Some(top), Some(below)) = (discard_max(&dm), discard_max(&lower)) else {
            continue;
        };
        if top == 0 && below > 0 {
            trim_blocked = true;
            let name = read_text(format!("/sys/block/{dm}/dm/name")).unwrap_or_default();
            let uuid = read_text(format!("/sys/block/{dm}/dm/uuid")).unwrap_or_default();
            let luks2 = uuid.starts_with("CRYPT-LUKS2-");
            let args = if luks2 && plain_name(&name) {
                vec![name.clone()]
            } else {
                Vec::new()
            };
            checks.push(json!({
                "id": "trim-blocked",
                "layer": bounded_text(&name, EXTERNAL_TEXT_LIMIT),
                "fix": if args.is_empty() { Value::Null } else { json!("allow-discards") },
                "args": args,
            }));
            break;
        }
    }
    let ssd = !volume.rotational && !volume.disk.is_empty();
    let discard = options
        .iter()
        .any(|o| o == "discard" || o.starts_with("discard="));
    if ssd
        && !trim_blocked
        && !discard
        && trim_timer == Some(false)
        && TRIM_FS.contains(&volume.fstype.as_str())
    {
        checks.push(json!({ "id": "trim-off", "fix": "enable-fstrim", "args": [] }));
    }
    if volume.fstype == "vfat" || volume.fstype == "msdos" {
        let slow: Vec<&str> = ["flush", "sync", "dirsync"]
            .into_iter()
            .filter(|flag| options.iter().any(|o| o == flag))
            .collect();
        if !slow.is_empty() {
            let udisks =
                volume.mount.starts_with("/run/media/") || volume.mount.starts_with("/media/");
            let uuid = device_uuid(&volume.device).filter(|u| plain_name(u));
            let fixable = udisks && uuid.is_some() && plain_name(&volume.device);
            checks.push(json!({
                "id": "fat-flush",
                "flags": slow,
                "fix": if fixable { json!("udisks-no-flush") } else { Value::Null },
                "args": if fixable { vec![uuid.unwrap_or_default(), volume.device.clone()] } else { Vec::new() },
            }));
        }
    }
    checks
}

impl DiskSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            prev: HashMap::new(),
            ids: HashMap::new(),
            volumes: Vec::new(),
            volumes_stamp: 0.0,
            drive_temps: HashMap::new(),
            mount_keys: HashMap::new(),
            stuck: Arc::new(Mutex::new(HashSet::new())),
        };
        sampler.scan_drive_temps();
        sampler
    }

    fn scan_drive_temps(&mut self) {
        let blocks = list_dir("/sys/block");
        for hw in hwmon_dirs() {
            let base = format!("/sys/class/hwmon/{hw}");
            let name = read_text(format!("{base}/name")).unwrap_or_default();
            if name != "nvme" && name != "drivetemp" {
                continue;
            }
            let device = format!("{base}/device");
            let mut block: Option<String> = None;
            for entry in list_dir(&device) {
                if is_whole_disk(&entry) {
                    block = Some(entry);
                    break;
                }
            }
            if block.is_none() {
                if let Some(first) = list_dir(format!("{device}/block")).into_iter().next() {
                    block = Some(first);
                }
            }
            if block.is_none() {
                // nvme hwmon lives on the controller; namespaces are named after it.
                if let Ok(real) = std::fs::canonicalize(&device) {
                    let ctrl = real
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default();
                    if !ctrl.is_empty() {
                        block = blocks.iter().find(|b| b.starts_with(&ctrl)).cloned();
                    }
                }
            }
            if let Some(block) = block {
                self.drive_temps
                    .insert(block, format!("{base}/temp1_input"));
            }
        }
    }

    fn scan_volumes(&mut self) -> Vec<Volume> {
        let mut volumes: HashMap<String, Volume> = HashMap::new();
        let mut options: HashMap<String, Vec<String>> = HashMap::new();
        let mut mount_keys = HashMap::new();
        let mounts = parse_mountinfo(&read_text("/proc/self/mountinfo").unwrap_or_default());
        let zfs = if mounts
            .iter()
            .any(|m| zfs_pool(&m.fstype, &m.source).is_some())
        {
            ZfsPools::query()
        } else {
            ZfsPools::default()
        };
        // A disk's identity and place are the same for every volume on it.
        let mut disk_info: HashMap<String, (String, bool, bool, bool)> = HashMap::new();
        let trim_timer = if mounts.iter().any(|m| TRIM_FS.contains(&m.fstype.as_str())) {
            match run(
                "systemctl",
                &["is-enabled", "fstrim.timer"],
                Duration::from_secs(2),
            )
            .trim()
            {
                "" => None,
                state => Some(state == "enabled"),
            }
        } else {
            None
        };
        for entry in &mounts {
            if volumes.len() >= VOLUME_LIMIT {
                break;
            }
            let fstype = entry.fstype.as_str();
            let device = entry.source.as_str();
            let mount = &entry.mount;
            let network = is_network_fs(fstype);
            // Every dataset in a pool shares the pool's space, so the pool is the
            // volume, at its shortest mount path.
            let pool = zfs_pool(fstype, device);
            if !(REAL_FS.contains(&fstype) || network)
                || (pool.is_none() && !network && !device.starts_with('/'))
                || device.is_empty()
                || device.len() > PATH_TEXT_LIMIT
                || mount.len() > PATH_TEXT_LIMIT
            {
                continue;
            }
            if [
                "/proc",
                "/sys",
                "/dev",
                "/run/user",
                "/var/lib/docker",
                "/snap",
            ]
            .iter()
            .any(|p| mount.starts_with(p))
            {
                continue;
            }
            let device = pool.unwrap_or(device);
            let disk = if network {
                String::new()
            } else {
                match pool {
                    Some(p) => zfs
                        .leaves
                        .get(p)
                        .map(|leaf| parent_disk(leaf))
                        .unwrap_or_default(),
                    None => parent_disk(device),
                }
            };
            let key = if disk.is_empty() {
                device.to_string()
            } else {
                disk.clone()
            };
            // Bind mounts and subvolumes count toward their drive's processes
            // even though only the shortest mount is listed.
            mount_keys.insert(entry.id, key.clone());
            if let Some(existing) = volumes.get(device) {
                if existing.mount.len() <= mount.len() {
                    continue;
                }
            }
            let space = if network {
                statvfs_bounded(mount, &self.stuck)
            } else {
                statvfs(mount)
            };
            let (mut size, mut used, mut avail) = match space {
                Some(v) => v,
                None => continue,
            };
            if size < 64 * 1024 * 1024 {
                continue;
            }
            if let Some(&(pool_used, pool_avail)) = pool.and_then(|p| zfs.space.get(p)) {
                size = pool_used.saturating_add(pool_avail);
                used = pool_used;
                avail = pool_avail;
            }
            let (model, rotational, removable, external) = disk_info
                .entry(disk.clone())
                .or_insert_with(|| {
                    if disk.is_empty() {
                        return (String::new(), false, false, false);
                    }
                    let model = bounded_text(
                        &read_text(format!("/sys/block/{disk}/device/model"))
                            .filter(|m| !m.is_empty())
                            .or_else(|| read_text(format!("/sys/block/{disk}/device/name")))
                            .unwrap_or_default()
                            .split_whitespace()
                            .collect::<Vec<_>>()
                            .join(" "),
                        EXTERNAL_TEXT_LIMIT,
                    );
                    (
                        model,
                        read_i64(format!("/sys/block/{disk}/queue/rotational")) == Some(1),
                        read_i64(format!("/sys/block/{disk}/removable")) == Some(1),
                        is_external(&disk),
                    )
                })
                .clone();
            options.insert(device.to_string(), entry.options.clone());
            volumes.insert(
                device.to_string(),
                Volume {
                    mount: mount.clone(),
                    device: device.to_string(),
                    fstype: bounded_text(fstype, 64),
                    size,
                    used,
                    avail,
                    rotational,
                    removable,
                    kind: if network {
                        "network"
                    } else if external {
                        "external"
                    } else {
                        "internal"
                    },
                    key,
                    disk,
                    model,
                    checks: Vec::new(),
                },
            );
        }
        for volume in volumes.values_mut() {
            let opts = options.get(&volume.device).cloned().unwrap_or_default();
            volume.checks = volume_checks(volume, &opts, trim_timer);
        }
        self.mount_keys = mount_keys;
        let mut list: Vec<Volume> = volumes.into_values().collect();
        list.sort_by(|a, b| (a.mount != "/", &a.mount).cmp(&(b.mount != "/", &b.mount)));
        list
    }

    /// Mount id -> drive key, for tying processes' open files to drives.
    pub fn mount_keys(&self) -> &HashMap<u64, String> {
        &self.mount_keys
    }

    pub fn sample(&mut self, elapsed: f64, now: f64) -> Value {
        if now - self.volumes_stamp > 10.0 {
            self.volumes = self.scan_volumes();
            self.volumes_stamp = now;
        }
        let mut current: HashMap<String, Counters> = HashMap::new();
        for line in read_text("/proc/diskstats").unwrap_or_default().lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 14 {
                continue;
            }
            let name = parts[2];
            if !is_whole_disk(name) {
                continue;
            }
            if read_i64(format!("/sys/block/{name}/size")).unwrap_or(0) <= 0 {
                continue;
            }
            current.insert(name.to_string(), parse_diskstats(&parts));
        }

        // Disks come and go with hotplug; look their identities up again then.
        if current.len() != self.prev.len() || current.keys().any(|k| !self.prev.contains_key(k)) {
            self.ids = scan_disk_ids();
        }

        let mut per_disk = Map::new();
        let mut temps: HashMap<String, Option<f64>> = HashMap::new();
        let mut total_read = 0.0;
        let mut total_write = 0.0;
        for (name, counters) in &current {
            let prev = self.prev.get(name);
            let read_rate = rate(
                Some(counters.read_bytes as f64),
                prev.map(|p| p.read_bytes as f64),
                elapsed,
            );
            let write_rate = rate(
                Some(counters.write_bytes as f64),
                prev.map(|p| p.write_bytes as f64),
                elapsed,
            );
            let load = prev.map(|p| DiskLoad::between(p, counters, elapsed));
            let temp = self
                .drive_temps
                .get(name)
                .and_then(read_i64)
                .filter(|t| *t > 0)
                .map(|t| round1(t as f64 / 1000.0));
            temps.insert(name.clone(), temp);
            let id = self.ids.get(name).unwrap_or(name);
            per_disk.insert(
                name.clone(),
                json!({
                    "id": id,
                    "read": read_rate,
                    "write": write_rate,
                    "temp": temp,
                    "latency": load.and_then(|l| l.latency),
                    "queue": load.map(|l| l.queue),
                    "busy": load.map(|l| l.busy),
                }),
            );
            total_read += read_rate;
            total_write += write_rate;
        }
        self.prev = current;

        let volumes: Vec<Value> = self
            .volumes
            .iter()
            .map(|v| {
                json!({
                    "mount": v.mount,
                    "device": v.device,
                    "fstype": v.fstype,
                    "size": v.size,
                    "used": v.used,
                    "avail": v.avail,
                    "disk": v.disk,
                    "key": v.key,
                    "kind": v.kind,
                    "model": v.model,
                    "rotational": v.rotational,
                    "removable": v.removable,
                    "temp": temps.get(&v.disk).copied().flatten(),
                    "checks": v.checks,
                })
            })
            .collect();

        let (pressure_some, pressure_full) = read_pressure("io");
        json!({
            "volumes": volumes,
            "read": total_read,
            "write": total_write,
            "perDisk": Value::Object(per_disk),
            "pressureSome": pressure_some,
            "pressureFull": pressure_full,
        })
    }
}

fn parse_diskstats(parts: &[&str]) -> Counters {
    let field = |i: usize| {
        parts
            .get(i)
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0)
    };
    // Fields from 14 on (discards, then flushes) exist on kernels since 4.18
    // and 5.5.
    Counters {
        read_bytes: field(5) * 512,
        write_bytes: field(9) * 512,
        ios: field(3) + field(7) + field(14) + field(18),
        ticks: field(6) + field(10) + field(17) + field(19),
        busy: field(12),
        queued: field(13),
    }
}

/// How hard a disk worked between two readings.
#[derive(Clone, Copy, Debug, PartialEq)]
struct DiskLoad {
    /// Average milliseconds per request, None when nothing completed.
    latency: Option<f64>,
    /// Average number of requests waiting or in service.
    queue: f64,
    /// Percent of the time with requests in flight.
    busy: f64,
}

impl DiskLoad {
    fn between(prev: &Counters, now: &Counters, elapsed: f64) -> Self {
        let ios = now.ios.saturating_sub(prev.ios);
        let ticks = now.ticks.saturating_sub(prev.ticks);
        let window = (elapsed * 1000.0).max(1.0);
        Self {
            latency: (ios > 0).then(|| round2(ticks as f64 / ios as f64)),
            queue: round2(now.queued.saturating_sub(prev.queued) as f64 / window),
            busy: round1((now.busy.saturating_sub(prev.busy) as f64 / window * 100.0).min(100.0)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datasets_share_their_pool_and_snapshots_have_none() {
        assert_eq!(zfs_pool("zfs", "tank/ROOT/root"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank/ROOT/home"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank/ROOT/root@daily"), None);
        assert_eq!(zfs_pool("ext4", "/dev/sda1"), None);
    }

    #[test]
    fn zfs_space_is_read_per_pool() {
        let raw = "tank\t849022443520\t123012960256\nbad line\nneg\t-5\t1\nsep\t1_000\t1\n";
        let space = parse_zfs_space(raw);
        assert_eq!(space.len(), 1);
        assert_eq!(space["tank"], (849022443520, 123012960256));
    }

    #[test]
    fn disks_are_identified_by_model_and_serial() {
        let links: Vec<(String, String)> = [
            ("nvme-eui.0025385991b33317", "nvme1n1"),
            (
                "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X_1",
                "nvme1n1",
            ),
            (
                "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X",
                "nvme1n1",
            ),
            (
                "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X-part1",
                "nvme1n1p1",
            ),
            ("wwn-0x5002538e40e5728a", "sda"),
            ("scsi-SATA_Samsung_SSD_860_S4CYNF0M312756K", "sda"),
            ("ata-Samsung_SSD_860_QVO_2TB_S4CYNF0M312756K", "sda"),
            ("wwn-0x500a0751e2247779", "sdb"),
            ("dm-name-root", "dm-0"),
        ]
        .iter()
        .map(|(l, d)| (l.to_string(), d.to_string()))
        .collect();
        let ids = pick_disk_ids(&links);
        assert_eq!(
            ids["nvme1n1"],
            "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X"
        );
        assert_eq!(ids["sda"], "ata-Samsung_SSD_860_QVO_2TB_S4CYNF0M312756K");
        assert_eq!(ids["sdb"], "wwn-0x500a0751e2247779");
        assert!(!ids.contains_key("nvme1n1p1"));
        assert!(!ids.contains_key("dm-0"));
    }

    #[test]
    fn zpool_leaves_are_first_data_devices() {
        let raw = "tank\n\tmirror-0\n\t\t/dev/sda1\n\t\t/dev/sdb1\n\nlogs\n\t/dev/sdc1\n\
                   fast\n\t/dev/nvme0n1p2\ncache\n\t/dev/sdd1\n";
        let leaves = parse_zpool_leaves(raw);
        assert_eq!(leaves.len(), 2);
        assert_eq!(leaves["tank"], "/dev/sda1");
        assert_eq!(leaves["fast"], "/dev/nvme0n1p2");
    }

    #[test]
    fn mountinfo_gives_ids_escaped_paths_and_both_option_sets() {
        let raw = "32 2 0:29 /@ / rw,relatime shared:1 - btrfs /dev/mapper/root rw,ssd,discard=async\n\
                   1215 29 8:65 / /run/media/me/MY\\040STICK rw,nosuid master:1 - vfat /dev/sde1 rw,uid=1000,flush\n\
                   90 32 0:61 / /mnt/nuc/music\\040production rw - cifs //nuc.local/Music\\040Production rw\n\
                   broken line\n";
        let mounts = parse_mountinfo(raw);
        assert_eq!(mounts.len(), 3);
        assert_eq!(mounts[0].id, 32);
        assert_eq!(
            mounts[0].options,
            ["rw", "relatime", "rw", "ssd", "discard=async"]
        );
        assert_eq!(mounts[1].mount, "/run/media/me/MY STICK");
        assert!(mounts[1].options.iter().any(|o| o == "flush"));
        assert_eq!(mounts[2].source, "//nuc.local/Music Production");
        assert!(is_network_fs(&mounts[2].fstype));
        assert_eq!(unescape_mount("a\\134b\\777"), "a\\b\\777");
    }

    #[test]
    fn disk_load_is_latency_queue_and_busy_time() {
        let line = "259 0 nvme0n1 100 0 800 50 200 0 1600 450 3 900 2000 10 0 0 0 4 10";
        let parts: Vec<&str> = line.split_whitespace().collect();
        let before = parse_diskstats(&parts);
        assert_eq!(before.read_bytes, 800 * 512);
        assert_eq!(before.ios, 100 + 200 + 10 + 4);
        assert_eq!(before.ticks, 50 + 450 + 10);
        let after = Counters {
            ios: before.ios + 40,
            ticks: before.ticks + 2000,
            busy: before.busy + 900,
            queued: before.queued + 3000,
            ..before
        };
        let load = DiskLoad::between(&before, &after, 1.0);
        assert_eq!(
            load,
            DiskLoad {
                latency: Some(50.0),
                queue: 3.0,
                busy: 90.0
            }
        );
        assert_eq!(DiskLoad::between(&before, &before, 1.0).latency, None);
    }

    fn volume(fstype: &str, mount: &str, kind: &'static str, rotational: bool) -> Volume {
        Volume {
            mount: mount.to_string(),
            device: "/dev/omastats-test-none".to_string(),
            fstype: fstype.to_string(),
            size: 0,
            used: 0,
            avail: 0,
            disk: "sdz".to_string(),
            model: String::new(),
            rotational,
            removable: false,
            kind,
            key: "sdz".to_string(),
            checks: Vec::new(),
        }
    }

    fn ids(checks: &[Value]) -> Vec<&str> {
        checks.iter().filter_map(|c| c["id"].as_str()).collect()
    }

    #[test]
    fn ssds_without_any_trim_are_flagged() {
        let opts = |o: &[&str]| o.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let ssd = volume("ext4", "/data", "internal", false);
        assert_eq!(
            ids(&volume_checks(&ssd, &opts(&["rw"]), Some(false))),
            ["trim-off"]
        );
        assert!(volume_checks(&ssd, &opts(&["rw"]), Some(true)).is_empty());
        assert!(volume_checks(&ssd, &opts(&["rw"]), None).is_empty());
        assert!(volume_checks(&ssd, &opts(&["discard=async"]), Some(false)).is_empty());
        let hdd = volume("ext4", "/data", "internal", true);
        assert!(volume_checks(&hdd, &opts(&["rw"]), Some(false)).is_empty());
        let share = volume("cifs", "/mnt/share", "network", false);
        assert!(volume_checks(&share, &opts(&["rw"]), Some(false)).is_empty());
    }

    #[test]
    fn fat_drives_mounted_with_flush_are_flagged() {
        let opts = |o: &[&str]| o.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let stick = volume("vfat", "/mnt/stick", "external", true);
        let checks = volume_checks(&stick, &opts(&["rw", "flush", "dirsync"]), Some(true));
        assert_eq!(ids(&checks), ["fat-flush"]);
        assert_eq!(checks[0]["flags"], json!(["flush", "dirsync"]));
        // Outside UDisks there is no per-drive option file to fix it with.
        assert!(checks[0]["fix"].is_null());
        assert!(volume_checks(&stick, &opts(&["rw", "utf8"]), Some(true)).is_empty());
    }

    #[test]
    fn only_plain_names_reach_a_fix() {
        assert!(plain_name("root"));
        assert!(plain_name("D71B-4467"));
        assert!(plain_name("/dev/sde1"));
        assert!(!plain_name(""));
        assert!(!plain_name("root; rm -rf /"));
        assert!(!plain_name("$(id)"));
        assert!(!plain_name("/dev/../etc"));
    }
}
