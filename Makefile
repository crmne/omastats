PLUGIN_ID := crmne.omastats
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)

.PHONY: all build install install-link clean

all: build

# Build the Rust sampler and place it where sampler.sh looks first.
build:
	cargo build --release --manifest-path sampler/Cargo.toml
	mkdir -p bin
	cp sampler/target/release/omastats-sampler bin/omastats-sampler

# Copy the plugin into the Omarchy plugin directory and reload the shell.
install:
	mkdir -p "$(PLUGIN_DIR)"
	rsync -a --delete --exclude .git --exclude sampler/target "$(CURDIR)/" "$(PLUGIN_DIR)/"
	omarchy-shell shell rescanPlugins || true

clean:
	cargo clean --manifest-path sampler/Cargo.toml
	rm -rf bin
