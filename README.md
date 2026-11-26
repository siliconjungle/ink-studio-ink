# Ink Studio in Ink Lang

This repository ports Ink Studio's Gaussian splat toolkit to [Ink Lang](https://github.com/siliconjungle/ink-lang). The first renderer takes screen-space or world-space Gaussian covariances and produces the axes, color and opacity for instanced Gaussian quads. It handles perspective and orthographic cameras, clipping and offscreen splats, and gives circular splats a stable orientation. The world path sorts far to near and retains input order at equal depths. The source follows [Ink Studio's WebGPU projection](https://github.com/siliconjungle/shapeshift-labs-ink-studio/blob/66eafbc93224aaef24c7c72a8c38487679af4999/src/webgpu/gaussian-shaders.mjs#L92-L158).

`src/gaussian.ink` builds to native Rust, JavaScript and WGSL. The GPU path produces a packed buffer of ellipses. The native and browser renderers bind that buffer directly and share `shaders/gaussian.wgsl` for rasterization. The caller creates the device and render target. Screen-space inputs use the supplied compositing order. World-space inputs use the supplied camera pose and keep splat data resident across camera changes. A renderer retains a single target size and an input capacity determined by the initial rows.

Callers that already own the correct far-to-near order can use `WorldOrder::Preordered` in Rust or `preordered: true` in JavaScript. The camera update then runs only projection. One Chrome probe at 480 × 270 with 4,096 synthetic splats used 1 compute dispatch per frame with preordered rows, compared with 60 with GPU sorting. Completion p95 was 12.2 ms and 19.4 ms respectively over 30 measured frames after warmup. This measures camera update, draw submission, and GPU completion with resident inputs.

`src/frost.ink` ports the seasonal ice clock, local spell timers, collision threshold, and GPU packing of the ice channel from the shared ecology rules. The packed GPU output preserves the fire, heat and ground-height channels.

## Build and check

The compiler is Ink Lang commit `758fd41b3ecd2415b9434b5dde03533c615190de` with its pinned submodules. Set `INK` to the absolute path of its built `ink` executable, or put it on `PATH`. The GPU build requires Cargo and the `wasm32-unknown-unknown` Rust target.

```sh
./scripts/build.sh --gpu
node tests/projection.mjs
node tests/frost.mjs
cargo test --release --locked --manifest-path native/Cargo.toml
python3 -m http.server --bind 127.0.0.1
```

Open `/tests/webgpu.html` on the local server to check browser dispatch, resident camera updates and compositing. The native test checks the same two draws with a wgpu device. To include native GPU compute in the value comparison, build `build/gpu/native/Cargo.toml` with Cargo and set `INK_WGPU_PROGRAM` to the generated `ink-gpu-program` executable.

Open `/bench/camera.html` on the same server to run the camera probe.

Current scope is Gaussian projection, depth sorting, and basic rasterization. Ink Studio's styled footprints, art passes, streaming, SDF baking, rigs, simulation, editors, and CLI remain part of the ongoing port. The fixtures exercise hardware execution and buffer residency. Full-scene performance still needs measurement.
