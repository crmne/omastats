# Packaging

[`native-packages.yaml`](native-packages.yaml) is the packaging configuration:
it pins the shared CLI and nFPM versions and declares Linux amd64/arm64 inputs,
DEB/RPM contents, dependencies, recipe templates and downstream repositories.
Application assets and native recipes stay in `packaging/`.

```sh
gem install native-packages --version 0.5.1
native-packages validate
native-packages doctor
native-packages build --release v1.2.3
```

Replace `v1.2.3` with an existing stable application release. Local use also
requires nFPM 2.47.0, `bsdtar` and `readelf`; AUR generation needs `makepkg`
or Docker. CI installs its tooling. To package local release archives, put
every configured input and recipe asset under `dist/`, then run
`native-packages build --version 1.2.3`. Outputs go to
`dist/packages/1.2.3`; use `--output` for a fresh destination when rebuilding.

Stable tags run the existing native build jobs first. After binaries and
`checksums.txt` are published, the shared workflow verifies their hashes,
builds the configured packages, and attaches them to the GitHub release.
Configured recipes are attached as an archive. Package checksums are separate
from the original binary checksums. PR validation never publishes.

Review or publish an existing build with the same installed CLI:

```sh
native-packages publish --from dist/packages/1.2.3 --to github
native-packages repositories
native-packages status --offline
```

For applications with configured AUR or Homebrew destinations, stage the
recipes with `native-packages stage TARGET dist/packages/1.2.3/recipes`,
inspect `native-packages diff TARGET`, run native package validation, and
publish with `native-packages publish TARGET`. These destinations use ignored
managed Git clones, recorded in this application's YAML configuration.
AUR automation needs `PUBLISH_AUR=true`, `AUR_SSH_KEY` and `AUR_KNOWN_HOSTS`;
Homebrew automation needs `PUBLISH_HOMEBREW=true` and
`HOMEBREW_TAP_GITHUB_TOKEN`. Enable only configured destinations.

The existing macOS, Windows and Flatpak build/signing steps remain responsible
for their native artifacts. Additional nFPM formats require suitable platform
inputs and dependencies; adding a format does not port the application.
See the [shared CLI documentation](https://github.com/crmne/native-packages/tree/v0.5.1)
for commands and supported formats.

To upgrade the tool, change `tool.version` in `native-packages.yaml`, the
matching immutable workflow reference, and any release-job gem installation
pin together. Applications need no packaging Gemfile, lockfile or Ruby wrapper.

This packages the native `omastats-sampler` executable. The full desktop plugin
installation and fallback sampler retain their existing installation paths.

## Releasing OmaStats

Keep `manifest.json`, `sampler/Cargo.toml`, and the sampler entry in
`sampler/Cargo.lock` at the same version. Rebuild and verify both bundled
executables using `make build`, `make verify-binary` on the pinned x86-64
Arch toolchain, and `make build-arm64`, `make verify-arm64`. Add release notes
under `.github/release-notes/v<VERSION>.md` and run
`python3 scripts/check-release.py v<VERSION>`.

After the release commit is on `main` and CI passes, push a stable `vX.Y.Z`
tag. The Release workflow verifies the tag and all version files, runs the
reproducible-binary and ARM64 runtime checks, builds native sampler archives,
and publishes a complete plugin archive plus checksums and release notes.
The packaging workflow then adds the amd64/arm64 DEB and RPM packages.
A manual Release dispatch can retry an existing tag without replacing
published binary archives.

The complete plugin archive contains the verified bundled executables.
Standalone GNU/Linux sampler archives are built on Ubuntu 24.04 for packaging
with glibc 2.39 compatibility; their checksums are published separately from
the bundled binaries' provenance.
