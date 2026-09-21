#!/usr/bin/env python3
"""Check native binary selection without executing a foreign architecture."""

import errno
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)


class Executed(Exception):
    """A successful exec never returns to the launcher."""


class LauncherTests(unittest.TestCase):
    def launch(self, machine, available, incompatible=()):
        attempts = []

        def execute(path, argv):
            attempts.append(path)
            self.assertEqual(argv, [path, "--interval", "0.1"])
            if path in incompatible:
                raise OSError(errno.ENOEXEC, "Exec format error")
            raise Executed

        with patch("os.uname", return_value=SimpleNamespace(machine=machine)), \
             patch("os.path.isfile", side_effect=lambda p: p in available), \
             patch("os.access", side_effect=lambda p, mode: p in available), \
             patch("os.execv", side_effect=execute):
            try:
                NAMESPACE["exec_compiled_sampler"](["--interval", "0.1"])
            except Executed:
                pass
        return attempts

    def test_bundled_binary_matches_machine(self):
        x86 = str(ROOT / "bin/omastats-sampler")
        arm = str(ROOT / "bin/omastats-sampler-aarch64")
        for machine, expected in [("x86_64", x86), ("amd64", x86),
                                  ("aarch64", arm), ("arm64", arm)]:
            with self.subTest(machine=machine):
                self.assertEqual(self.launch(machine, [x86, arm]), [expected])

    def test_missing_arm_binary_does_not_try_x86_under_binfmt(self):
        x86 = str(ROOT / "bin/omastats-sampler")
        self.assertEqual(self.launch("aarch64", [x86]), [])

    def test_unknown_machine_falls_back_to_python(self):
        binaries = [str(ROOT / "bin" / name)
                    for name in ("omastats-sampler", "omastats-sampler-aarch64")]
        self.assertEqual(self.launch("riscv64", binaries), [])

    def test_other_architectures_can_install_native_builds(self):
        native = str(ROOT / "bin/omastats-sampler-riscv64")
        self.assertEqual(self.launch("riscv64", [native]), [native])

    def test_incompatible_binary_tries_local_build(self):
        arm = str(ROOT / "bin/omastats-sampler-aarch64")
        local = str(ROOT / "sampler/target/release/omastats-sampler")
        self.assertEqual(self.launch("aarch64", [arm, local], [arm]), [arm, local])

    def test_unusable_binaries_fall_back_to_python(self):
        arm = str(ROOT / "bin/omastats-sampler-aarch64")
        local = str(ROOT / "sampler/target/release/omastats-sampler")
        self.assertEqual(self.launch("aarch64", [arm, local], [arm, local]), [arm, local])


if __name__ == "__main__":
    unittest.main()
