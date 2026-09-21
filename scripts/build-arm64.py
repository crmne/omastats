#!/usr/bin/env python3
"""Build the bundled static ARM64 sampler with a checksum-pinned Rust toolchain."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
HOST = "x86_64-unknown-linux-gnu"
TARGET = "aarch64-unknown-linux-musl"
VERSION = "1.98.0"
# Published checksums from https://static.rust-lang.org/dist/<archive>.sha256.
ARCHIVES = {
    f"rustc-{VERSION}-{HOST}": "0e37cb339f447fc44d6d781073bacacebfdc5612f2600e4c7e84c266f5f3aced",
    f"cargo-{VERSION}-{HOST}": "2f512d170d3dd23e16ababcda32ee2e6d5172d861a7af1f504e0b1e270cafab9",
    f"rust-std-{VERSION}-{HOST}": "f5022e6c95a5ad23cca2513dc8281200f585fa188de6370aa37b128a43f876a3",
    f"rust-std-{VERSION}-{TARGET}": "36f82e96e86ec8a02d0a0a66574f4b7be086771cec41bb8e9d40ba5cbd64c93a",
}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def toolchain(cache):
    prefix = cache / "toolchain"
    stamp = prefix / "omastats-toolchain.json"
    identity = json.dumps(ARCHIVES, sort_keys=True)
    if stamp.is_file() and stamp.read_text() == identity:
        return prefix
    downloads = cache / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    for name, expected in ARCHIVES.items():
        archive = downloads / f"{name}.tar.xz"
        if not archive.is_file() or digest(archive) != expected:
            url = f"https://static.rust-lang.org/dist/{archive.name}"
            print(f"Downloading {url}", flush=True)
            with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
        if digest(archive) != expected:
            raise SystemExit(f"Checksum mismatch: {archive}")
        with tempfile.TemporaryDirectory(dir=cache) as staging:
            with tarfile.open(archive) as bundle:
                bundle.extractall(staging, filter="data")
            subprocess.run(
                ["sh", str(Path(staging) / name / "install.sh"),
                 f"--prefix={prefix}", "--disable-ldconfig"],
                check=True,
            )
    stamp.write_text(identity)
    return prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-dir", type=Path, default=ROOT / ".cache/arm64-build")
    parser.add_argument("--toolchain-dir", type=Path, default=ROOT / ".cache/arm64-toolchain")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("the pinned cross-build runs on x86-64 Linux")
    prefix = toolchain(args.toolchain_dir.resolve())
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")).resolve()
    env = os.environ.copy()
    env.pop("CARGO_ENCODED_RUSTFLAGS", None)
    env.update({
        "CARGO_HOME": str(cargo_home),
        "CARGO_INCREMENTAL": "0",
        "SOURCE_DATE_EPOCH": "1788307200",
        "RUSTC": str(prefix / "bin/rustc"),
        "RUSTFLAGS": " ".join([
            f"--remap-path-prefix={cargo_home}=/cargo-home",
            f"--remap-path-prefix={ROOT}=/source",
            f"--remap-path-prefix={prefix}=/rust-toolchain",
            "-C linker-flavor=ld.lld",
        ]),
        "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER":
            str(prefix / f"lib/rustlib/{HOST}/bin/rust-lld"),
    })
    subprocess.run([
        str(prefix / "bin/cargo"), "build", "--release", "--locked",
        "--manifest-path", str(ROOT / "sampler/Cargo.toml"),
        "--target", TARGET, "--target-dir", str(args.target_dir.resolve()),
    ], env=env, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
