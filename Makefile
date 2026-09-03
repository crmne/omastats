PLUGIN_ID := crmne.omastats
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)
CARGO_HOME ?= $(HOME)/.cargo
REPRO_RUSTFLAGS := --remap-path-prefix=$(CARGO_HOME)=/cargo-home --remap-path-prefix=$(CURDIR)=/source
SOURCE_DATE_EPOCH := 1788307200

.PHONY: all build verify-binary install clean

all: build

# Build the Rust sampler and place it where sampler.sh looks first.
build:
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml
	install -Dm755 sampler/target/release/omastats-sampler bin/omastats-sampler
	sha256sum bin/omastats-sampler > bin/omastats-sampler.sha256

# Prove that two clean builds are identical to each other and to the bundled ELF.
verify-binary:
	@build_root="$$(mktemp -d)"; \
	trap 'rm -rf -- "$$build_root"' EXIT; \
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml --target-dir "$$build_root/a"; \
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" CARGO_HOME="$(CARGO_HOME)" \
		CARGO_INCREMENTAL=0 RUSTFLAGS="$(REPRO_RUSTFLAGS)" \
		cargo build --release --locked --manifest-path sampler/Cargo.toml --target-dir "$$build_root/b"; \
	cmp "$$build_root/a/release/omastats-sampler" "$$build_root/b/release/omastats-sampler"; \
	cmp "$$build_root/a/release/omastats-sampler" bin/omastats-sampler; \
	sha256sum --check --strict bin/omastats-sampler.sha256

# Copy the plugin into the Omarchy plugin directory and reload the shell.
install:
	mkdir -p "$(PLUGIN_DIR)"
	rsync -a --delete --exclude .git --exclude sampler/target "$(CURDIR)/" "$(PLUGIN_DIR)/"
	omarchy-shell shell rescanPlugins || true

clean:
	cargo clean --manifest-path sampler/Cargo.toml
