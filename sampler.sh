#!/bin/bash
# Launches the fastest sampler available: the compiled Rust binary when it
# runs on this machine, otherwise the zero-dependency Python one. Both speak
# the same JSON-lines protocol, so the shell never knows which one ran.
script=${BASH_SOURCE[0]}
case "$script" in
  */*) dir=${script%/*} ;;
  *) dir=. ;;
esac
dir=$(cd -- "$dir" && pwd -P) || exit 1
for candidate in "$dir/bin/omastats-sampler" "$dir/sampler/target/release/omastats-sampler"; do
  # --version also proves the binary is for this architecture and links here.
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    exec "$candidate" "$@"
  fi
done
for interpreter in /usr/bin/python3 /bin/python3; do
  if [ -x "$interpreter" ]; then
    exec "$interpreter" "$dir/sampler.py" "$@"
  fi
done
printf 'OmaStats requires Python 3 when the Rust sampler cannot run.\n' >&2
exit 127
