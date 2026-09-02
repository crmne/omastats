#!/bin/bash
# Launches the fastest sampler available: the compiled Rust binary when it
# runs on this machine, otherwise the zero-dependency Python one. Both speak
# the same JSON-lines protocol, so the shell never knows which one ran.
dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
for candidate in "$dir/bin/omastats-sampler" "$dir/sampler/target/release/omastats-sampler"; do
  # --version also proves the binary is for this architecture and links here.
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    exec "$candidate" "$@"
  fi
done
exec python3 "$dir/sampler.py" "$@"
