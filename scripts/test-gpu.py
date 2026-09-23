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

    def test_a_suspended_or_always_on_card_is_read_every_time(self):
        for control, status in (("auto", "suspended"), ("on", "active")):
            device, busy = self.card(control, status)
            gate = NAMESPACE["RuntimePmGate"]()
            self.assertEqual(gate.read(str(device), busy, 100.0), "37")
            (device / "gpu_busy_percent").write_text("80\n")
            self.assertEqual(gate.read(str(device), busy, 101.0), "80")


if __name__ == "__main__":
    unittest.main()
