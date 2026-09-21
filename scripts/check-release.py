#!/usr/bin/env python3
"""Validate release versions and the checksummed plugin binaries."""

import hashlib
import json
from pathlib import Path
import sys
import tomllib


ROOT = Path(__file__).resolve().parent.parent
manifest = json.loads((ROOT / "manifest.json").read_text())
cargo = tomllib.loads((ROOT / "sampler/Cargo.toml").read_text())
lock = tomllib.loads((ROOT / "sampler/Cargo.lock").read_text())
version = manifest["version"]
assert sys.argv[1:] == [f"v{version}"], "Release tag must match manifest.json"
assert cargo["package"]["version"] == version, "Cargo.toml version mismatch"
assert next(p["version"] for p in lock["package"] if p["name"] == "omastats-sampler") == version
for name in ("omastats-sampler", "omastats-sampler-aarch64"):
    binary = ROOT / "bin" / name
    expected, recorded_path = binary.with_suffix(".sha256").read_text().split()
    assert recorded_path == f"bin/{name}", "Unexpected checksum path"
    with binary.open("rb") as source:
        assert hashlib.file_digest(source, "sha256").hexdigest() == expected, name
print(f"OmaStats {version}: manifest, Cargo versions and bundled checksums agree")
