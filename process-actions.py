#!/usr/bin/python3
"""Inspect one sampled process group and act on explicitly selected members."""

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import runpy
import select
import signal
import sys
import time


# Use the same grouping and bounded helper execution as the sampler. Loading
# by path keeps Python's isolated mode without adding this directory to PATH.
SAMPLER_PATH = Path(__file__).resolve().with_name("sampler.py")
sampler = runpy.run_path(str(SAMPLER_PATH))
display_name = sampler["display_name"]
run = sampler["run"]
PROC_SCAN_LIMIT = sampler["PROCESS_SCAN_LIMIT"]
PAGE_SIZE = sampler["PAGE_SIZE"]
GROUP_BYTES = sampler["EXTERNAL_TEXT_LIMIT"]

MAX_MEMBERS = 128
MAX_WINDOWS = 128
MAX_TARGETS = MAX_MEMBERS + MAX_WINDOWS
REQUEST_BYTES = 16 * 1024
REQUEST_SECONDS = 4.0
PROC = Path("/proc")
PROTECTED = {"hyprland", "start-hyprland", "xwayland", "quickshell", "omarchy-shell", "systemd", "omastats-sampler"}
STABLE_ID = re.compile(r"[0-9a-fA-F]{1,16}")
START_TICKS = re.compile(r"[0-9]{1,20}")
CONTROLS = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]")


class Unavailable(Exception):
    """The compositor's window list could not be verified."""


@dataclass(frozen=True)
class ProcStat:
    name: str
    state: str
    parent: int
    start: int
    memory: int


@dataclass(frozen=True)
class Target:
    pid: int
    start: int
    window: str = ""


def read_proc(pid, name, limit):
    with (PROC / str(pid) / name).open("rb") as file:
        data = file.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Oversized proc record")
    return data


def proc_stat(pid):
    data = read_proc(pid, "stat", 4096).decode("utf-8", "replace")
    # The kernel permits both parentheses and whitespace in comm.
    first, last = data.find("("), data.rfind(")")
    fields = data[last + 1:].split()
    if first < 0 or last <= first or len(fields) < 22:
        raise ValueError("Invalid proc stat")
    return ProcStat(data[first + 1:last], fields[0], int(fields[1]), int(fields[19]),
                    max(0, int(fields[21])) * PAGE_SIZE)


def ancestors():
    protected = {1, os.getpid()}
    pid = os.getppid()
    for _ in range(256):
        if pid <= 1 or pid in protected:
            break
        protected.add(pid)
        try:
            pid = proc_stat(pid).parent
        except (OSError, ValueError):
            break
    return protected


def can_act(pid, protected):
    uid = os.getuid()
    if uid == 0 or uid != os.geteuid() or pid <= 1 or pid in protected:
        return False
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        return False
    status = read_proc(pid, "status", 64 * 1024)
    credentials = next((line[4:].split() for line in status.split(b"\n") if line.startswith(b"Uid:")), [])
    if credentials != [str(uid).encode()] * 4:
        return False
    exe = os.readlink(PROC / str(pid) / "exe").removesuffix(" (deleted)")
    if Path(exe).name.casefold() in PROTECTED:
        return False
    if Path(exe).name.startswith("python"):
        args = read_proc(pid, "cmdline", 64 * 1024).split(b"\0")
        if os.fsencode(SAMPLER_PATH) in args:
            return False
    return True


def window_id(value):
    if isinstance(value, str) and STABLE_ID.fullmatch(value) and int(value, 16) > 0:
        return format(int(value, 16), "x")
    return ""


def window_title(client):
    for field in ("title", "class"):
        raw = client.get(field)
        if isinstance(raw, str):
            title = CONTROLS.sub(" ", raw[:160]).strip()
            if title:
                return title.encode("utf-8", "replace").decode("utf-8")
    return ""


def hyprctl(args, deadline):
    # Require the calling shell's compositor. An absent signature must never
    # be allowed to fall back to another Hyprland instance.
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        raise Unavailable
    reply = run(["hyprctl", *args], timeout=min(remaining, 0.8))
    if not reply:
        raise Unavailable
    return reply


def clients(deadline):
    try:
        data = json.loads(hyprctl(["-j", "-a", "clients"], deadline))
    except (ValueError, RecursionError) as error:
        raise Unavailable from error
    if not isinstance(data, list):
        raise Unavailable
    result = {}
    ids = set()
    for client in data:
        if not isinstance(client, dict) or type(client.get("pid")) is not int:
            raise Unavailable
        pid = client["pid"]
        if pid <= 1:
            continue
        # Even a client with no stable selector blocks a process signal.
        windows = result.setdefault(pid, [])
        if client.get("mapped") is not True:
            continue
        identifier = window_id(client.get("stableId"))
        if identifier:
            if identifier in ids:
                raise Unavailable
            ids.add(identifier)
            windows.append({"id": identifier, "title": window_title(client)})
    return result


def list_group(group, deadline):
    try:
        windows = clients(deadline)
    except Unavailable:
        windows = None
    protected = ancestors()
    members = []
    truncated = False
    remaining_windows = MAX_WINDOWS
    with os.scandir(PROC) as entries:
        for index, entry in enumerate(entries):
            if index >= PROC_SCAN_LIMIT or time.monotonic() >= deadline:
                truncated = True
                break
            if not entry.name.isdecimal():
                continue
            pid = int(entry.name)
            try:
                stat = proc_stat(pid)
                if stat.state in ("Z", "X", "x") or display_name(pid, stat.name) != group:
                    continue
            except (OSError, ValueError):
                continue
            if len(members) >= MAX_MEMBERS:
                truncated = True
                break
            try:
                allowed = windows is not None and can_act(pid, protected)
            except (OSError, ValueError):
                allowed = False
            visible = windows.get(pid, []) if allowed else []
            if len(visible) > remaining_windows:
                truncated = True
            visible = visible[:remaining_windows]
            remaining_windows -= len(visible)
            members.append({"pid": pid, "start": str(stat.start), "mem": stat.memory,
                            "canTerminate": allowed and pid not in windows, "windows": visible})
    members.sort(key=lambda member: (-member["mem"], member["pid"]))
    return {"status": "ok", "windowsAvailable": windows is not None,
            "truncated": truncated, "members": members}


def parse_targets(raw):
    if len(raw.encode("utf-8")) > REQUEST_BYTES:
        raise ValueError("Oversized request")
    data = json.loads(raw)
    if not isinstance(data, list) or not 1 <= len(data) <= MAX_TARGETS:
        raise ValueError("Invalid target list")
    targets = set()
    identities = {}
    for item in data:
        if not isinstance(item, list) or len(item) not in (2, 3):
            raise ValueError("Invalid target")
        pid, start = item[:2]
        if type(pid) is not int or not 1 < pid < 2**31 or not isinstance(start, str) or not START_TICKS.fullmatch(start):
            raise ValueError("Invalid process identity")
        window = window_id(item[2]) if len(item) == 3 else ""
        if len(item) == 3 and not window:
            raise ValueError("Invalid window selector")
        target = Target(pid, int(start), window)
        identity = (target.start, bool(window))
        if target in targets or identities.setdefault(pid, identity) != identity:
            raise ValueError("Conflicting targets")
        targets.add(target)
    return sorted(targets, key=lambda target: (not target.window, target.pid, target.window))


def apply_target(group, target, windows, protected, deadline):
    if time.monotonic() >= deadline:
        return False
    try:
        pidfd = os.pidfd_open(target.pid)
    except (AttributeError, OSError):
        return False
    try:
        stat = proc_stat(target.pid)
        if stat.start != target.start or stat.state in ("Z", "X", "x"):
            return False
        if not can_act(target.pid, protected) or display_name(target.pid, stat.name) != group:
            return False
        poller = select.poll()
        poller.register(pidfd, select.POLLIN)
        if poller.poll(0):
            return False
        if target.window:
            if not any(window["id"] == target.window for window in windows.get(target.pid, [])):
                return False
            # Stable IDs survive focus changes and are unique within this
            # compositor. Only validated hexadecimal IDs enter the dispatch.
            request = f'hl.dsp.window.close({{ window = "stableid:{target.window}" }})'
            return hyprctl(["dispatch", request], deadline).strip() == "ok"
        # A background process may have opened a window since the other
        # targets were checked. Verify it immediately before the signal.
        if target.pid in clients(deadline):
            return False
        signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        return True
    except (OSError, ValueError, Unavailable):
        return False
    finally:
        os.close(pidfd)


def apply(group, targets, deadline):
    protected = ancestors()
    sent = 0
    windows = {}
    if any(target.window for target in targets):
        try:
            windows = clients(deadline)
        except Unavailable:
            return {"status": "skipped", "sent": 0, "skipped": len(targets)}
    # parse_targets orders normal window closure before process signals.
    for target in targets:
        if apply_target(group, target, windows, protected, deadline):
            sent += 1
    return {"status": "sent" if sent else "skipped", "sent": sent, "skipped": len(targets) - sent}


def main(args):
    deadline = time.monotonic() + REQUEST_SECONDS
    try:
        if len(args) not in (2, 3) or not 0 < len(args[1].encode("utf-8")) <= GROUP_BYTES:
            raise ValueError("Invalid group")
        mode, group = args[:2]
        if mode == "list" and len(args) == 2:
            result = list_group(group, deadline)
        elif mode == "apply" and len(args) == 3:
            result = apply(group, parse_targets(args[2]), deadline)
        else:
            raise ValueError("Invalid action")
    except (OSError, ValueError, RecursionError):
        result = {"status": "failed"}
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main(sys.argv[1:])
