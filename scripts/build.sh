#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ink=${INK:-ink}
mkdir -p build
"$ink" build src/gaussian.ink --target javascript -o build/gaussian.mjs
"$ink" build src/gaussian.ink --target rust -o build/rust
"$ink" build src/walker.ink --target javascript -o build/walker.mjs
"$ink" build src/walker.ink --target rust -o build/walker-rust
for module in noise terrain sculpt marks sampling bake edit brush material trees rig_bake locomotion rail texture_address textured_surface; do
    "$ink" build "src/$module.ink" --target javascript -o "build/$module.mjs"
    case "$module" in
        bake|rig_bake|texture_address|textured_surface) node scripts/build-native-bake.mjs "$ink" "src/$module.ink" "build/$module-rust" ;;
        *) "$ink" build "src/$module.ink" --target rust -o "build/$module-rust" ;;
    esac
done
"$ink" build src/frost.ink --target javascript -o build/frost.mjs
"$ink" build src/frost.ink --target rust -o build/frost-rust
if [ "${1:-}" = "--gpu" ]; then
    "$ink" build-render src/contour_render.ink frame --shader shaders/gaussian-contours.wgsl -o build/contour-render
    "$ink" build src/gaussian.ink --target webgpu -o build/gpu
    "$ink" build src/frost.ink --target webgpu -o build/frost-gpu
fi
