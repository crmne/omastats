#!/usr/bin/env python3
"""Battery fallback regression tests without depending on host hardware."""

from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)
TTL = NAMESPACE["DEVICE_BATTERY_TTL"]
RETRY = NAMESPACE["DEVICE_BATTERY_RETRY"]


def write(base, entry, attribute, value):
    Path(base, entry).mkdir(parents=True, exist_ok=True)
    Path(base, entry, attribute).write_text(value)


class DeviceBatteryTests(unittest.TestCase):
    peripherals = staticmethod(NAMESPACE["device_peripherals"])

    def test_a_device_battery_is_read_once_per_ttl(self):
        with tempfile.TemporaryDirectory() as base:
            write(base, "hid-mouse-battery", "capacity", "80\n")
            write(base, "hid-mouse-battery", "model_name", "Magic Mouse\n")
            cache = {}
            first = self.peripherals(base, ["hid-mouse-battery"], cache, 100.0)
            self.assertEqual(first, [{"name": "Magic Mouse", "percent": 80, "status": "Unknown"}])
            write(base, "hid-mouse-battery", "capacity", "79\n")
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, 100.0 + TTL - 1)[0]["percent"], 80)
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, 100.0 + TTL)[0]["percent"], 79)

    def test_a_failed_read_keeps_the_last_value_and_is_retried_sooner(self):
        with tempfile.TemporaryDirectory() as base:
            write(base, "hid-mouse-battery", "capacity", "50\n")
            cache = {}
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, 0.0)[0]["percent"], 50)
            Path(base, "hid-mouse-battery", "capacity").unlink()
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, TTL)[0]["percent"], 50)
            write(base, "hid-mouse-battery", "capacity", "40\n")
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, TTL + RETRY - 1)[0]["percent"], 50)
            self.assertEqual(self.peripherals(base, ["hid-mouse-battery"], cache, TTL + RETRY)[0]["percent"], 40)

    def test_devices_follow_the_live_list(self):
        with tempfile.TemporaryDirectory() as base:
            write(base, "hid-a-battery", "capacity", "10\n")
            write(base, "hid-b-battery", "capacity", "20\n")
            cache = {}
            self.peripherals(base, ["hid-a-battery"], cache, 0.0)
            self.assertIn("hid-a-battery", cache)
            self.assertEqual(self.peripherals(base, ["hid-b-battery"], cache, 0.0)[0]["percent"], 20)
            self.assertNotIn("hid-a-battery", cache)


if __name__ == "__main__":
    unittest.main()
