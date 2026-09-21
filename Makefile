PLUGIN_ID := crmne.omastats
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)
CARGO_HOME ?= $(HOME)/.cargo
REPRO_RUSTFLAGS := --remap-path-prefix=$(CARGO_HOME)=/cargo-home --remap-path-prefix=$(CURDIR)=/source
SOURCE_DATE_EPOCH := 1788307200
NATIVE_ARCH := $(shell uname -m)
NATIVE_BINARY := bin/omastats-sampler$(if $(filter x86_64,$(NATIVE_ARCH)),,-$(NATIVE_ARCH))
ARM64_TARGET := aarch64-unknown-linux-musl
ARM64_BUILD_DIR := .cache/arm64-build

.PHONY: all build build-arm64 verify-binary verify-arm64 install clean

all: build

# Build the Rust sampler and place it where sampler.py looks first.
build:
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml
	install -Dm755 sampler/target/release/omastats-sampler $(NATIVE_BINARY)
	sha256sum $(NATIVE_BINARY) > $(NATIVE_BINARY).sha256

# Reproduce the portable ARM64 artifact from x86-64 Linux, without root.
build-arm64:
	python3 scripts/build-arm64.py --target-dir "$(ARM64_BUILD_DIR)"
	install -Dm755 "$(ARM64_BUILD_DIR)/$(ARM64_TARGET)/release/omastats-sampler" bin/omastats-sampler-aarch64
	sha256sum bin/omastats-sampler-aarch64 > bin/omastats-sampler-aarch64.sha256

# Prove that two clean builds are identical to each other and to the bundled ELF.
verify-binary:
	@set -eu; build_root="$$(mktemp -d)"; \
	trap 'rm -rf -- "$$build_root"' EXIT; \
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml --target-dir "$$build_root/a"; \
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml --target-dir "$$build_root/b"; \
	cmp "$$build_root/a/release/omastats-sampler" "$$build_root/b/release/omastats-sampler"; \
	cmp "$$build_root/a/release/omastats-sampler" $(NATIVE_BINARY); \
	sha256sum --check --strict $(NATIVE_BINARY).sha256

verify-arm64:
	@set -eu; build_root="$$(mktemp -d)"; \
	trap 'rm -rf -- "$$build_root"' EXIT; \
	python3 scripts/build-arm64.py --target-dir "$$build_root/a"; \
	python3 scripts/build-arm64.py --target-dir "$$build_root/b"; \
	cmp "$$build_root/a/$(ARM64_TARGET)/release/omastats-sampler" "$$build_root/b/$(ARM64_TARGET)/release/omastats-sampler"; \
	cmp "$$build_root/a/$(ARM64_TARGET)/release/omastats-sampler" bin/omastats-sampler-aarch64; \
	sha256sum --check --strict bin/omastats-sampler-aarch64.sha256

# Copy the plugin into the Omarchy plugin directory and reload the shell.
install:
	mkdir -p "$(PLUGIN_DIR)"
	rsync -a --delete --exclude .git --exclude .cache --exclude sampler/target "$(CURDIR)/" "$(PLUGIN_DIR)/"
	omarchy-shell shell rescanPlugins || true

clean:
	cargo clean --manifest-path sampler/Cargo.toml
