# Ink Studio in Ink Lang

This repository ports Ink Studio's Gaussian splat toolkit to [Ink Lang](https://github.com/siliconjungle/ink-lang). The first renderer takes screen-space or world-space Gaussian covariances and produces the axes, color and opacity for instanced Gaussian quads. It handles perspective and orthographic cameras, clipping and offscreen splats, and gives circular splats a stable orientation. The world path sorts far to near and retains input order at equal depths. The source follows [Ink Studio's WebGPU projection](https://github.com/siliconjungle/shapeshift-labs-ink-studio/blob/66eafbc93224aaef24c7c72a8c38487679af4999/src/webgpu/gaussian-shaders.mjs#L92-L158).

`src/gaussian.ink` builds to native Rust, JavaScript and WGSL. The GPU path produces a packed buffer of ellipses. The native and browser renderers bind that buffer directly and share `shaders/gaussian.wgsl` for rasterization. WebGPU and native wgpu on Metal, Vulkan, and Direct3D 12 use the packed row count to draw only projected splats, with the draw count staying on the GPU. The caller creates the device and render target. Screen-space inputs use the supplied compositing order. World-space inputs use the supplied camera pose and keep splat data resident across camera changes. A renderer retains a single target size and an input capacity determined by the initial rows.

Colored Contours is available for sorted world and skinned views. One Ink projection and depth sort supplies the native grid and a double-resolution grid. The native grid snaps splats to pixel centers. Solid coverage on the finer grid determines the silhouette, and the shared WGSL resolve applies the palette and ordered dither. Use Rust's `with_contours` or the browser renderer's `contours` option. Each palette uses packed `0xRRGGBB` colors and begins with its background. Rust's `set_contour_grade` and JavaScript's `setContourGrade` update the displayed colors of resident geometry.

`src/contour_render.ink` declares both raster grids and the resolve pass for wgpu and WebGPU. The GPU build compiles the pass sequence with the shared WGSL. Both renderers bind the resident projection buffer and reuse one GPU-side count for the two grid draws.

Use `with_directional_contours` in Rust or `directional: true` in the browser contour options to pass ambient and directional light to the same renderer. Ink projects the visible splats, estimates normals from their covariance, and keeps each base pigment for the contour palette vote. Stage a light with `stage_contour_lighting` or `stageContourLighting` before the next projection. The existing color and depth passes carry the light to the image without restaging geometry.

Both hosts can stage changes to disjoint row ranges and project them on the next camera update or explicit `project` call. The `wide-green` scene uses this path to retain the original field cells as the view moves. `import_builder_splats` reads position, covariance, pigment and opacity from the Studio builder’s sixteen-float rows. Native clients can present an art-resolution texture with `PixelPresenter`, which uses centered nearest-neighbor scaling and supports sRGB surfaces.

Rust callers can stage packed world splat ranges and use typed camera, bone, rig light, and contour light updates. Studio checks the ordered field layout against the compiled GPU session before its first packed write. Rebirth uses these methods for live frame updates.

A world view can reserve its final splat range for one moving actor. Ink applies the actor's yaw and translation to the centers and rotates their covariances on the GPU. Actor and scene rows share the same stable depth sort. Moving the actor updates its placement without replacing its pose rows. Rust exposes the mode through `WorldOrder::Actor` and `update_actor_camera`, and JavaScript accepts `actor` when creating the renderer and updating its camera.

The skinned path uploads a character's bind splats once. `src/walker.ink` evaluates a biped's gait, lean and nod springs, landing squash, and cloth joints at each simulation tick. It also provides seeded gaze and blink timing for character rigs. `skin_world` blends the joint transforms, applies them to splat centers and covariances, and shades the transformed normals. The GPU projects and compacts terrain and character splats before the shared stable depth sort. Rust exposes this through `WorldOrder::Skinned` and `update_skin_camera`. The browser renderer takes a `skin` option and exposes `updateSkinCamera`. After the first pose update, both hosts keep unchanged leading and trailing joint transforms resident and upload only the span between changed joints. A repeated pose uploads the light alone.

Walkers can add an action pose to the joint palette. The pose controls torso lean and stretch, head nod, and hem flare while retaining the current gait and cloth state. Rebirth uses this for Hex's slash.

`translate_walk` moves the hem and both cloth position buffers by a world offset. The next tick keeps the previous gait phase and velocity when an actor crosses between coordinate spaces.

`src/locomotion.ink` supplies the character controller's grounded, airborne, and low-traction acceleration. Low traction uses separate rates for speeding up, coasting, and reversing direction. Rebirth applies it after downhill acceleration on the Dry Reach. The same module tracks wall contact and kick lock, applies the rebound impulse, and requires an opposite wall or a landing before another kick from the same face. It checks support and headroom before applying the step-up and timed climb rules.

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

Lathe profiles can ripple as they taper, including the phase-shifted power profile used for the stalagmites in Rebirth's Drake cave. The same profile drives the signed-distance field and ring sampling.

`src/rail.ink` samples Catmull–Rom splines and measures authored 3D polylines by arc length. Its nearest-point query preserves the first segment on equal-distance hits and handles repeated points. Rebirth uses the same Ink implementation on both targets for rail boarding, steering, and handoffs in the Crypt’s Works wing.

`src/textured_surface.ink` generates indexed triangle grids with normalized texture coordinates. Heightfields query the triangles used by the mesh, and attachments use the same split to recover position and surface normal. A profile sweep accepts authored frames or samples an Ink rail by distance. Closed sweeps join at the first frame while preserving both ends of the UV range. These functions build to native Rust and JavaScript.

`src/texture_address.ink` packs UV address fields with optional coverage. It samples RGBA texels using nearest or linear filtering and independently clamps, mirrors, wraps, or clears each axis. `surface_material_at` uses the same coordinates to return a surface attachment and the sampled color.

## Pixel documents

`src/pixel_document.ink` opens version 1 and version 2 pixel documents. It checks the grid, palette, layer stack, frame timing, cel IDs and hold links. Version 1 drawings migrate to a single square-pixel `artwork` frame with their original drawing data and metadata. Both hosts return the normalized document and SHA-256 revisions for the document and its legacy source when present.

Call `openPixelDocument(source)` from `web/pixel-document.mjs` in a secure browser context after building. The native loader is also available as a command.

```sh
cargo run --release --locked --manifest-path native/pixel/Cargo.toml -- artwork.json
```

Use `openPixelPng(bytes)` from `web/pixel-document.mjs` to import a `Uint8Array` as an editable version 2 document. It returns the document and its SHA-256 revision in the same format as `openPixelDocument`. The importer accepts noninterlaced and Adam7 PNGs up to 512 × 512 with 8-bit or smaller channels. Editable PNGs retain swatch IDs, labels, locks, ramps, alpha and knockout marks.

```sh
cargo run --release --locked --manifest-path native/pixel/Cargo.toml -- import-png artwork.png
```

`rasterizePixelFrame(source, { frame, layer, cel })` compiles artwork into indexed slots, alpha, clipping and packed RGBA. Omit `layer` and `cel` for the frame composite. The same Ink code runs on both targets and handles held cels, content offsets, layer groups, blend modes, clipping masks, and authored point, run, stair, rectangle, path and polygon marks. The compiler needs `f64_from_decimal` to read authored numbers.

Both loaders pass full cel slot arrays to Ink as palette indices. A held cel can share its source's slot plane. Snapshots and document exports restore the original swatch IDs, transparent slots and authored field order, including on 512 × 512 cels.

Retained editors decode valid run-only cels into typed spans when opening a document. Raster queries and held cels reuse those spans, and snapshots still export the authored marks.

`selectPixelFrame(source, query, scope)` runs selection on the resolved raster and returns the frame, grid and selected coordinates. Use `createPixelEditor(source)` for repeated selections. Its `select(query, scope)` method reuses the last raster for the same resolved frame and layer, including when the scope is given as a cel. `replaceDocument(source)` validates and installs a fresh snapshot, then clears the cached raster. Rust provides the same lifecycle through `PixelEditor::new`, `select` and `replace_document`.

Use `{ type: 'recall', id }` to resolve a document's saved selection. An unscoped top-level recall selects its saved frame. Recalls within a composed query use the active frame.

`editor.saveSelection({ id, query, layer, cel }, { frame })` saves a raster query as a named mask, replacing a mask with the same ID in place. The report includes the frame and native pixel runs. The mask is immediately available to selection queries, paint and brush capture. Native callers use `PixelEditor::save_selection` or the `save-selection-document` command with a request containing `document`, `operation`, and optional `frame`.

`editor.paint(operation, { frame, cel })` applies pencil, eraser, fill, shape and saved brush operations to the open document and returns the changed runs. Pass the layer in the operation or select a cel in the scope. Operations support the original named selection constraints, pixel-perfect pencil paths, mirror axes and wrapping. `editor.snapshot()` materializes the edited pixel document from retained Ink state and preserves author order in saved masks. The native library supports `PixelEditor::paint` and `snapshot`. Its `paint-document` command takes `document`, `operation`, and optional `frame` and `cel`, and returns the target report and updated document.

Set `tool: 'replace-swatch'` with a saved `selection` and distinct `from` and `to` swatch IDs. Use `tool: 'rgba'` with a list of `{ at: [x, y], rgba: [r, g, b, a], swatch }` pixels for exact color edits. The swatch ID is optional. An RGBA byte tuple with zero alpha retains its pigment. Use `rgba: null` to clear the index at a pixel.

Use `{ tool: 'transform', layer, selection, mode, transform, resultSelection }` to move or copy a named selection. `mode` defaults to `'move'`. Transform settings support an absolute position or offset, size, rotation, and flips. Set `carryProtection: true` when moving whole frame-specific protected details. Use `editor.copySelection({ selection, layer, frame })` or pass a cel instead of a layer to get an indexed clipboard, then pass it to `{ tool: 'paste', layer, clipboard, transform, resultSelection }`. Clipboard slots retain swatch identities, opacity, and knockouts. Rust provides `PixelEditor::copy_selection` and the `copy-selection-document` command with `document` and `options` fields. Pass the copied value directly to `PixelEditor::paste_clipboard` with typed `PasteOptions`.

Set `tool: 'shape'` and pass `shape: { type, ...geometry }` for lines, quadratic or cubic curves, rectangles, ellipses, polygons, bitmap text and staircases. Filled shapes and outline widths follow the native pixel grid. Text supports individual scale, tracking, leading, alignment and column wrapping. Shapes honor the same named selections, protection, clipping, mirror axes and wrapping as other raster tools.

`editor.captureBrush({ rect, pixels, selection, frame, layer, cel, anchor, settings })` saves an indexed tip. Supply one rectangle, one pixel list, or one named selection. Omit the layer and cel to capture the frame composite. Paint with `{ tool: 'brush', layer, brush, at }`, a `points` path, or timed `samples` with pressure. Brush operations support the original palette matching and additions, tint, color override, alpha changes, recolor and inline or named palette ramps. Native callers use `PixelEditor::capture_brush` or `capture-brush-document` with a JSON request containing `document` and `options`.

Use `createPixelCommandEditor(source, { historyLimit })` for revision-checked, in-memory edit history. The browser API returns promises. `revision()` gives the document SHA-256 for an edit envelope with an `id`, `frame` or `cel`, and a raster `operation`. Add `destination: 'selections'` to save a named mask. `previewPatch(patch)` returns the prospective document and receipt without changing the draft. `apply(patch)` applies the edit, and `receipts()` returns version 1 SDK receipts for the current history branch. `replay(receipt)` validates the input revision and verifies the recorded targets and output before accepting the edit.

`begin(label)` opens a group. `preview()` returns its draft document. `commit()` makes the group one undo step, and `cancel()` restores the initial revision and receipts. A rejected apply cancels its open group. `undo()` and `redo()` restore the artwork, selection masks, revision and receipts together. The journal covers retained raster edits and named raster masks.

`previewEdit(patch, { limit, exact })` compares one proposed local raster or selection edit with the current artwork. `previewChanges({ limit, exact })` compares the active draft with the artwork at `begin()`. The default limit includes the first 256 changed composite pixels in frame and row order, while `pixelCount` covers the entire change. Set `exact: true` to include all composited and raw layer changes and protection evidence. Both previews leave the draft and receipt history intact.

Rust exposes the same journal through `PixelCommandEditor`, with `PixelPreviewOptions` for both diff methods. Its `journal-document` command accepts `{ document, historyLimit, steps }` and writes one JSON reply per step. Each step has an `op` such as `begin`, `apply`, `preview-patch`, `preview-edit`, `preview-changes`, `commit`, `undo`, or `replay`. Pass `label`, `patch`, or `receipt` on the corresponding step and `options` for either diff.

Use `editor.execute(command)` with an `{ format: 'ink-studio/pixel-command', version: 1, action, … }` envelope. The shared Ink dispatcher handles local `draw`, `mask`, `recolor`, and `transform` aliases, guarded raster and selection operations, `validate`, `select`, `inspect`, `preview`, `replay`, and journal travel. Export the authored document, an indexed `stamp`, a `layer-deck`, or a `png`. Stamp and layer-deck exports include held-cel rasters, opacity, knockouts and the applicable palette and frame metadata.

The `png` command returns base64 with `frame`, `cel`, `layer`, and `colorMode` options. Choose `auto` to use indexed PNG when the samples fit in 256 entries, `indexed` to require indexed PNG, or `rgba` for straight RGBA. PNGs retain editable palette order, aliases, names, locks, ramps, and knockout locations in the `inKD` chunk. For the PNG bytes directly, use `await editor.png(options)` in JavaScript or `PixelCommandEditor::png` with a JSON options string in Rust.

Run `inspect` with `at: [x, y]` to read the document revision, the visible layer and swatch, and the local layer composition. Its options accept a frame or cel and can include reference layers. Pass the observed revision and an `edits` array of `{ at, layer, from, to }` points in a `draw` patch to apply guarded replacements. `layer` and `from` are the observed layer and swatch, including `null` when absent. Set `to` to a swatch ID or `null` for a knockout. A patch with a cel edits that cel. Otherwise its ID names a new layer on the selected frame.

Rust callers can pass a command JSON string to `PixelCommandEditor::execute` and receive the serialized reply. For an existing native journal sequence, pass `{ "op": "execute", "command": … }` in its steps. For a single command, `command-document` reads a request file with `{ "document": …, "command": … }` and prints the original reply shape. An invalid envelope exits with status 1. A rejected edit with a receipt or an invalid preview prints its JSON and exits with status 2.

`raster` and `select-document` are the native equivalents. Their JSON request contains `document` and optional `frame`, `layer` or `cel`. Add `query` for `select-document`.

`selectPixels(width, height, query, { rgba, saved, indexed })` in the same browser module returns selected `[x, y]` coordinates in native row order. The shared Ink implementation covers rectangular and elliptical marquees, lassos and polygons, literal and saved masks, mask combinations and modifiers, wand fills, swatches, and clusters. Wand fills take one packed `0xRRGGBBAA` word per pixel. Saved masks map selection IDs to coordinate lists.

Supply an already rasterized composite, layer, or cel as `indexed` for swatch selections and clusters with no explicit source. Pass row-major `slots` with negative values for unpainted pixels and an `ids` array in palette order. The optional `alpha` and `clipping` planes exclude pixels whose corresponding value is zero. The browser accepts the original raster's `Int16Array` slots and `Uint8Array` alpha and clipping directly.

For tools that work with whole masks, `selectPixelMask(width, height, query, options)` keeps the result packed. Pixel `y * width + x` uses the corresponding bit, starting with the least significant bit of each 32-bit word. Set `large: true` for a material canvas of up to 8,192 pixels per axis and 16,777,216 total pixels. Literal and saved coordinate lists travel as runs, including full-canvas masks.

The native `select` and `select-mask` commands read a JSON request with `width`, `height`, and `query`, plus optional `rgba`, `saved`, `large`, and `indexed`. `select` returns coordinates. `select-mask` returns the packed words. Rust callers can pass the raster as typed vectors through `select_pixel_mask_with_raster`.

```sh
cargo run --release --locked --manifest-path native/pixel/Cargo.toml -- select selection.json
cargo run --release --locked --manifest-path native/pixel/Cargo.toml -- select-mask selection.json
```

## Build and check

Use [Ink Lang commit `56fb433`](https://github.com/siliconjungle/ink-lang/commit/56fb433bb1b68b25d592056572598946b6e38f4f) with its pinned submodules. Set `INK` to the absolute path of its built `ink` executable, or put it on `PATH`. The build asks Ink to select checked Rust borrows for immutable geometry and pixel document inputs. The GPU build requires Cargo and the `wasm32-unknown-unknown` Rust target.

```sh
./scripts/build.sh --gpu
node tests/projection.mjs
node tests/sculpt.mjs
node tests/frost.mjs
node tests/locomotion.mjs
node tests/rail.mjs
node tests/textured-surface.mjs
node tests/texture-address.mjs
node tests/walk-translation.mjs
node tests/native-bake.mjs
cargo test --release --locked --manifest-path native/Cargo.toml
python3 -m http.server --bind 127.0.0.1
```

Open `/tests/webgpu.html` on the local server to check browser dispatch, resident camera updates and compositing. Both GPU tests also check rig uploads, bit-exact signed-zero changes, and replacement after other writes. To include native GPU compute in the value comparison, build `build/gpu/native/Cargo.toml` with Cargo and set `INK_WGPU_PROGRAM` to the generated `ink-gpu-program` executable.

Open `/bench/camera.html` on the same server to run the camera probe. For sorted resident worlds, `updateCameraAndDraw` in the browser and `update_packed_camera_and_draw` in wgpu encode projection and drawing in one submission.

The ongoing port includes additional shape recipes, textured materials, additional rig types, animation clips, the remaining art and streaming features, simulation tools, additional editor tools, and the CLI.
