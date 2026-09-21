# Rust binary provenance

OmaStats retains the complete source for both bundled executables in `sampler/`:
`bin/omastats-sampler` for x86-64 Linux and `bin/omastats-sampler-aarch64` for
ARM64 Linux. The launcher selects the matching architecture before executing
it, even on machines with foreign-architecture emulation enabled.
`sampler.py` remains the readable fallback for other architectures or a missing
or incompatible binary.

## What is pinned

- Rust dependencies and their registry checksums are committed in
  `sampler/Cargo.lock`; every build uses `cargo --locked`.
- The x86-64 build uses an Arch Linux image pinned by OCI digest and the signed Arch Linux
  Archive snapshot dated 2026-09-02.
- For x86-64, CI rejects build hosts that do not provide Rust 1.98.0, GCC 16.2.1, GNU
  binutils 2.47, and glibc 2.44 at the recorded Arch package releases.
- Compiler path remapping gives the source checkout and Cargo cache stable
  virtual paths, so local filesystem locations cannot leak into the ELF.
- `SOURCE_DATE_EPOCH` is fixed at `1788307200` (2026-09-02 00:00:00 UTC), the
  date of the archived build environment.
- Every GitHub Action is referenced by its full commit SHA.

The ARM64 build uses the `aarch64-unknown-linux-musl` target and statically
links libc. [`scripts/build-arm64.py`](scripts/build-arm64.py) pins SHA-256
checksums for the official Rust 1.98.0 compiler, Cargo, host standard library,
and ARM64 standard library archives. The compiler's bundled LLD performs the
target link; no system cross-compiler or ARM sysroot is needed. The script
downloads and installs these tools only into `.cache/arm64-toolchain`, uses the
same locked dependencies and epoch, and remaps toolchain paths as well as the
source and Cargo cache. CI also runs this cross-build in the pinned Arch image.

The executable has no update or download mechanism. It runs unprivileged, reads
procfs/sysfs, and invokes only a small allowlist of optional helpers resolved
from `/usr/bin` or `/bin`. Helper processes have deadlines, process-group
termination, and a 1 MiB output limit. File, line, and directory reads are also
bounded. Each serialized sampler record is capped at 512 KiB before it is
written to the shell's streaming parser.

### Runtime capability map

The plugin's runtime launch path uses no shell and requests no elevated
privileges. Quickshell invokes `/usr/bin/python3` by absolute path in isolated
mode with a cleared environment; that entry point replaces itself with the Rust
executable by absolute path when compatible. Its runtime inputs are deliberately
narrow:

- read-only system telemetry from `/proc` and `/sys`;
- `nvidia-smi` for NVIDIA telemetry and `lspci` for a human-readable GPU name;
- `ip` for interface addresses, `iw` for Wi-Fi details, and `ss` for TCP socket
  counters; and
- `curl` to one of the three fixed IP-only HTTPS endpoints documented in the
  README, solely when public-IP display is enabled.

Each helper is passed a fixed argument structure without shell evaluation.
Missing helpers simply make the corresponding optional field unavailable.

## What CI proves

[`.github/workflows/verify-binary.yml`](.github/workflows/verify-binary.yml) runs
for every commit pushed to `main`, for pull requests, and on manual dispatch. It:

1. tests and lints the retained Rust source and parses the Python fallback;
2. performs two independent clean, locked release builds for each architecture;
3. requires both builds to be byte-identical to each other and to the matching
   checked-in executable;
4. verifies both `.sha256` files;
5. runs the ARM64 binary and launcher on a native ARM64 runner, checking the
   JSON stream, process replacement, and stdin shutdown protocol; and
6. on `main`, asks GitHub's OIDC-backed Sigstore service to attest both ELFs
   and the generated verification report.

Any source, dependency, toolchain, workflow, checksum, or binary change that
breaks those relationships fails the workflow.

## Verify a checked-out commit

The checksum is the quick local integrity check:

```bash
sha256sum --check --strict bin/omastats-sampler.sha256
sha256sum --check --strict bin/omastats-sampler-aarch64.sha256
```

On the pinned Arch toolchain, this additionally performs two clean builds and
compares every byte:

```bash
make verify-binary
```

On x86-64 Linux with Python 3.12+, a C linker and tar, build or verify the
portable ARM64 artifact without changing the system toolchain:

```bash
make build-arm64
make verify-arm64
```

`make build` on an ARM64 machine instead produces a locally linked native
binary; use the pinned cross-build to regenerate the distributed static ELF.

After the commit's `Verify bundled Rust binary` run succeeds, verify the signed
attestation against this repository, workflow, and exact source commit:

```bash
gh attestation verify bin/omastats-sampler \
  --repo crmne/omastats \
  --signer-workflow crmne/omastats/.github/workflows/verify-binary.yml \
  --source-digest "$(git rev-parse HEAD)" \
  --deny-self-hosted-runners
```

Use `bin/omastats-sampler-aarch64` in the same command to verify the ARM64
attestation.

The uploaded `binary-provenance-<commit>` report records the builder image,
source commit, reproducible-build epoch, Cargo lockfile digest, artifact digest,
exact Arch packages, and full `rustc` identity used for that run.
