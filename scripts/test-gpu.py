#!/usr/bin/env python3
"""GPU fallback regression tests without depending on host hardware."""

from pathlib import Path
from types import SimpleNamespace
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


if __name__ == "__main__":
    unittest.main()
