#!/usr/bin/env python3
"""GPU fallback regression tests without depending on host hardware."""

from pathlib import Path
from types import SimpleNamespace
import os
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)


class GpuTests(unittest.TestCase):
    def test_boot_display_can_be_discrete(self):
        amd = SimpleNamespace(slot="0000:10:00.0", boot_vga=False)
        nvidia = SimpleNamespace(slot="0000:01:00.0", boot_vga=True)
        self.assertEqual(NAMESPACE["order_cards"]([amd, nvidia]), [nvidia, amd])

    def test_no_boot_display_uses_stable_pci_order(self):
        cards = [SimpleNamespace(slot=slot, boot_vga=False)
                 for slot in ("0000:02:00.0", "0000:00:02.0", "0000:01:00.0")]
        self.assertEqual([c.slot for c in NAMESPACE["order_cards"](cards)],
                         ["0000:00:02.0", "0000:01:00.0", "0000:02:00.0"])

    def test_missing_nvidia_helper_preserves_both_gpus(self):
        values = {
            "/sys/class/drm/card0/device/vendor": "0x1002",
            "/sys/class/drm/card1/device/vendor": "0x10de",
            "/sys/class/drm/card1/device/boot_vga": "1",
        }
        with patch("os.path.isdir", return_value=True), patch.dict(NAMESPACE, {
            "list_dir": lambda path: ["card0", "card1"] if path == "/sys/class/drm" else [],
            "read_text": lambda path: values.get(path, ""),
            "read_float": lambda path: None,
            "command_path": lambda name: None,
            "pci_slot": lambda path: "0000:01:00.0" if "card1" in path else "0000:10:00.0",
        }):
            sampler = NAMESPACE["GpuSampler"]()
            try:
                cards = sampler.sample_all()
                self.assertEqual([c["id"] for c in cards], ["0000:01:00.0", "0000:10:00.0"])
                self.assertEqual(cards[0]["vendor"], "nvidia")
                self.assertIsNone(cards[0]["util"])
            finally:
                sampler.stop()


class NvidiaAccessTests(unittest.TestCase):
    access = staticmethod(NAMESPACE["nvidia_access"])

    def test_always_on_cards_stream(self):
        self.assertEqual(self.access(["on"], None, 100.0), ("stream", False))

    def test_a_sleeping_card_is_never_asked(self):
        self.assertEqual(self.access(["on", "suspended"], None, 100.0), ("rest", False))

    def test_an_awake_card_that_can_suspend_is_queried_then_left_alone(self):
        self.assertEqual(self.access([5.0], None, 100.0), ("query", True))
        # The process list in the same tick shares the window.
        self.assertEqual(self.access([5.0], 100.0, 100.1), ("query", False))
        self.assertEqual(self.access([5.0], 100.0, 103.0), ("rest", False))
        self.assertEqual(self.access([5.0], 100.0, 106.0), ("query", True))

    def test_runtime_state_follows_control_and_status(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        device = Path(root.name)
        (device / "power").mkdir()
        (device / "power/control").write_text("auto\n")
        (device / "power/runtime_status").write_text("active\n")
        state = NAMESPACE["runtime_state"]
        # NVIDIA leaves the delay unreadable.
        self.assertEqual(state(str(device)), NAMESPACE["DEFAULT_SUSPEND_DELAY"])
        (device / "power/autosuspend_delay_ms").write_text("2000\n")
        self.assertEqual(state(str(device)), 2.0)
        (device / "power/runtime_status").write_text("suspended\n")
        self.assertEqual(state(str(device)), "suspended")
        (device / "power/control").write_text("on\n")
        self.assertEqual(state(str(device)), "on")

    def test_a_sleeping_card_reports_only_its_identity(self):
        sampler = NAMESPACE["GpuSampler"].__new__(NAMESPACE["GpuSampler"])
        sampler.lock = NAMESPACE["threading"].Lock()
        sampler.latest = {"0000:01:00.0": {"name": "RTX", "vendor": "nvidia", "util": 40.0, "temp": 60.0}}
        sampler.asleep = {"0000:01:00.0"}
        card = SimpleNamespace(kind="nvidia", slot="0000:01:00.0", name="")
        reading = sampler._sample_card(card)
        self.assertTrue(reading["asleep"])
        self.assertEqual(reading["name"], "RTX")
        self.assertIsNone(reading["util"])
        self.assertNotIn("temp", reading)


class MemoryClockTests(unittest.TestCase):
    def test_mclk_is_read_by_its_label_only(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        hwmon = Path(root.name)
        (hwmon / "freq1_input").write_text("2400000000\n")
        (hwmon / "freq1_label").write_text("sclk\n")
        labelled = NAMESPACE["GpuSampler"]._hwmon_labelled
        self.assertIsNone(labelled(str(hwmon), "freq", "mclk"), "sclk is not the memory clock")
        (hwmon / "freq2_input").write_text("96000000\n")
        (hwmon / "freq2_label").write_text("mclk\n")
        self.assertEqual(labelled(str(hwmon), "freq", "mclk"), 96000000.0)


class RuntimePmTests(unittest.TestCase):
    def card(self, control: str, status: str) -> tuple[Path, str]:
        """A fake amdgpu PCI device with runtime PM files and one attribute."""
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        device = Path(root.name) / "0000:3b:00.0"
        (device / "power").mkdir(parents=True)
        (Path(root.name) / "amdgpu").mkdir()
        os.symlink(Path(root.name) / "amdgpu", device / "driver")
        (device / "power/control").write_text(f"{control}\n")
        (device / "power/runtime_status").write_text(f"{status}\n")
        (device / "power/autosuspend_delay_ms").write_text("5000\n")
        (device / "gpu_busy_percent").write_text("37\n")
        return device, str(device / "gpu_busy_percent")

    def test_an_awake_card_repeats_its_last_reading(self):
        device, busy = self.card("auto", "active")
        gate = NAMESPACE["RuntimePmGate"]()
        self.assertEqual(gate.read(str(device), busy, 100.0), "37")
        (device / "gpu_busy_percent").write_text("80\n")
        self.assertEqual(gate.read(str(device), busy, 100.1), "80")  # same pass
        (device / "gpu_busy_percent").write_text("90\n")
        self.assertEqual(gate.read(str(device), busy, 101.0), "80")
        self.assertEqual(gate.read(str(device), busy, 105.9), "80")
        self.assertEqual(gate.read(str(device), busy, 106.0), "90")

    def test_an_awake_card_is_not_read_for_the_first_time_in_its_cooldown(self):
        device, busy = self.card("auto", "active")
        gate = NAMESPACE["RuntimePmGate"]()
        self.assertEqual(gate.read(str(device), busy, 100.0), "37")
        (device / "temp1_input").write_text("45000\n")
        temp = str(device / "temp1_input")
        self.assertEqual(gate.read(str(device), temp, 101.0), "")
        self.assertEqual(gate.read(str(device), temp, 106.0), "45000")

    def test_a_suspended_or_always_on_card_is_read_every_time(self):
        for control, status in (("auto", "suspended"), ("on", "active")):
            device, busy = self.card(control, status)
            gate = NAMESPACE["RuntimePmGate"]()
            self.assertEqual(gate.read(str(device), busy, 100.0), "37")
            (device / "gpu_busy_percent").write_text("80\n")
            self.assertEqual(gate.read(str(device), busy, 101.0), "80")


AMDGPU_FDINFO = """pos:\t0
drm-driver:\tamdgpu
drm-client-id:\t20516
drm-pdev:\t0000:11:00.0
drm-resident-vram:\t12 KiB
drm-resident-gtt:\t2 MiB
drm-resident-cpu:\t0
drm-memory-vram:\t12 KiB
drm-engine-gfx:\t6438199656611 ns
drm-engine-compute:\t99404265 ns
"""

PMON = """# gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command
# Idx           #    C/G      %      %      %      %      %      %     MB     MB    name
    0      37129     C      -      -      -      -      -      -   6196      0    llama-server
    0    1904057     G     30      1      -      -      -      -      6      0    Hyprland
    1        812     G      4      0      -      -      -      -     12      0    other-card
"""


class GpuProcessTests(unittest.TestCase):
    def test_amdgpu_fdinfo_gives_engines_and_regions(self):
        client = NAMESPACE["parse_drm_fdinfo"](AMDGPU_FDINFO)
        self.assertEqual((client["pdev"], client["id"]), ("0000:11:00.0", "20516"))
        self.assertEqual(client["engines"]["gfx"]["busy"], 6438199656611)
        memory = NAMESPACE["client_memory"]
        self.assertEqual(memory(client, False), 12 * 1024)
        self.assertEqual(memory(client, True), 12 * 1024 + 2 * 1024 * 1024)

    def test_a_file_without_a_client_is_not_a_drm_client(self):
        self.assertIsNone(NAMESPACE["parse_drm_fdinfo"]("pos:\t0\nflags:\t02\n"))

    def test_busy_time_becomes_the_busiest_engines_share(self):
        def counter(busy, capacity=1):
            return {"busy": busy, "total": None, "capacity": capacity}
        busy = NAMESPACE["client_busy"]
        before = {"gfx": counter(1_000_000_000), "compute": counter(0)}
        now = {"gfx": counter(1_250_000_000), "compute": counter(100_000_000)}
        self.assertEqual(busy(now, before, 1.0), 25.0)
        self.assertEqual(busy(now, None, 1.0), 0.0)
        self.assertEqual(busy({"vcn": counter(10**9, 2)}, {"vcn": counter(0, 2)}, 1.0), 50.0)

    def test_xe_cycles_are_measured_against_total_cycles(self):
        parse = NAMESPACE["parse_drm_fdinfo"]
        head = "drm-client-id:\t3\ndrm-pdev:\t0000:00:02.0\n"
        before = parse(head + "drm-cycles-rcs:\t500\ndrm-total-cycles-rcs:\t1000\n")["engines"]
        now = parse(head + "drm-cycles-rcs:\t800\ndrm-total-cycles-rcs:\t2000\n")["engines"]
        self.assertEqual(NAMESPACE["client_busy"](now, before, 1.0), 30.0)

    def test_pmon_rows_follow_the_header_and_card_index(self):
        rows = NAMESPACE["parse_pmon"](PMON, {"0": "0000:01:00.0"})
        self.assertEqual([r["pid"] for r in rows], [37129, 1904057])
        self.assertEqual(rows[0]["util"], 0.0)
        self.assertEqual(rows[0]["mem"], 6196 * 1024 * 1024)
        self.assertEqual((rows[1]["name"], rows[1]["util"]), ("Hyprland", 30.0))


class CpuPowerTests(unittest.TestCase):
    def test_ppt_in_milliwatts_is_recognised(self):
        watts = NAMESPACE["ppt_watts"]
        self.assertEqual(watts(15_000_000), 15.0)
        self.assertEqual(watts(165_000), 165.0)
        self.assertEqual(watts(800_000), 0.8)

    def test_energy_counters_survive_one_wraparound(self):
        delta = NAMESPACE["energy_delta"]
        self.assertEqual(delta(1_500, 1_000, 10_000), 500)
        self.assertEqual(delta(200, 9_800, 10_000), 400)
        self.assertEqual(delta(200, 9_800, 0), 0)


class PowerSamplerTests(unittest.TestCase):
    def test_zones_add_up_by_kind_and_the_psu_reports_its_total(self):
        files = {
            "/sys/class/powercap/intel-rapl:0/name": "package-0",
            "/sys/class/powercap/intel-rapl:0:0/name": "core",
            "/sys/class/powercap/intel-rapl:1:0/name": "core",
            "/sys/class/powercap/intel-rapl:0:1/name": "dram",
            "/sys/class/hwmon/hwmon4/name": "corsairpsu",
            "/sys/class/hwmon/hwmon4/power1_label": "power total",
            "/sys/class/hwmon/hwmon4/power2_label": "power 12v",
        }
        energy = {"intel-rapl:0:0": 1_000_000, "intel-rapl:1:0": 2_000_000, "intel-rapl:0:1": 0}
        dirs = {
            "/sys/class/powercap": ["intel-rapl:0", "intel-rapl:0:0", "intel-rapl:1:0", "intel-rapl:0:1"],
            "/sys/class/hwmon": ["hwmon4"],
            "/sys/class/hwmon/hwmon4": ["name", "power2_input", "power1_input", "power1_label", "power2_label"],
        }
        clock = [100.0]

        def read_int(path, default=None):
            zone = path.split("/")[4]
            return energy.get(zone, default)

        with patch.dict(NAMESPACE, {
            "list_dir": lambda path: dirs.get(path, []),
            "read_text": lambda path: files.get(path, ""),
            "read_int": read_int,
            "read_float": lambda path: 245_500_000.0 if path.endswith("power1_input") else 9.0,
        }), patch("os.access", return_value=True), patch("time.monotonic", lambda: clock[0]):
            sampler = NAMESPACE["PowerSampler"]()
            self.assertEqual(sampler.psu, "/sys/class/hwmon/hwmon4/power1_input")
            first = sampler.sample()
            self.assertEqual(first["zones"], {}, "rates need two readings")
            self.assertEqual(first["psu"], 245.5)
            clock[0] = 102.0
            energy["intel-rapl:0:0"] += 20_000_000
            energy["intel-rapl:1:0"] += 10_000_000
            energy["intel-rapl:0:1"] += 4_000_000
            self.assertEqual(sampler.sample()["zones"], {"core": 15.0, "dram": 2.0})


if __name__ == "__main__":
    unittest.main()
