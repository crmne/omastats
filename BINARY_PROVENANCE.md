# Rust binary provenance

OmaStats retains the complete source for `bin/omastats-sampler` in `sampler/`.
The bundled executable is used on x86-64 because it consumes roughly 3 MB of
resident memory; `sampler.py` remains the readable, cross-architecture fallback.

## What is pinned

- Rust dependencies and their registry checksums are committed in
  `sampler/Cargo.lock`; every build uses `cargo --locked`.
- CI uses an Arch Linux image pinned by OCI digest and the signed Arch Linux
  Archive snapshot dated 2026-09-02.
- CI rejects build hosts that do not provide Rust 1.98.0, GCC 16.2.1, GNU
  binutils 2.47, and glibc 2.44 at the recorded Arch package releases.
- Compiler path remapping gives the source checkout and Cargo cache stable
  virtual paths, so local filesystem locations cannot leak into the ELF.
- `SOURCE_DATE_EPOCH` is fixed at `1788307200` (2026-09-02 00:00:00 UTC), the
  date of the archived build environment.
- Every GitHub Action is referenced by its full commit SHA.

The executable has no update or download mechanism. It runs unprivileged, reads
procfs/sysfs, and invokes only a small allowlist of optional helpers resolved
from `/usr/bin` or `/bin`. Helper processes have deadlines, process-group
termination, and a 1 MiB output limit. File, line, and directory reads are also
bounded.

### Runtime capability map

The Rust executable uses no shell and requests no elevated privileges. Its
runtime inputs are deliberately narrow:

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
2. performs two independent clean, locked release builds;
3. requires both builds to be byte-identical to each other and to the checked-in
   `bin/omastats-sampler`;
4. verifies `bin/omastats-sampler.sha256`; and
5. on `main`, asks GitHub's OIDC-backed Sigstore service to attest both the ELF
   and the generated verification report.

Any source, dependency, toolchain, workflow, checksum, or binary change that
breaks those relationships fails the workflow.

## Verify a checked-out commit

The checksum is the quick local integrity check:

```bash
sha256sum --check --strict bin/omastats-sampler.sha256
```

On the pinned Arch toolchain, this additionally performs two clean builds and
compares every byte:

```bash
make verify-binary
```

After the commit's `Verify bundled Rust binary` run succeeds, verify the signed
attestation against this repository, workflow, and exact source commit:

```bash
gh attestation verify bin/omastats-sampler \
  --repo crmne/omastats \
  --signer-workflow crmne/omastats/.github/workflows/verify-binary.yml \
  --source-digest "$(git rev-parse HEAD)" \
  --deny-self-hosted-runners
```

The uploaded `binary-provenance-<commit>` report records the builder image,
source commit, reproducible-build epoch, Cargo lockfile digest, artifact digest,
exact Arch packages, and full `rustc` identity used for that run.
