#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ink=${INK:-ink}
mkdir -p build
"$ink" build src/gaussian.ink --target javascript -o build/gaussian.mjs
"$ink" build src/gaussian.ink --target rust -o build/rust
"$ink" build src/frost.ink --target javascript -o build/frost.mjs
"$ink" build src/frost.ink --target rust -o build/frost-rust
if [ "${1:-}" = "--gpu" ]; then
    "$ink" build src/gaussian.ink --target webgpu -o build/gpu
    "$ink" build src/frost.ink --target webgpu -o build/frost-gpu
fi
