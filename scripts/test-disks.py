#!/usr/bin/env python3
"""Disk volume regression tests without depending on host storage."""

from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)

MOUNTS = """\
30 1 0:30 / / rw,noatime shared:1 - zfs tank/ROOT/root rw,xattr
31 30 0:31 / /home rw,noatime shared:2 - zfs tank/ROOT/home rw,xattr
32 30 0:32 / /.zfs/snapshot/daily ro shared:3 - zfs tank/ROOT/root@daily ro
33 30 259:1 / /boot/efi rw,relatime shared:4 - vfat /dev/nvme0n1p1 rw,fmask=0022
"""
ZFS_LIST = "tank\t800\t200\n"
ZPOOL_LIST = "tank\n\tmirror-0\n\t\t/dev/nvme0n1p2\n\t\t/dev/nvme1n1p2\n"


def statvfs(path):
    return SimpleNamespace(f_blocks=1 << 20, f_bfree=1 << 19, f_bavail=1 << 19, f_frsize=4096)


class DiskTests(unittest.TestCase):
    def test_disks_are_identified_by_model_and_serial(self):
        links = [
            ("nvme-eui.0025385991b33317", "nvme1n1"),
            ("nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X_1", "nvme1n1"),
            ("nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X", "nvme1n1"),
            ("nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X-part1", "nvme1n1p1"),
            ("wwn-0x5002538e40e5728a", "sda"),
            ("scsi-SATA_Samsung_SSD_860_S4CYNF0M312756K", "sda"),
            ("ata-Samsung_SSD_860_QVO_2TB_S4CYNF0M312756K", "sda"),
            ("wwn-0x500a0751e2247779", "sdb"),
            ("dm-name-root", "dm-0"),
        ]
        self.assertEqual(NAMESPACE["pick_disk_ids"](links), {
            "nvme1n1": "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X",
            "sda": "ata-Samsung_SSD_860_QVO_2TB_S4CYNF0M312756K",
            "sdb": "wwn-0x500a0751e2247779",
        })

    def test_shared_sensor_chip_names_are_told_apart_by_device(self):
        sensor_id = NAMESPACE["sensor_id"]
        self.assertEqual(sensor_id({"name": "k10temp", "device": "0000:00:18.3"}, "temp1", False), "k10temp/temp1")
        self.assertEqual(sensor_id({"name": "nvme", "device": "0000:02:00.0"}, "temp1", True), "nvme@0000:02:00.0/temp1")
        self.assertEqual(sensor_id({"name": "nvme", "device": ""}, "temp1", True), "nvme/temp1")

    def test_zpool_leaves_are_first_data_devices(self):
        raw = ZPOOL_LIST + "\nlogs\n\t/dev/sdc1\nfast\n\t/dev/sda1\ncache\n\t/dev/sdd1\n"
        self.assertEqual(NAMESPACE["parse_zpool_leaves"](raw),
                         {"tank": "/dev/nvme0n1p2", "fast": "/dev/sda1"})

    def test_zfs_space_takes_only_plain_byte_counts(self):
        raw = ZFS_LIST + "bad line\nneg\t-5\t1\nsep\t1_000\t1\n"
        self.assertEqual(NAMESPACE["parse_zfs_space"](raw), {"tank": (800, 200)})

    def test_pool_without_zpool_output_keeps_its_space_and_no_drive(self):
        outputs = {"zfs": ZFS_LIST, "zpool": "", "systemctl": "enabled\n"}
        sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
        with patch("os.statvfs", statvfs), patch.dict(NAMESPACE, {
            "read_text": lambda path, default="": MOUNTS if path == "/proc/self/mountinfo" else default,
            "run": lambda cmd, timeout=2.0: outputs[cmd[0]],
        }):
            pool = sampler._volumes()[0]
        self.assertEqual((pool["device"], pool["size"], pool["disk"]), ("tank", 1000, ""))

    def test_zfs_datasets_collapse_into_one_pool_volume(self):
        outputs = {"zfs": ZFS_LIST, "zpool": ZPOOL_LIST, "systemctl": "enabled\n"}
        sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
        with patch("os.statvfs", statvfs), patch.dict(NAMESPACE, {
            "read_text": lambda path, default="": MOUNTS if path == "/proc/self/mountinfo" else default,
            "run": lambda cmd, timeout=2.0: outputs[cmd[0]],
        }), patch.object(NAMESPACE["DiskSampler"], "_parent_disk",
                         staticmethod(lambda device: device.removeprefix("/dev/").removesuffix("p2").removesuffix("p1"))):
            volumes = sampler._volumes()
        self.assertEqual([(v["mount"], v["device"]) for v in volumes],
                         [("/", "tank"), ("/boot/efi", "/dev/nvme0n1p1")])
        pool = volumes[0]
        self.assertEqual((pool["size"], pool["used"], pool["avail"], pool["disk"]),
                         (1000, 800, 200, "nvme0n1"))


    def test_mountinfo_gives_ids_escaped_paths_and_both_option_sets(self):
        raw = (
            "32 2 0:29 /@ / rw,relatime shared:1 - btrfs /dev/mapper/root rw,ssd,discard=async\n"
            "1215 29 8:65 / /run/media/me/MY\\040STICK rw,nosuid master:1 - vfat /dev/sde1 rw,uid=1000,flush\n"
            "90 32 0:61 / /mnt/nuc/music\\040production rw - cifs //nuc.local/Music\\040Production rw\n"
            "broken line\n"
        )
        mounts = NAMESPACE["parse_mountinfo"](raw)
        self.assertEqual(len(mounts), 3)
        self.assertEqual(mounts[0]["id"], 32)
        self.assertEqual(mounts[0]["options"], ["rw", "relatime", "rw", "ssd", "discard=async"])
        self.assertEqual(mounts[1]["mount"], "/run/media/me/MY STICK")
        self.assertIn("flush", mounts[1]["options"])
        self.assertEqual(mounts[2]["source"], "//nuc.local/Music Production")
        self.assertEqual(NAMESPACE["unescape_mount"]("a\\134b\\777"), "a\\b\\777")

    def test_disk_load_is_latency_queue_and_busy_time(self):
        parts = "259 0 nvme0n1 100 0 800 50 200 0 1600 450 3 900 2000 10 0 0 0 4 10".split()
        before = NAMESPACE["parse_diskstats"](parts)
        self.assertEqual(before, (800 * 512, 1600 * 512, 314, 510, 900, 2000))
        after = (before[0], before[1], before[2] + 40, before[3] + 2000, before[4] + 900, before[5] + 3000)
        self.assertEqual(NAMESPACE["disk_load"](before, after, 1.0), {"latency": 50.0, "queue": 3.0, "busy": 90.0})
        self.assertIsNone(NAMESPACE["disk_load"](before, before, 1.0)["latency"])

    @staticmethod
    def volume(fstype, mount, kind, rotational):
        return {"mount": mount, "device": "/dev/omastats-test-none", "fstype": fstype, "disk": "sdz",
                "key": "sdz", "kind": kind, "rotational": rotational}

    def test_ssds_without_any_trim_are_flagged(self):
        checks = NAMESPACE["volume_checks"]
        ssd = self.volume("ext4", "/data", "internal", False)
        self.assertEqual([c["id"] for c in checks(ssd, ["rw"], False)], ["trim-off"])
        self.assertEqual(checks(ssd, ["rw"], True), [])
        self.assertEqual(checks(ssd, ["rw"], None), [])
        self.assertEqual(checks(ssd, ["discard=async"], False), [])
        self.assertEqual(checks(self.volume("ext4", "/data", "internal", True), ["rw"], False), [])
        self.assertEqual(checks(self.volume("cifs", "/mnt/s", "network", False), ["rw"], False), [])

    def test_fat_drives_mounted_with_flush_are_flagged(self):
        stick = self.volume("vfat", "/mnt/stick", "external", True)
        found = NAMESPACE["volume_checks"](stick, ["rw", "flush", "dirsync"], True)
        self.assertEqual([c["id"] for c in found], ["fat-flush"])
        self.assertEqual(found[0]["flags"], ["flush", "dirsync"])
        # Outside UDisks there is no per-drive option file to fix it with.
        self.assertIsNone(found[0]["fix"])
        self.assertEqual(NAMESPACE["volume_checks"](stick, ["rw", "utf8"], True), [])

    def test_only_plain_names_reach_a_fix(self):
        plain = NAMESPACE["plain_name"]
        for good in ("root", "D71B-4467", "/dev/sde1"):
            self.assertTrue(plain(good), good)
        for bad in ("", "root; rm -rf /", "$(id)", "/dev/../etc"):
            self.assertFalse(plain(bad), bad)

    def test_network_mounts_are_listed_without_a_drive(self):
        mounts = "90 30 0:61 / /mnt/nuc/music rw - cifs //nuc.local/Music rw\n"
        sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
        with patch.dict(NAMESPACE, {
            "read_text": lambda path, default="": mounts if path == "/proc/self/mountinfo" else default,
            "statvfs_bounded": statvfs,
        }):
            volumes = sampler._volumes()
        self.assertEqual([(v["kind"], v["key"], v["disk"]) for v in volumes],
                         [("network", "//nuc.local/Music", "")])
        self.assertEqual(sampler.mount_keys, {90: "//nuc.local/Music"})


if __name__ == "__main__":
    unittest.main()
