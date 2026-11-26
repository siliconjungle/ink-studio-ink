# Ink Studio in Ink Lang

This repository ports Ink Studio's Gaussian splat toolkit to [Ink Lang](https://github.com/siliconjungle/ink-lang). The first implemented stage takes screen-space Gaussian covariances and produces the axes, color and opacity for instanced Gaussian quads. It handles offscreen and invalid splats and gives circular splats a stable orientation. The source follows the ellipse path in [Ink Studio's WebGPU projection](https://github.com/siliconjungle/shapeshift-labs-ink-studio/blob/66eafbc93224aaef24c7c72a8c38487679af4999/src/webgpu/gaussian-shaders.mjs#L134-L158).

`src/gaussian.ink` builds to native Rust, JavaScript and WGSL. The GPU path produces a packed buffer of ellipses. The native and browser renderers bind that buffer directly and share `shaders/gaussian.wgsl` for rasterization. The caller supplies splats in compositing order and creates the device and render target. A renderer retains a single target size and an input capacity determined by the initial rows.

## Build and check

The compiler is Ink Lang commit `758fd41b3ecd2415b9434b5dde03533c615190de` with its pinned submodules. Set `INK` to the absolute path of its built `ink` executable, or put it on `PATH`. The GPU build requires Cargo and the `wasm32-unknown-unknown` Rust target.

```sh
./scripts/build.sh --gpu
node tests/projection.mjs
cargo test --release --locked --manifest-path native/Cargo.toml
python3 -m http.server --bind 127.0.0.1
```

Open `/tests/webgpu.html` on the local server to check browser dispatch, resident updates and pixels. The native test checks the same two draws with a wgpu device. To include native GPU compute in the value comparison, build `build/gpu/native/Cargo.toml` with Cargo and set `INK_WGPU_PROGRAM` to the generated `ink-gpu-program` executable.

Current scope is the screen-space projection and basic rasterization stage. Ink Studio's world-space projection, depth sorting, art passes, SDF baking, rigs, simulation, editors, and CLI are separate parts of the ongoing port. This fixture exercises hardware execution and buffer residency. Full-scene performance still needs measurement.
