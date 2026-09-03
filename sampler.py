#!/usr/bin/env python3
"""System sampler for the OmaStats plugin.

Emits one JSON object per line on stdout at a fixed interval. Reads procfs and
sysfs directly (no psutil) so the only dependency is a Python 3 interpreter.

Control lines on stdin:
    detail 0|1|2    0 = none, 1 = top processes, 2 = every process
    focus <page>    page the panel shows; "network" adds per-process traffic
    interval <sec>  change the sampling interval (0.1 - 30)
    pubip           refresh the public IP address in the background

Cheap counters follow the interval; anything that walks many files
(processes, sensors, battery, socket mapping) runs at most once a second.
"""

from __future__ import annotations

import json
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
import urllib.request

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
REAL_FS = {
    "ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs",
    "ntfs3", "fuseblk", "zfs", "jfs", "reiserfs", "nfs", "nfs4", "cifs",
    "smb3", "apfs", "hfsplus", "bcachefs",
}
CPU_TEMP_PREFERENCE = ("k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal", "acpitz")
GPU_TEMP_HWMON = ("amdgpu", "nouveau", "i915", "xe", "radeon")
PROC_LIMIT = 6
FULL_LIMIT = 400
CONNECTION_LIMIT = 12
CONTROL_LINE_LIMIT = 4 * 1024
EXTERNAL_TEXT_LIMIT = 512
STREAM_LINE_LIMIT = 64 * 1024
FILE_READ_LIMIT = 1024 * 1024
COMMAND_OUTPUT_LIMIT = 1024 * 1024
DIRECTORY_ENTRY_LIMIT = 4096
PROCESS_SCAN_LIMIT = 16_384
FD_SCAN_LIMIT = 4096
SOCKET_SCAN_LIMIT = 16_384
PROC_FILE_LIMIT = 64 * 1024
TOOL_DIRS = ("/usr/bin", "/bin")


def bounded_text(value: str, limit: int = EXTERNAL_TEXT_LIMIT) -> str:
    """Return at most limit UTF-8 bytes without splitting a character."""
    encoded = value.encode("utf-8", "replace")
    if len(encoded) <= limit:
        return value
    return encoded[:limit].decode("utf-8", "ignore")


def list_dir(path: str, limit: int = DIRECTORY_ENTRY_LIMIT) -> list[str]:
    """Return sorted names, or nothing when a directory exceeds its bound."""
    names: list[str] = []
    try:
        with os.scandir(path) as entries:
            for entry in entries:
                if len(names) >= limit:
                    return []
                names.append(entry.name)
    except OSError:
        return []
    names.sort()
    return names


def read_text(path: str, default: str = "") -> str:
    try:
        with open(path, "rb") as handle:
            raw = handle.read(FILE_READ_LIMIT + 1)
        if len(raw) > FILE_READ_LIMIT:
            return default
        return raw.decode("utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return default


def read_int(path: str, default: int | None = None) -> int | None:
    raw = read_text(path)
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        try:
            return int(float(raw))
        except ValueError:
            return default


def read_float(path: str, default: float | None = None) -> float | None:
    raw = read_text(path)
    if raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def command_path(program: str) -> str | None:
    """Resolve optional helpers from protected system directories, not PATH."""
    if not program or "/" in program:
        return None
    for directory in TOOL_DIRS:
        candidate = os.path.join(directory, program)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def kill_process_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass


def run(cmd: list[str], timeout: float = 2.0) -> str:
    """Run a fixed system helper with explicit time and output bounds."""
    if not cmd:
        return ""
    executable = command_path(cmd[0])
    if executable is None:
        return ""
    try:
        proc = subprocess.Popen(
            [executable, *cmd[1:]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return ""
    assert proc.stdout is not None
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    os.set_blocking(proc.stdout.fileno(), False)
    deadline = time.monotonic() + timeout
    eof = False
    exited = False
    try:
        while not (eof and exited):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                kill_process_group(proc)
                proc.wait()
                return ""
            for key, _ in selector.select(min(0.05, remaining)):
                try:
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    eof = True
                    selector.unregister(key.fileobj)
                    break
                if len(output) + len(chunk) > COMMAND_OUTPUT_LIMIT:
                    kill_process_group(proc)
                    proc.wait()
                    return ""
                output.extend(chunk)
            if not exited and proc.poll() is not None:
                exited = True
                # A descendant must not retain the captured pipe indefinitely.
                kill_process_group(proc)
        return output.decode("utf-8")
    except (OSError, UnicodeDecodeError, subprocess.SubprocessError):
        kill_process_group(proc)
        proc.wait()
        return ""
    finally:
        selector.close()
        proc.stdout.close()


def bounded_lines(stream, limit: int):
    """Yield decoded lines while draining and ignoring oversized input."""
    while True:
        raw = stream.readline(limit + 2)
        if not raw:
            return
        oversized = len(raw.rstrip(b"\r\n")) > limit
        while raw and not raw.endswith(b"\n"):
            raw = stream.readline(64 * 1024)
            oversized = True
        if oversized:
            yield ""
            continue
        try:
            yield raw.rstrip(b"\r\n").decode("utf-8")
        except UnicodeDecodeError:
            yield ""


def rate(now: float | None, prev: float | None, elapsed: float) -> float:
    if now is None or prev is None or elapsed <= 0:
        return 0.0
    delta = now - prev
    return max(0.0, delta / elapsed)


# ----------------------------------------------------------------------------- CPU


class CpuSampler:
    def __init__(self) -> None:
        self.prev_total: list[int] | None = None
        self.prev_cores: list[list[int]] | None = None
        self.static = self._static_info()
        self.temp_source = self._find_temp_source()
        self.freq_paths = [
            f"/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq"
            for i in range(self.static["threads"])
        ]
        self.freq_paths = [p for p in self.freq_paths if os.path.exists(p)]

    @staticmethod
    def _cpu_list(raw: str) -> list[int]:
        cpus: list[int] = []
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                if "-" in part:
                    lo, hi = (int(value) for value in part.split("-", 1))
                    if hi < lo or hi - lo > DIRECTORY_ENTRY_LIMIT:
                        return []
                    cpus.extend(range(lo, hi + 1))
                else:
                    cpus.append(int(part))
            except ValueError:
                continue
            if len(cpus) > DIRECTORY_ENTRY_LIMIT:
                return []
        return cpus

    def _static_info(self) -> dict:
        model = ""
        for line in read_text("/proc/cpuinfo").splitlines():
            if line.lower().startswith("model name"):
                model = line.split(":", 1)[1].strip()
                break
        threads = os.cpu_count() or 1
        core_ids = set()
        for i in range(threads):
            core = read_text(f"/sys/devices/system/cpu/cpu{i}/topology/core_id")
            pkg = read_text(f"/sys/devices/system/cpu/cpu{i}/topology/physical_package_id")
            if core != "":
                core_ids.add((pkg, core))
        cores = len(core_ids) or threads
        efficiency = self._cpu_list(read_text("/sys/devices/cpu_atom/cpus"))
        max_khz = read_int("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
        model = re.sub(r"\s+", " ", model)
        model = bounded_text(re.sub(r"\((R|TM)\)", "", model).replace("  ", " ").strip())
        return {
            "model": model,
            "cores": cores,
            "threads": threads,
            "efficiency": efficiency,
            "maxMhz": round(max_khz / 1000) if max_khz else 0,
        }

    def _find_temp_source(self) -> str | None:
        found: dict[str, str] = {}
        for hw in list_dir("/sys/class/hwmon"):
            base = f"/sys/class/hwmon/{hw}"
            name = read_text(f"{base}/name")
            if not name:
                continue
            for entry in list_dir(base):
                if not (entry.startswith("temp") and entry.endswith("_input")):
                    continue
                label = read_text(f"{base}/{entry[:-6]}_label").lower()
                key = f"{base}/{entry}"
                if name in ("k10temp", "zenpower") and label in ("tctl", "tdie", ""):
                    found.setdefault(name, key)
                elif name == "coretemp" and label.startswith("package"):
                    found.setdefault(name, key)
                elif name in ("cpu_thermal", "soc_thermal", "acpitz"):
                    found.setdefault(name, key)
                elif label == "cpu":
                    found.setdefault("labelled", key)
        for pref in CPU_TEMP_PREFERENCE:
            if pref in found:
                return found[pref]
        if "labelled" in found:
            return found["labelled"]
        # Thermal zones as a last resort (ARM boards, laptops without hwmon labels).
        for zone in list_dir("/sys/class/thermal"):
            if not zone.startswith("thermal_zone"):
                continue
            ztype = read_text(f"/sys/class/thermal/{zone}/type").lower()
            if "cpu" in ztype or "x86_pkg" in ztype or "soc" in ztype:
                return f"/sys/class/thermal/{zone}/temp"
        return None

    def sample(self) -> dict:
        totals: list[int] | None = None
        cores: list[list[int]] = []
        for line in read_text("/proc/stat").splitlines():
            if not line.startswith("cpu"):
                continue
            parts = line.split()
            values = [int(v) for v in parts[1:]]
            if parts[0] == "cpu":
                totals = values
            else:
                cores.append(values)

        def split(now: list[int], prev: list[int] | None) -> tuple[float, float, float, float]:
            if prev is None or len(now) < 8:
                return 0.0, 0.0, 0.0, 0.0
            delta = [n - p for n, p in zip(now, prev)]
            total = sum(delta[:8])
            if total <= 0:
                return 0.0, 0.0, 0.0, 0.0
            user = (delta[0] + delta[1]) / total * 100
            system = (delta[2] + delta[5] + delta[6] + delta[7]) / total * 100
            iowait = delta[4] / total * 100
            idle = delta[3] / total * 100
            return user, system, iowait, 100 - idle - iowait

        user, system, iowait, busy = split(totals or [], self.prev_total)
        per_core: list[float] = []
        if self.prev_cores and len(self.prev_cores) == len(cores):
            for now, prev in zip(cores, self.prev_cores):
                per_core.append(round(split(now, prev)[3], 1))
        else:
            per_core = [0.0 for _ in cores]
        self.prev_total = totals
        self.prev_cores = cores

        mhz = 0
        if self.freq_paths:
            values = [read_int(p, 0) or 0 for p in self.freq_paths]
            values = [v for v in values if v > 0]
            if values:
                mhz = round(sum(values) / len(values) / 1000)
        if mhz == 0:
            speeds = re.findall(r"cpu MHz\s*:\s*([0-9.]+)", read_text("/proc/cpuinfo"))
            if speeds:
                mhz = round(sum(float(s) for s in speeds) / len(speeds))

        load = read_text("/proc/loadavg").split()[:3]
        uptime = read_text("/proc/uptime").split()
        temp = None
        if self.temp_source:
            raw = read_int(self.temp_source)
            if raw is not None:
                temp = round(raw / 1000, 1)

        return {
            "total": round(busy, 1),
            "user": round(user, 1),
            "system": round(system, 1),
            "iowait": round(iowait, 1),
            "cores": per_core,
            "mhz": mhz,
            "maxMhz": self.static["maxMhz"],
            "load": [float(v) for v in load] if len(load) == 3 else [0, 0, 0],
            "uptime": float(uptime[0]) if uptime else 0,
            "model": self.static["model"],
            "coreCount": self.static["cores"],
            "threadCount": self.static["threads"],
            "efficiency": self.static["efficiency"],
            "temp": temp,
        }


# ----------------------------------------------------------------------------- GPU


class GpuSampler:
    """NVIDIA via a long-running `nvidia-smi -l` reader, AMD/Intel via sysfs."""

    QUERY = (
        "name,utilization.gpu,memory.used,memory.total,temperature.gpu,"
        "power.draw,clocks.gr,clocks.max.gr,fan.speed"
    )

    def __init__(self) -> None:
        self.kind: str | None = None
        self.latest: dict | None = None
        self.lock = threading.Lock()
        self.proc: subprocess.Popen | None = None
        self.card: str | None = None
        self.hwmon: str | None = None
        self.name = ""
        self._detect()

    def _detect(self) -> None:
        drm = "/sys/class/drm"
        if os.path.isdir(drm):
            for card in list_dir(drm):
                if not re.fullmatch(r"card\d+", card):
                    continue
                device = f"{drm}/{card}/device"
                vendor = read_text(f"{device}/vendor").lower()
                if vendor == "0x1002":
                    self.kind, self.card = "amd", device
                    break
                if vendor == "0x8086":
                    self.kind, self.card = "intel", device
                elif vendor == "0x10de" and self.kind is None:
                    self.kind, self.card = "nvidia", device
        if self.kind == "nvidia" and command_path("nvidia-smi"):
            self._start_nvidia()
        elif self.kind == "nvidia":
            self.kind = None
        if self.card:
            for hw in list_dir(f"{self.card}/hwmon"):
                self.hwmon = f"{self.card}/hwmon/{hw}"
                break
            self.name = self._pci_name(self.card)

    @staticmethod
    def _pci_name(device: str) -> str:
        try:
            slot = os.path.basename(os.path.realpath(device))
        except OSError:
            return ""
        if not command_path("lspci"):
            return ""
        for line in run(["lspci", "-mm", "-s", slot]).splitlines():
            fields = re.findall(r'"([^"]*)"', line)
            if len(fields) >= 3:
                name = fields[2]
                bracket = re.findall(r"\[([^\]]+)\]", name)
                return bounded_text(bracket[-1] if bracket else name)
        return ""

    def _start_nvidia(self) -> None:
        try:
            executable = command_path("nvidia-smi")
            if executable is None:
                raise FileNotFoundError("nvidia-smi")
            self.proc = subprocess.Popen(
                [executable, f"--query-gpu={self.QUERY}", "--format=csv,noheader,nounits", "-l", "1"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            self.proc = None
            self.kind = None
            return
        threading.Thread(target=self._read_nvidia, daemon=True).start()

    def _read_nvidia(self) -> None:
        assert self.proc and self.proc.stdout
        for line in bounded_lines(self.proc.stdout, STREAM_LINE_LIMIT):
            parts = [p.strip() for p in line.strip().split(",")]
            if len(parts) < 9:
                continue

            def num(value: str) -> float | None:
                try:
                    return float(value)
                except ValueError:
                    return None

            mem_used = num(parts[2])
            mem_total = num(parts[3])
            snapshot = {
                "name": bounded_text(parts[0]),
                "vendor": "nvidia",
                "util": num(parts[1]),
                "memUsed": mem_used * 1024 * 1024 if mem_used is not None else None,
                "memTotal": mem_total * 1024 * 1024 if mem_total is not None else None,
                "temp": num(parts[4]),
                "power": num(parts[5]),
                "mhz": num(parts[6]),
                "maxMhz": num(parts[7]),
                "fan": num(parts[8]),
            }
            with self.lock:
                self.latest = snapshot

    def _hwmon_value(self, prefix: str, labels: tuple[str, ...]) -> float | None:
        if not self.hwmon:
            return None
        chosen = None
        for entry in list_dir(self.hwmon):
            if entry.startswith(prefix) and entry.endswith("_input"):
                label = read_text(f"{self.hwmon}/{entry[:-6]}_label").lower()
                if label in labels or chosen is None:
                    chosen = entry
                    if label in labels:
                        break
        if not chosen:
            return None
        return read_float(f"{self.hwmon}/{chosen}")

    def sample(self) -> dict | None:
        if self.kind == "nvidia":
            with self.lock:
                return dict(self.latest) if self.latest else {"name": self.name or "NVIDIA", "vendor": "nvidia", "util": None}
        if self.kind in ("amd", "intel") and self.card:
            util = read_float(f"{self.card}/gpu_busy_percent")
            mem_used = read_float(f"{self.card}/mem_info_vram_used")
            mem_total = read_float(f"{self.card}/mem_info_vram_total")
            temp = self._hwmon_value("temp", ("edge", "junction"))
            power = self._hwmon_value("power", ("ppt", "power"))
            freq = self._hwmon_value("freq", ("sclk",))
            mhz = None
            if freq:
                mhz = freq / 1_000_000
            else:
                gt = read_float(f"{os.path.dirname(self.card)}/gt_cur_freq_mhz") or read_float(f"{os.path.dirname(self.card)}/gt/gt0/rps_cur_freq_mhz")
                if gt:
                    mhz = gt
            max_mhz = None
            gt_max = read_float(f"{os.path.dirname(self.card)}/gt_max_freq_mhz")
            if gt_max:
                max_mhz = gt_max
            return {
                "name": self.name or ("AMD" if self.kind == "amd" else "Intel"),
                "vendor": self.kind,
                "util": util,
                "memUsed": mem_used,
                "memTotal": mem_total,
                "temp": temp / 1000 if temp else None,
                "power": power / 1_000_000 if power else None,
                "mhz": mhz,
                "maxMhz": max_mhz,
                "fan": None,
            }
        return None

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            kill_process_group(self.proc)
            self.proc.wait()


# -------------------------------------------------------------------------- Memory


def sample_memory() -> dict:
    info: dict[str, int] = {}
    for line in read_text("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            info[key] = int(parts[0]) * 1024
    total = info.get("MemTotal", 0)
    free = info.get("MemFree", 0)
    available = info.get("MemAvailable", free)
    buffers = info.get("Buffers", 0)
    cached = info.get("Cached", 0) + info.get("SReclaimable", 0)
    shmem = info.get("Shmem", 0)
    swap_total = info.get("SwapTotal", 0)
    swap_used = swap_total - info.get("SwapFree", 0)
    apps = max(0, total - free - buffers - cached)
    zram_orig = 0
    zram_compr = 0
    for dev in list_dir("/sys/block"):
        if dev.startswith("zram"):
            fields = read_text(f"/sys/block/{dev}/mm_stat").split()
            if len(fields) >= 3:
                zram_orig += int(fields[0])
                zram_compr += int(fields[1])
    pressure_some = 0.0
    pressure_full = 0.0
    for line in read_text("/proc/pressure/memory").splitlines():
        match = re.match(r"(some|full)\s+avg10=([0-9.]+)", line)
        if match:
            if match.group(1) == "some":
                pressure_some = float(match.group(2))
            else:
                pressure_full = float(match.group(2))
    return {
        "total": total,
        "free": free,
        "available": available,
        "used": max(0, total - available),
        "apps": apps,
        "cached": max(0, cached + buffers - shmem),
        "shared": shmem,
        "swapTotal": swap_total,
        "swapUsed": max(0, swap_used),
        "compressed": zram_orig,
        "compressedSize": zram_compr,
        "pressureSome": pressure_some,
        "pressureFull": pressure_full,
    }


# --------------------------------------------------------------------------- Disks


class DiskSampler:
    def __init__(self) -> None:
        self.prev: dict[str, tuple[int, int]] = {}
        self.volumes_cache: list[dict] = []
        self.volumes_stamp = 0.0
        self.drive_temps: dict[str, str] = {}
        self._scan_drive_temps()

    def _scan_drive_temps(self) -> None:
        base = "/sys/class/hwmon"
        if not os.path.isdir(base):
            return
        for hw in list_dir(base):
            name = read_text(f"{base}/{hw}/name")
            if name not in ("nvme", "drivetemp"):
                continue
            device = f"{base}/{hw}/device"
            block = None
            try:
                for entry in list_dir(device):
                    if re.fullmatch(r"(nvme\d+n\d+|sd[a-z]+)", entry):
                        block = entry
                        break
                if block is None and os.path.isdir(f"{device}/block"):
                    block = next(iter(list_dir(f"{device}/block")), None)
                if block is None and os.path.isdir(f"{device}/nvme"):
                    # nvme hwmon sits on the controller; its namespaces live one level deeper.
                    ctrl = os.path.basename(os.path.realpath(device))
                    for entry in list_dir("/sys/block"):
                        if entry.startswith(ctrl):
                            block = entry
                            break
            except OSError:
                continue
            if block is None:
                ctrl = os.path.basename(os.path.realpath(device))
                for entry in list_dir("/sys/block"):
                    if entry.startswith(ctrl):
                        block = entry
                        break
            if block:
                self.drive_temps[block] = f"{base}/{hw}/temp1_input"

    @staticmethod
    def _parent_disk(device: str) -> str:
        """Map /dev/nvme0n1p2 or /dev/mapper/root to its whole-disk name."""
        real = os.path.realpath(device)
        name = os.path.basename(real)
        for _ in range(4):
            slaves = f"/sys/block/{name}/slaves"
            if os.path.isdir(slaves):
                entries = list_dir(slaves)
                if entries:
                    name = entries[0]
                    continue
            break
        if os.path.isdir(f"/sys/block/{name}"):
            return name
        match = re.match(r"(nvme\d+n\d+)p\d+$", name) or re.match(r"(mmcblk\d+)p\d+$", name) or re.match(r"([a-z]+)\d+$", name)
        if match and os.path.isdir(f"/sys/block/{match.group(1)}"):
            return match.group(1)
        # Partition directories live under their parent in sysfs.
        for disk in list_dir("/sys/block"):
            if os.path.isdir(f"/sys/block/{disk}/{name}"):
                return disk
        return name

    def _volumes(self) -> list[dict]:
        volumes: dict[str, dict] = {}
        for line in read_text("/proc/self/mounts").splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            device = bounded_text(parts[0], 4096)
            mount = bounded_text(parts[1].replace("\\040", " "), 4096)
            fstype = bounded_text(parts[2], 64)
            if fstype not in REAL_FS or not device.startswith("/"):
                continue
            if mount.startswith(("/proc", "/sys", "/dev", "/run/user", "/var/lib/docker", "/snap")):
                continue
            try:
                stat = os.statvfs(mount)
            except OSError:
                continue
            size = stat.f_blocks * stat.f_frsize
            if size < 64 * 1024 * 1024:
                continue
            avail = stat.f_bavail * stat.f_frsize
            used = size - stat.f_bfree * stat.f_frsize
            key = device
            existing = volumes.get(key)
            if existing and len(existing["mount"]) <= len(mount):
                continue
            if existing is None and len(volumes) >= 256:
                continue
            disk = self._parent_disk(device)
            model = bounded_text(
                read_text(f"/sys/block/{disk}/device/model")
                or read_text(f"/sys/block/{disk}/device/name")
            )
            rotational = read_int(f"/sys/block/{disk}/queue/rotational", 0) == 1
            volumes[key] = {
                "mount": mount,
                "device": device,
                "fstype": fstype,
                "size": size,
                "used": used,
                "avail": avail,
                "disk": disk,
                "model": re.sub(r"\s+", " ", model).strip(),
                "rotational": rotational,
                "removable": read_int(f"/sys/block/{disk}/removable", 0) == 1,
            }
        result = sorted(volumes.values(), key=lambda v: (v["mount"] != "/", v["mount"]))
        return result

    def sample(self, elapsed: float, now: float) -> dict:
        if now - self.volumes_stamp > 10:
            self.volumes_cache = self._volumes()
            self.volumes_stamp = now
        current: dict[str, tuple[int, int]] = {}
        for line in read_text("/proc/diskstats").splitlines():
            parts = line.split()
            if len(parts) < 14:
                continue
            name = parts[2]
            if not re.fullmatch(r"(nvme\d+n\d+|sd[a-z]+|vd[a-z]+|hd[a-z]+|mmcblk\d+|xvd[a-z]+)", name):
                continue
            if (read_int(f"/sys/block/{name}/size", 0) or 0) <= 0:
                continue
            current[name] = (int(parts[5]) * 512, int(parts[9]) * 512)
        per_disk: dict[str, dict] = {}
        total_read = 0.0
        total_write = 0.0
        for name, (read_bytes, write_bytes) in current.items():
            prev = self.prev.get(name)
            read_rate = rate(read_bytes, prev[0] if prev else None, elapsed)
            write_rate = rate(write_bytes, prev[1] if prev else None, elapsed)
            temp_path = self.drive_temps.get(name)
            temp = read_int(temp_path) if temp_path else None
            per_disk[name] = {
                "read": read_rate,
                "write": write_rate,
                "temp": round(temp / 1000, 1) if temp else None,
            }
            total_read += read_rate
            total_write += write_rate
        self.prev = current
        volumes = []
        for volume in self.volumes_cache:
            entry = dict(volume)
            activity = per_disk.get(volume["disk"], {})
            entry["temp"] = activity.get("temp")
            volumes.append(entry)
        return {
            "volumes": volumes,
            "read": total_read,
            "write": total_write,
            "perDisk": per_disk,
        }


# ------------------------------------------------------------------------- Network


class NetworkSampler:
    def __init__(self) -> None:
        self.prev: dict[str, tuple[int, int]] = {}
        self.addr_cache: dict[str, dict] = {}
        self.addr_stamp = 0.0
        self.wifi_cache: dict[str, dict] = {}
        self.wifi_stamp = 0.0
        self.public_ip = ""
        self.public_stamp = 0.0
        self.public_lock = threading.Lock()
        self.public_inflight = False

    @staticmethod
    def _default_iface() -> str:
        for line in read_text("/proc/net/route").splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4 and parts[1] == "00000000" and int(parts[3], 16) & 2:
                return parts[0]
        for line in read_text("/proc/net/ipv6_route").splitlines():
            parts = line.split()
            if len(parts) >= 10 and parts[0] == "0" * 32 and parts[1] == "00":
                return parts[9]
        return ""

    def _refresh_addresses(self) -> None:
        self.addr_cache = {}
        if not command_path("ip"):
            return
        try:
            data = json.loads(run(["ip", "-j", "addr"]) or "[]")
        except json.JSONDecodeError:
            return
        for iface in data:
            name = bounded_text(str(iface.get("ifname", "")))
            if not name:
                continue
            v4, v6 = [], []
            for addr in iface.get("addr_info", []):
                if addr.get("scope") != "global":
                    continue
                if addr.get("family") == "inet":
                    v4.append(bounded_text(str(addr.get("local", "")), 64))
                elif addr.get("family") == "inet6" and not addr.get("temporary"):
                    v6.append(bounded_text(str(addr.get("local", "")), 64))
            self.addr_cache[name] = {"ipv4": v4, "ipv6": v6}

    def _refresh_wifi(self, ifaces: list[str]) -> None:
        self.wifi_cache = {}
        if not command_path("iw"):
            return
        for name in ifaces:
            info: dict = {}
            for line in run(["iw", "dev", name, "link"]).splitlines():
                line = line.strip()
                if line.startswith("SSID:"):
                    info["ssid"] = bounded_text(line[5:].strip(), 128)
                elif line.startswith("signal:"):
                    match = re.search(r"(-?\d+) dBm", line)
                    if match:
                        info["dbm"] = int(match.group(1))
                elif line.startswith("freq:"):
                    match = re.search(r"([0-9.]+)", line)
                    if match:
                        info["freq"] = float(match.group(1))
                elif line.startswith("tx bitrate:"):
                    match = re.search(r"([0-9.]+) MBit/s", line)
                    if match:
                        info["bitrate"] = float(match.group(1))
            self.wifi_cache[name] = info

    def fetch_public_ip(self) -> None:
        with self.public_lock:
            if self.public_inflight:
                return
            self.public_inflight = True

        def worker() -> None:
            result = ""
            for url in ("https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"):
                try:
                    with urllib.request.urlopen(url, timeout=5) as response:
                        raw = response.read(65)
                        candidate = raw.decode("utf-8", "replace").strip()
                    if len(raw) <= 64 and re.fullmatch(r"[0-9a-fA-F.:]+", candidate):
                        result = candidate
                        break
                except Exception:
                    continue
            with self.public_lock:
                self.public_ip = result
                self.public_stamp = time.time()
                self.public_inflight = False

        threading.Thread(target=worker, daemon=True).start()

    def sample(self, elapsed: float, now: float, detail: bool) -> dict:
        current: dict[str, tuple[int, int]] = {}
        for line in read_text("/proc/net/dev").splitlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            parts = rest.split()
            if name == "lo" or len(parts) < 16:
                continue
            current[name] = (int(parts[0]), int(parts[8]))
        if now - self.addr_stamp > (10 if detail else 30):
            self._refresh_addresses()
            self.addr_stamp = now
        wireless = [n for n in current if os.path.isdir(f"/sys/class/net/{n}/wireless")]
        if wireless and now - self.wifi_stamp > (10 if detail else 30):
            self._refresh_wifi(wireless)
            self.wifi_stamp = now
        default = self._default_iface()
        ifaces = []
        total_rx = total_tx = 0.0
        default_rx = default_tx = 0.0
        online = False
        for name, (rx_total, tx_total) in current.items():
            prev = self.prev.get(name)
            rx = rate(rx_total, prev[0] if prev else None, elapsed)
            tx = rate(tx_total, prev[1] if prev else None, elapsed)
            state = read_text(f"/sys/class/net/{name}/operstate")
            up = state == "up" or (state == "unknown" and rx_total > 0)
            if name.startswith(("veth", "docker", "br-", "virbr", "vmnet", "tap")) and name != default:
                continue
            speed = read_int(f"/sys/class/net/{name}/speed", 0) or 0
            addrs = self.addr_cache.get(name, {"ipv4": [], "ipv6": []})
            entry = {
                "name": name,
                "up": up,
                "default": name == default,
                "wireless": name in wireless,
                "speed": speed if speed > 0 else 0,
                "rx": rx,
                "tx": tx,
                "rxTotal": rx_total,
                "txTotal": tx_total,
                "ipv4": addrs["ipv4"],
                "ipv6": addrs["ipv6"],
            }
            entry.update(self.wifi_cache.get(name, {}))
            ifaces.append(entry)
            if up:
                total_rx += rx
                total_tx += tx
            if name == default:
                default_rx, default_tx = rx, tx
                online = up
        self.prev = current
        ifaces.sort(key=lambda i: (not i["default"], not i["up"], i["name"]))
        with self.public_lock:
            public_ip = self.public_ip
        return {
            "ifaces": ifaces,
            "default": default,
            "rx": default_rx if default else total_rx,
            "tx": default_tx if default else total_tx,
            "online": online or any(i["up"] for i in ifaces),
            "publicIp": public_ip,
        }


# ------------------------------------------------------------------------- Sensors


class SensorSampler:
    def __init__(self) -> None:
        self.chips: list[dict] = []
        self.stamp = 0.0
        self.gpu_temp_path: str | None = None

    def _scan(self) -> None:
        base = "/sys/class/hwmon"
        chips: list[dict] = []
        remaining = 1024
        if not os.path.isdir(base):
            self.chips = []
            return
        for hw in sorted(list_dir(base), key=lambda h: int(h[5:]) if h[5:].isdigit() else 0):
            if remaining == 0:
                break
            path = f"{base}/{hw}"
            name = bounded_text(read_text(f"{path}/name"))
            if not name:
                continue
            temps, fans = [], []
            for entry in list_dir(path):
                if len(temps) + len(fans) >= remaining:
                    break
                if entry.startswith("temp") and entry.endswith("_input"):
                    key = entry[:-6]
                    temps.append({
                        "key": key,
                        "label": bounded_text(read_text(f"{path}/{key}_label")),
                        "path": f"{path}/{entry}",
                        "max": read_int(f"{path}/{key}_max") or read_int(f"{path}/{key}_crit") or 0,
                    })
                elif entry.startswith("fan") and entry.endswith("_input"):
                    key = entry[:-6]
                    fans.append({
                        "key": key,
                        "label": bounded_text(read_text(f"{path}/{key}_label")),
                        "path": f"{path}/{entry}",
                    })
            if not temps and not fans:
                continue
            remaining -= len(temps) + len(fans)
            chips.append({"name": name, "path": path, "temps": temps, "fans": fans,
                          "labelled": any(t["label"] for t in temps) or any(f["label"] for f in fans)})
        # Some boards expose the same super-IO chip twice (vendor + generic driver).
        # Keep the labelled instance; drop unlabelled duplicates.
        self.chips = self._dedupe(chips)
        self.gpu_temp_path = None
        for chip in self.chips:
            if chip["name"] in GPU_TEMP_HWMON and chip["temps"]:
                preferred = [t for t in chip["temps"] if t["label"].lower() in ("edge", "junction")]
                self.gpu_temp_path = (preferred or chip["temps"])[0]["path"]
                break

    @staticmethod
    def _is_board_chip(name: str) -> bool:
        return name.startswith(("nct", "it87", "f71", "w83", "asus_ec"))

    @staticmethod
    def _score(chip: dict) -> int:
        return sum(2 for f in chip["fans"] if f["label"]) + sum(1 for t in chip["temps"] if t["label"])

    def _dedupe(self, chips: list[dict]) -> list[dict]:
        """Some boards register the same super-IO chip under two drivers.

        A board chip is one physical device, so keep only the better-labelled
        copy of each name. Everything else (one hwmon per DIMM, per drive, per
        GPU) is kept as is.
        """
        kept: list[dict] = []
        for chip in chips:
            duplicate = None
            if self._is_board_chip(chip["name"]):
                duplicate = next((other for other in kept if other["name"] == chip["name"]), None)
            if duplicate is None:
                kept.append(chip)
            elif self._score(chip) > self._score(duplicate):
                kept[kept.index(duplicate)] = chip
        return kept

    @staticmethod
    def _pretty_chip(name: str) -> str:
        table = {
            "k10temp": "CPU", "zenpower": "CPU", "coretemp": "CPU", "nvme": "NVMe",
            "drivetemp": "Drive", "amdgpu": "GPU", "nouveau": "GPU", "i915": "GPU",
            "acpitz": "ACPI", "iwlwifi_1": "Wi-Fi", "mt7921_phy0": "Wi-Fi",
            "spd5118": "Memory", "jc42": "Memory", "thinkpad": "ThinkPad",
            "BAT0": "Battery", "BAT1": "Battery",
        }
        if name in table:
            return table[name]
        if name.startswith("r8169") or name.startswith("igc") or name.startswith("e1000"):
            return "Ethernet"
        if name.startswith("mt79") or name.startswith("iwl") or name.startswith("ath"):
            return "Wi-Fi"
        if name.startswith("nct") or name.startswith("it87") or name.startswith("f71"):
            return "Board"
        return bounded_text(name)

    def sample(self, now: float) -> dict:
        if now - self.stamp > 30:
            self._scan()
            self.stamp = now
        temps, fans = [], []
        name_counts: dict[str, int] = {}
        for chip in self.chips:
            name_counts[chip["name"]] = name_counts.get(chip["name"], 0) + 1
        name_seen: dict[str, int] = {}
        for chip in self.chips:
            chip_label = self._pretty_chip(chip["name"])
            if name_counts[chip["name"]] > 1:
                name_seen[chip["name"]] = name_seen.get(chip["name"], 0) + 1
                chip_label = f"{chip_label} {name_seen[chip['name']]}"
            for temp in chip["temps"]:
                raw = read_int(temp["path"])
                if raw is None or raw <= 0 or raw >= 200_000:
                    continue
                label = temp["label"] or (chip_label if len(chip["temps"]) == 1 else f"{chip_label} {temp['key'][4:]}")
                temps.append({
                    "chip": chip_label,
                    "id": f"{chip['name']}/{temp['key']}",
                    "label": label,
                    "value": round(raw / 1000, 1),
                    "max": round(temp["max"] / 1000) if 0 < temp["max"] < 200_000 else 0,
                })
            for fan in chip["fans"]:
                raw = read_int(fan["path"])
                if raw is None:
                    continue
                fans.append({
                    "chip": chip_label,
                    "id": f"{chip['name']}/{fan['key']}",
                    "label": fan["label"] or f"Fan {fan['key'][3:]}",
                    "rpm": raw,
                })
        gpu_temp = None
        if self.gpu_temp_path:
            raw = read_int(self.gpu_temp_path)
            if raw:
                gpu_temp = round(raw / 1000, 1)
        return {"temps": temps, "fans": fans, "gpuTemp": gpu_temp}


# ------------------------------------------------------------------------- Battery


def sample_battery() -> dict | None:
    base = "/sys/class/power_supply"
    if os.environ.get("OMASTATS_FAKE_BATTERY"):
        phase = (time.time() / 4) % 100
        return {
            "present": True, "name": "BAT0", "percent": round(35 + phase / 2, 1),
            "status": "Charging" if int(time.time() / 40) % 2 else "Discharging",
            "energyNow": 32.1, "energyFull": 56.0, "energyDesign": 57.0, "power": 12.4,
            "voltage": 11.9, "timeToEmpty": 142, "timeToFull": 0, "cycles": 212,
            "health": 98.2, "acOnline": bool(int(time.time() / 40) % 2), "model": "Demo Cell",
            "peripherals": [{"name": "MX Master 3S", "percent": 70, "status": "Discharging"}],
        }
    if not os.path.isdir(base):
        return None
    system = None
    peripherals = []
    ac_online = None
    for entry in list_dir(base):
        path = f"{base}/{entry}"
        ptype = read_text(f"{path}/type")
        if ptype in ("Mains", "USB", "USB_PD", "USB_C"):
            online = read_int(f"{path}/online")
            if online is not None:
                ac_online = bool(online) if ac_online is None else (ac_online or bool(online))
            continue
        if ptype != "Battery":
            continue
        scope = read_text(f"{path}/scope")
        capacity = read_int(f"{path}/capacity")
        status = bounded_text(read_text(f"{path}/status") or "Unknown")
        model = bounded_text(read_text(f"{path}/model_name"))
        if scope == "Device" or entry.startswith(("hid", "wacom")) or (not entry.startswith("BAT") and read_int(f"{path}/present", 1) == 1 and read_int(f"{path}/energy_full") is None and read_int(f"{path}/charge_full") is None):
            if capacity is not None and len(peripherals) < 256:
                peripherals.append({"name": model or bounded_text(entry), "percent": capacity, "status": status})
            continue
        if system is not None:
            continue
        present = read_int(f"{path}/present", 1) == 1
        voltage = (read_int(f"{path}/voltage_now") or 0) / 1_000_000
        energy_now = read_int(f"{path}/energy_now")
        energy_full = read_int(f"{path}/energy_full")
        energy_design = read_int(f"{path}/energy_full_design")
        power_now = read_int(f"{path}/power_now")
        if energy_now is None:
            charge_now = read_int(f"{path}/charge_now")
            charge_full = read_int(f"{path}/charge_full")
            charge_design = read_int(f"{path}/charge_full_design")
            current_now = read_int(f"{path}/current_now")
            energy_now = charge_now * voltage if charge_now is not None else None
            energy_full = charge_full * voltage if charge_full is not None else None
            energy_design = charge_design * voltage if charge_design is not None else None
            power_now = abs(current_now) * voltage if current_now is not None else None
        health = None
        if energy_full and energy_design:
            health = round(min(100.0, energy_full / energy_design * 100), 1)
        power_w = (power_now or 0) / 1_000_000
        time_to_empty = read_int(f"{path}/time_to_empty_now")
        time_to_full = read_int(f"{path}/time_to_full_now")
        if time_to_empty is None and status == "Discharging" and power_w > 0 and energy_now:
            time_to_empty = round(energy_now / 1_000_000 / power_w * 60)
        if time_to_full is None and status == "Charging" and power_w > 0 and energy_now is not None and energy_full:
            time_to_full = round((energy_full - energy_now) / 1_000_000 / power_w * 60)
        if capacity is None and energy_now is not None and energy_full:
            capacity = round(energy_now / energy_full * 100)
        system = {
            "present": present,
            "name": entry,
            "percent": capacity if capacity is not None else 0,
            "status": status,
            "energyNow": round((energy_now or 0) / 1_000_000, 2),
            "energyFull": round((energy_full or 0) / 1_000_000, 2),
            "energyDesign": round((energy_design or 0) / 1_000_000, 2),
            "power": round(power_w, 2),
            "voltage": round(voltage, 2),
            "timeToEmpty": time_to_empty or 0,
            "timeToFull": time_to_full or 0,
            "cycles": read_int(f"{path}/cycle_count") or 0,
            "health": health,
            "acOnline": ac_online,
            "model": model,
            "technology": bounded_text(read_text(f"{path}/technology")),
        }
    if system is None:
        if peripherals:
            return {"present": False, "peripherals": peripherals}
        return None
    if system["acOnline"] is None:
        system["acOnline"] = system["status"] in ("Charging", "Full", "Not charging")
    system["peripherals"] = peripherals
    return system


# ----------------------------------------------------------------------- Processes


def display_name(pid: int, comm: str) -> str:
    """A readable name: the kernel's 15-char comm, or the executable's basename."""
    if len(comm) < 15:
        return bounded_text(comm)
    cmdline = read_text(f"/proc/{pid}/cmdline").split("\0")[0]
    if cmdline:
        base = os.path.basename(cmdline)
        if base.startswith(comm[:8]) or len(base) > len(comm):
            return bounded_text(base)
    return bounded_text(comm)


class ProcessSampler:
    def __init__(self) -> None:
        self.prev: dict[int, tuple[int, int, int, int]] = {}
        self.threads = os.cpu_count() or 1
        self.uid = os.getuid()
        self.names: dict[int, str] = {}
        self.sockets_prev: dict[str, tuple[int, int]] = {}
        self.sockets_time: float | None = None

    def reset(self) -> None:
        self.prev = {}
        self.names = {}

    def sample(self, elapsed: float, full: bool = False) -> dict:
        current: dict[int, tuple[int, int, int, int]] = {}
        by_name: dict[str, dict] = {}
        names: dict[int, str] = {}
        for entry in list_dir("/proc", PROCESS_SCAN_LIMIT):
            if not entry.isdigit():
                continue
            pid = int(entry)
            try:
                with open(f"/proc/{pid}/stat", "rb") as handle:
                    raw_stat = handle.read(PROC_FILE_LIMIT + 1)
                if len(raw_stat) > PROC_FILE_LIMIT:
                    continue
                stat = raw_stat.decode("utf-8", "replace")
            except OSError:
                continue
            close = stat.rfind(")")
            open_paren = stat.find("(")
            if close < 0 or open_paren < 0:
                continue
            comm = stat[open_paren + 1:close]
            fields = stat[close + 2:].split()
            if len(fields) < 22:
                continue
            if fields[0] == "Z":
                continue
            ticks = int(fields[11]) + int(fields[12])
            rss = int(fields[21]) * PAGE_SIZE
            read_bytes = write_bytes = 0
            try:
                with open(f"/proc/{pid}/io", "rb") as handle:
                    raw_io = handle.read(PROC_FILE_LIMIT + 1)
                    if len(raw_io) > PROC_FILE_LIMIT:
                        raw_io = b""
                    for line in raw_io.splitlines():
                        if line.startswith(b"read_bytes:"):
                            read_bytes = int(line.split()[1])
                        elif line.startswith(b"write_bytes:"):
                            write_bytes = int(line.split()[1])
                            break
            except OSError:
                pass
            current[pid] = (ticks, rss, read_bytes, write_bytes)
            prev = self.prev.get(pid)
            cpu = 0.0
            io_read = io_write = 0.0
            if prev is not None and elapsed > 0:
                cpu = (ticks - prev[0]) / CLK_TCK / elapsed * 100 / self.threads
                io_read = rate(read_bytes, prev[2], elapsed)
                io_write = rate(write_bytes, prev[3], elapsed)
            name = self.names.get(pid) or display_name(pid, comm)
            names[pid] = name
            agg = by_name.get(name)
            if agg is None:
                agg = by_name[name] = {"name": name, "pid": pid, "cpu": 0.0, "mem": 0, "read": 0.0, "write": 0.0, "count": 0}
            agg["cpu"] += max(0.0, cpu)
            agg["mem"] += rss
            agg["read"] += io_read
            agg["write"] += io_write
            agg["count"] += 1
        self.prev = current
        self.names = names
        groups = list(by_name.values())

        def trim(items: list[dict], key: str) -> list[dict]:
            out = []
            for item in items[:PROC_LIMIT]:
                if item[key] <= 0:
                    break
                out.append({
                    "name": item["name"], "pid": item["pid"], "count": item["count"],
                    "cpu": round(item["cpu"], 1), "mem": item["mem"],
                    "read": item["read"], "write": item["write"],
                })
            return out

        by_cpu = sorted(groups, key=lambda g: g["cpu"], reverse=True)
        result = {
            "cpu": trim(by_cpu, "cpu"),
            "mem": trim(sorted(groups, key=lambda g: g["mem"], reverse=True), "mem"),
            "total": len(groups),
            "io": [
                {
                    "name": g["name"], "pid": g["pid"], "count": g["count"],
                    "read": g["read"], "write": g["write"], "cpu": round(g["cpu"], 1), "mem": g["mem"],
                }
                for g in sorted(groups, key=lambda g: g["read"] + g["write"], reverse=True)[:PROC_LIMIT]
                if g["read"] + g["write"] > 0
            ],
        }
        if full:
            result["all"] = [
                {
                    "name": g["name"], "pid": g["pid"], "count": g["count"],
                    "cpu": round(g["cpu"], 1), "mem": g["mem"], "read": g["read"], "write": g["write"],
                }
                for g in by_cpu[:FULL_LIMIT]
            ]
        return result

    def network_usage(self, full: bool = False) -> list[dict]:
        """Network traffic per process, without root.

        The kernel keeps cumulative bytes_sent / bytes_received on every TCP
        socket and hands them to any user through socket diagnostics
        (`ss -ti`); differencing them per socket between calls gives real
        per-process rates. Sockets are tied to processes through
        /proc/<pid>/fd (own processes) or named after their cgroup (system
        services). UDP, and so QUIC, carries no such counters.
        """
        sockets: dict[str, dict] = {}
        current: dict | None = None
        for line in run(["ss", "-tineH"]).splitlines():
            if line.startswith((" ", "\t")):
                if current is not None:
                    for tok in line.split():
                        if tok.startswith("bytes_sent:"):
                            current["sent"] = int(tok[11:] or 0)
                        elif tok.startswith("bytes_received:"):
                            current["recv"] = int(tok[15:] or 0)
                continue
            ino = ""
            cgroup = ""
            for tok in line.split():
                if tok.startswith("ino:"):
                    ino = tok[4:]
                elif tok.startswith("cgroup:"):
                    cgroup = tok[7:]
            current = None
            if ino:
                current = {"sent": 0, "recv": 0, "cgroup": cgroup, "established": line.startswith("ESTAB")}
                sockets[ino] = current
                if len(sockets) > SOCKET_SCAN_LIMIT:
                    self.sockets_prev = {}
                    self.sockets_time = None
                    return []
        if not sockets:
            self.sockets_prev = {}
            self.sockets_time = None
            return []

        owner: dict[str, tuple[int, str]] = {}
        for entry in list_dir("/proc", PROCESS_SCAN_LIMIT):
            if not entry.isdigit():
                continue
            pid = int(entry)
            try:
                fds = list_dir(f"/proc/{pid}/fd", FD_SCAN_LIMIT)
            except OSError:
                continue
            name: str | None = None
            for fd in fds:
                try:
                    target = os.readlink(f"/proc/{pid}/fd/{fd}")
                except OSError:
                    continue
                if not target.startswith("socket:["):
                    continue
                ino = target[8:-1]
                if ino not in sockets:
                    continue
                if name is None:
                    name = self.names.get(pid)
                    if name is None:
                        stat = read_text(f"/proc/{pid}/stat")
                        open_paren, close = stat.find("("), stat.rfind(")")
                        name = display_name(pid, stat[open_paren + 1:close]) if 0 <= open_paren < close else f"pid {pid}"
                owner[ino] = (pid, name)

        now = time.monotonic()
        elapsed = now - self.sockets_time if self.sockets_time is not None else 0.0
        usable = 0.0 < elapsed < 5.0
        groups: dict[str, dict] = {}
        for ino, sock in sockets.items():
            pid, name = owner.get(ino, (0, cgroup_label(sock["cgroup"])))
            group = groups.setdefault(name, {"name": name, "pid": pid, "pids": set(), "connections": 0, "rx": 0.0, "tx": 0.0})
            group["pids"].add(pid)
            if sock["established"]:
                group["connections"] += 1
            prev = self.sockets_prev.get(ino)
            if usable and prev is not None:
                group["tx"] += max(0, sock["sent"] - prev[0]) / elapsed
                group["rx"] += max(0, sock["recv"] - prev[1]) / elapsed
        self.sockets_prev = {ino: (s["sent"], s["recv"]) for ino, s in sockets.items()}
        self.sockets_time = now

        ranked = sorted(
            (g for g in groups.values() if g["connections"] > 0 or g["rx"] + g["tx"] > 0),
            key=lambda g: (-(g["rx"] + g["tx"]), -g["connections"], g["name"]),
        )
        return [
            {"name": g["name"], "pid": g["pid"], "count": len(g["pids"]), "connections": g["connections"], "rx": g["rx"], "tx": g["tx"]}
            for g in ranked[: FULL_LIMIT if full else CONNECTION_LIMIT]
        ]


def cgroup_label(cgroup: str) -> str:
    """Label for a socket whose owner we cannot inspect, from its cgroup."""
    last = cgroup.rsplit("/", 1)[-1].replace("\\x2d", "-")
    if not last:
        return "other"
    stem = last
    for suffix in (".scope", ".service", ".mount", ".slice"):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
    if stem.startswith("app-"):
        parts = stem[4:].split("-")
        if len(parts) >= 3:
            return bounded_text("-".join(parts[1:-1]))
        if len(parts) == 2:
            return bounded_text(parts[1])
    return bounded_text(stem) or "other"


# ---------------------------------------------------------------------------- main


class Controller:
    def __init__(self, interval: float) -> None:
        self.interval = interval
        self.detail = 0
        self.focus = ""
        self.lock = threading.Lock()
        self.public_ip_requested = False
        self.stop = False

    def listen(self) -> None:
        for line in bounded_lines(sys.stdin.buffer, CONTROL_LINE_LIMIT):
            parts = line.strip().split()
            if not parts:
                continue
            with self.lock:
                if parts[0] == "detail" and len(parts) > 1:
                    self.detail = 2 if parts[1] in ("2", "full", "all") else (1 if parts[1] in ("1", "true", "on") else 0)
                elif parts[0] == "focus" and len(parts) > 1:
                    self.focus = parts[1]
                elif parts[0] == "interval" and len(parts) > 1:
                    try:
                        self.interval = max(0.1, min(30.0, float(parts[1])))
                    except ValueError:
                        pass
                elif parts[0] == "pubip":
                    self.public_ip_requested = True
                elif parts[0] == "quit":
                    self.stop = True


def main() -> int:
    interval = 1.0
    args = sys.argv[1:]
    if "--version" in args or "-V" in args:
        print("omastats-sampler 1.0.0 (python)")
        return 0
    if "--interval" in args:
        try:
            interval = float(args[args.index("--interval") + 1])
        except (IndexError, ValueError):
            pass
    detail_flag = 2 if "--full" in args else (1 if "--detail" in args else 0)
    once = "--once" in args

    controller = Controller(interval)
    controller.detail = detail_flag
    if "--focus" in args:
        try:
            controller.focus = args[args.index("--focus") + 1]
        except IndexError:
            pass
    if not once:
        threading.Thread(target=controller.listen, daemon=True).start()

    cpu = CpuSampler()
    gpu = GpuSampler()
    disks = DiskSampler()
    net = NetworkSampler()
    sensors = SensorSampler()
    procs = ProcessSampler()

    last = time.monotonic()
    seq = 0
    # Prime the delta-based samplers so the first emitted line already has rates.
    cpu.sample()
    disks.sample(1.0, time.time())
    net.sample(1.0, time.time(), controller.detail > 0)
    if controller.detail:
        procs.sample(1.0, controller.detail >= 2)
    time.sleep(min(interval, 1.0) if not once else 0.5)

    last_slow: float | None = None
    last_procs: float | None = None
    sensors_cache: dict | None = None
    battery_cache: dict | None = None
    procs_cache: dict | None = None
    connections_cache: list | None = None

    while not controller.stop:
        now_mono = time.monotonic()
        elapsed = max(0.02, now_mono - last)
        last = now_mono
        now = time.time()
        with controller.lock:
            detail = controller.detail
            focus = controller.focus
            want_public = controller.public_ip_requested
            controller.public_ip_requested = False
            current_interval = controller.interval
        if want_public:
            net.fetch_public_ip()

        payload: dict = {"seq": seq, "t": now, "elapsed": round(elapsed, 3), "interval": current_interval, "errors": []}
        slow_due = last_slow is None or now_mono - last_slow >= 0.95
        if slow_due:
            try:
                sensors_cache = sensors.sample(now)
            except Exception as error:  # noqa: BLE001 - keep streaming on any sampler failure
                sensors_cache = None
                payload["errors"].append(f"sensors: {error}")
            try:
                battery_cache = sample_battery()
            except Exception as error:  # noqa: BLE001
                battery_cache = None
                payload["errors"].append(f"battery: {error}")
            if detail:
                since = elapsed if last_procs is None else max(0.05, now_mono - last_procs)
                try:
                    procs_cache = procs.sample(since, detail >= 2)
                except Exception as error:  # noqa: BLE001
                    procs_cache = None
                    payload["errors"].append(f"procs: {error}")
                last_procs = now_mono
            else:
                procs.reset()
                procs_cache = None
                last_procs = None
            connections_cache = None
            if detail and focus == "network":
                try:
                    connections_cache = procs.network_usage(detail >= 2)
                except Exception as error:  # noqa: BLE001
                    payload["errors"].append(f"connections: {error}")
            last_slow = now_mono
        for key, fn in (
            ("cpu", cpu.sample),
            ("gpu", gpu.sample),
            ("mem", sample_memory),
            ("disks", lambda: disks.sample(elapsed, now)),
            ("net", lambda: net.sample(elapsed, now, detail > 0)),
        ):
            try:
                payload[key] = fn()
            except Exception as error:  # noqa: BLE001
                payload[key] = None
                payload["errors"].append(f"{key}: {error}")
        if isinstance(payload.get("net"), dict):
            payload["net"]["procs"] = connections_cache
        payload["sensors"] = sensors_cache
        payload["battery"] = battery_cache
        payload["procs"] = procs_cache
        try:
            sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            break
        seq += 1
        if once:
            break
        spent = time.monotonic() - now_mono
        time.sleep(max(0.02, current_interval - spent))

    gpu.stop()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
