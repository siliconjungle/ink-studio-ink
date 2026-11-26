# Ink Studio in Ink Lang

This repository ports Ink Studio's Gaussian splat toolkit to [Ink Lang](https://github.com/siliconjungle/ink-lang). The first renderer takes screen-space or world-space Gaussian covariances and produces the axes, color and opacity for instanced Gaussian quads. It handles perspective and orthographic cameras, clipping and offscreen splats, and gives circular splats a stable orientation. The world path sorts far to near and retains input order at equal depths. The source follows [Ink Studio's WebGPU projection](https://github.com/siliconjungle/shapeshift-labs-ink-studio/blob/66eafbc93224aaef24c7c72a8c38487679af4999/src/webgpu/gaussian-shaders.mjs#L92-L158).

`src/gaussian.ink` builds to native Rust, JavaScript and WGSL. The GPU path produces a packed buffer of ellipses. The native and browser renderers bind that buffer directly and share `shaders/gaussian.wgsl` for rasterization. The caller creates the device and render target. Screen-space inputs use the supplied compositing order. World-space inputs use the supplied camera pose and keep splat data resident across camera changes. A renderer retains a single target size and an input capacity determined by the initial rows.

Both hosts can stage changes to disjoint row ranges and project them on the next camera update or explicit `project` call. The `wide-green` scene uses this path to retain the original field cells as the view moves. `import_builder_splats` reads position, covariance, pigment and opacity from the Studio builder’s sixteen-float rows. Native clients can present an art-resolution texture with `PixelPresenter`, which uses centered nearest-neighbor scaling and supports sRGB surfaces.

A world view can reserve its final splat range for one moving actor. Ink applies the actor's yaw and translation to the centers and rotates their covariances on the GPU. Actor and scene rows share the same stable depth sort. Moving the actor updates its placement without replacing its pose rows. Rust exposes the mode through `WorldOrder::Actor` and `update_actor_camera`, and JavaScript accepts `actor` when creating the renderer and updating its camera.

The skinned path uploads a character's bind splats once. `src/walker.ink` evaluates a biped's gait, lean and nod springs, landing squash, and cloth joints at each simulation tick. `skin_world` blends the joint transforms, applies them to splat centers and covariances, and shades the transformed normals. The GPU projects and compacts terrain and character splats before the shared stable depth sort. Rust exposes this through `WorldOrder::Skinned` and `update_skin_camera`. The browser renderer takes a `skin` option and exposes `updateSkinCamera`. After the first pose update, both hosts keep unchanged leading and trailing joint transforms resident and upload only the span between changed joints. A repeated pose uploads the light alone.

Walkers can add an action pose to the joint palette. The pose controls torso lean and stretch, head nod, and hem flare while retaining the current gait and cloth state. Rebirth uses this for Hex's slash.

`translate_walk` moves the hem and both cloth position buffers by a world offset. The next tick keeps the previous gait phase and velocity when an actor crosses between coordinate spaces.

`src/locomotion.ink` supplies the character controller's grounded, airborne, and low-traction acceleration. Low traction uses separate rates for speeding up, coasting, and reversing direction. Rebirth applies it after downhill acceleration on the Dry Reach. The same module tracks wall contact and kick lock, applies the rebound impulse, and requires an opposite wall or a landing before another kick from the same face.

Callers that already own the correct far-to-near order can use `WorldOrder::Preordered` in Rust or `preordered: true` in JavaScript. The camera update then runs only projection. One Chrome probe at 480 × 270 with 4,096 synthetic splats used 1 compute dispatch per frame with preordered rows, compared with 60 with GPU sorting. Completion p95 was 12.2 ms and 19.4 ms respectively over 30 measured frames after warmup. This measures camera update, draw submission, and GPU completion with resident inputs.

`src/frost.ink` ports the seasonal ice clock, local spell timers, collision threshold, and GPU packing of the ice channel from the shared ecology rules. The packed GPU output preserves the fire, heat and ground-height channels.

## Procedural terrain

`src/noise.ink` implements the builder's seeded value noise and octave blending. `src/terrain.ink` evaluates a bilinear height grid as a signed-distance field, derives the contact elevation for a distance threshold, and samples a world-space staggered lattice across rectangular cell boundaries. Both compile to Rust and JavaScript with the original numeric precision. Rebirth uses these modules to generate ground collision and to supply terrain samples to the original styling and sculpting pass.

## Sculpting and splat marks

`src/sculpt.ink` evaluates rounded boxes, ellipsoids, linear-profile lathes, tapered tube segments, and tori. It applies local frames, seeded surface bumps, smooth unions within each group, and subtractive cuts. Vertical ray queries select nearby shapes once for the ray, with each shape's vertical range used to skip probes outside its bounds. Rebirth uses this path for live field collision.

`src/sampling.ink` generates surface candidates for boxes, ellipsoids, tapered tubes, lathes, and tori. Lathes can use a linear profile measured from either end or a list of authored radii. `src/bake.ink` projects candidates onto the combined field, records the contributing surface or cut, estimates normals and ambient occlusion, and marches shadow rays toward the sun and local lamps. A field cell indexes shape lists once and reuses them across its surface and shadow queries. Decorative shapes can project against their own fields while receiving light and shadows from the scene. Both modules build to Rust and JavaScript.

Rebirth uses this projection and lighting in the visual field export. Its Lupine Steps fixture bakes and renders the same paired arches on both hosts using the portable palette painter with ambient, sky and shadowed sunlight.

`src/edit.ink` turns art-frame coordinates into an orthographic or perspective ray, traces the current sculpt, and adds a spherical cut at the picked surface. The edit history supports undo and redo. Rebaking runs the same projection and shadow pass and returns the updated Gaussian splats. Rebirth's live Lupine Steps view uses this module on both targets.

`src/marks.ink` computes the covariance of round splats, axial discs and sticks, and oriented surface dabs. Rebirth uses the compiled mark geometry during field export, with the original styling pass supplying colors and shading.

The same module reflects a world-space splat across a horizontal water plane, including the signs of the covariance terms. Rebirth uses it to generate water reflections in Rust and JavaScript.

`src/brush.ink` generates seed-driven grass blades, foliage, and feathers. It takes a projected surface, material settings, a pigment ramp, and a random state. It returns the marks and the advanced random state. Rebirth uses these brushes during field export. Studio tests the same strokes, noise, and splat shapes in Rust and JavaScript.

`src/material.ink` turns projected normals, ambient occlusion, and sun and lamp visibility into diffuse paint. It also provides palette ramps, moss placement on upward-facing surfaces, masonry courses, and the final dab. Rebirth uses it with the brush module to paint the two cells affected by the Wide Green bush at run time.

`src/trees.ink` grows the trunk, roots, limbs and twigs from a seed, computes the tapered tube segments, and paints the crown and falling leaves. The crown uses the cell’s clipping bounds, sun and lamp settings, and an authored pigment ramp. `tree_colliders` generates the trunk and roots directly for collision. Rebirth uses the same tree module during field export, live cell baking, and collision generation.

`src/rig_bake.ink` bakes a character's rest sculpt into the renderer's bind splats. It projects the blended and carved forms, then uses each visible surface's joint tags to bind the splat. Tags can blend two joints by height or mark a splat as a blinking eye. The bake preserves palette ramps, ambient occlusion, and seeded shade variation. Power-law lathe profiles support curved forms such as Hex's robe.

Lathe profiles can also ripple as they taper. The same profile drives the signed-distance field and ring sampling, as used by the sculpted figures around Rebirth's Green Flame.

## Build and check

Use [Ink Lang commit `ca47d82`](https://github.com/siliconjungle/ink-lang/commit/ca47d82e898fe28345f6b397f48bc0ec848c4d23) with its pinned submodules. Set `INK` to the absolute path of its built `ink` executable, or put it on `PATH`. The build uses Node.js to request checked Rust borrows for the bake's immutable geometry inputs. The GPU build requires Cargo and the `wasm32-unknown-unknown` Rust target.

```sh
./scripts/build.sh --gpu
node tests/projection.mjs
node tests/sculpt.mjs
node tests/frost.mjs
node tests/locomotion.mjs
node tests/walk-translation.mjs
cargo test --release --locked --manifest-path native/Cargo.toml
python3 -m http.server --bind 127.0.0.1
```

Open `/tests/webgpu.html` on the local server to check browser dispatch, resident camera updates and compositing. Both GPU tests also check rig uploads, bit-exact signed-zero changes, and replacement after other writes. To include native GPU compute in the value comparison, build `build/gpu/native/Cargo.toml` with Cargo and set `INK_WGPU_PROGRAM` to the generated `ink-gpu-program` executable.

Open `/bench/camera.html` on the same server to run the camera probe.

The ongoing port includes additional shape recipes, textured materials, additional rig types, idle gaze, animation clips, the remaining art and streaming features, simulation tools, additional editor tools, and the CLI.
