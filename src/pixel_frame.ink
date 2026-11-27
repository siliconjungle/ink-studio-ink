module StudioPixelFrame;

import "std:json" as json;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;
import "pixel_raster.ink" as paint;
import "pixel_selection.ink" as selection;

record Location { id: String, frame: String, layer: String, }
record Cel { id: String, layer: String, frame: String, fields: List<json.Member>, }
record Placement { x: i32, y: i32, opacity: f64, }
record Layer { id: String, kind: String, parent: String, clip: String, blend: String, protect: Bool,
    locked: Bool, visible: Bool, opacity: f64, }
record Artwork { grid: mask.Grid, layers: List<Layer>, ids: List<String>, colors: List<u32>,
    cels: List<Cel>, locations: List<Location>, frames: List<String>, inputs: List<json.Json>, }
record Scope { frame: String, layer: String, }
record Captured { found: Bool, slots: List<i32>, alpha: List<u32>, clipping: List<u32>, }
record Pixel { slot: i32, color: u32, alpha: u32, locked: Bool, }
record Source { raw: paint.Raw, group: List<Pixel>, }
record Canvas { pixels: Buffer<Pixel>, masks: Buffer<List<u32>>, shown: Bool, protected: Bool, }
record Parked { pixels: List<Pixel>, masks: List<List<u32>>, shown: Bool, protected: Bool, }
record Job { ordinal: u32, closing: Bool, }
record Scene { canvas: Canvas, ancestors: Buffer<Parked>, todo: Buffer<Job>,
    capture: Captured, work: paint.Work, issue: String, }
record Overlay { pixels: Buffer<Pixel>, coverage: Buffer<u32>, issue: String, }
record Style { opacity: f64, blend: String, kind: String, protect: Bool, }
record Raster { width: u32, height: u32, frame: String, image: selection.Image, }
record PaintView { captured: Captured, pixels: List<Pixel>, }

fn palette_color(raw: json.Json) -> u32 {
    let s = json.as_text(raw).fold(fn(color) => color, fn(issue) => value.text(value.get(value.fields(raw), "color")));
    return repeat_until(6, 0, fn(acc) => false, fn(i) => fn(acc) =>
        acc * 16 + hex_digit(string_byte_at(s, i + 1).fold(fn(byte) => byte, fn(unit) => 48)));
}

fn hex_digit(byte: u32) -> u32 {
    if byte <= 57 { return byte - 48; }
    return if byte <= 70 { byte - 55 } else { byte - 87 };
}

fn no_cel() -> Cel { return Cel { id: "", layer: "", frame: "", fields: [] }; }
fn no_capture() -> Captured { return Captured { found: false, slots: [], alpha: [], clipping: [] }; }
fn blank() -> Pixel { return Pixel { slot: -1, color: 0, alpha: 0, locked: false }; }

fn cel_entry(frame: String, row: json.Member) -> Cel {
    let spec = value.fields(row.value);
    let id = json.lookup(spec, "id").fold(fn(v) => value.text(v), fn(unit) =>
        string_concat(string_concat(frame, "/"), row.key));
    return Cel { id: id, frame: frame, layer: row.key, fields: spec };
}

fn all_cels(frames: List<json.Json>) -> List<Cel> {
    let cels: Buffer<Cel> = Buffer.empty();
    return foldl(frames, cels, fn(frame) => fn(out) =>
        append_cels(value.fields(frame), out)).freeze();
}

fn append_cels(frame: List<json.Member>, out: Buffer<Cel>) -> Buffer<Cel> {
    let id = value.text(value.get(frame, "id"));
    return foldl(value.fields(value.get(frame, "cels")), out, fn(row) => fn(next) => next.push(cel_entry(id, row)));
}

fn find_cel(cels: List<Cel>, id: String) -> Cel {
    if id == "" { return no_cel(); }
    return repeat_until(length(cels), no_cel(), fn(cel) => cel.id != "", fn(i) => fn(found) =>
        if cels.at_or(i, no_cel()).id == id { cels.at_or(i, no_cel()) } else { found });
}

fn active_cel(cels: List<Cel>, frame: String, layer: String) -> Cel {
    return repeat_until(length(cels), no_cel(), fn(cel) => cel.id != "", fn(i) => fn(found) =>
        match_location(cels.at_or(i, no_cel()), frame, layer, found));
}

fn match_location(cel: Cel, frame: String, layer: String, found: Cel) -> Cel {
    return if cel.frame == frame && cel.layer == layer { cel } else { found };
}

fn content(cels: List<Cel>, start: Cel) -> List<json.Member> {
    let resolved = repeat_until(length(cels), start, fn(cel) => !value.has(cel.fields, "hold"),
        fn(i) => fn(cel) => find_cel(cels, value.text(value.get(cel.fields, "hold"))));
    return resolved.fields;
}

fn layer_spec(raw: json.Json) -> Layer {
    let fields = value.fields(raw);
    let opacity = json.lookup(fields, "opacity").fold(fn(v) => value.number(v), fn(unit) => 1.0f64);
    return Layer { id: value.text(value.get(fields, "id")), kind: value.text(value.get(fields, "kind")),
        parent: value.text(value.get(fields, "parent")), clip: value.text(value.get(fields, "clip")),
        blend: json.lookup(fields, "blend").fold(fn(v) => value.text(v), fn(unit) => "normal"),
        protect: value.flag(fields, "protect", false), locked: value.flag(fields, "locked", false),
        visible: value.flag(fields, "visible", true),
        opacity: opacity };
}

fn placement(layer: json.Json, cel: Cel) -> Placement {
    let layer_offset = value.items(value.get(value.fields(layer), "offset"));
    let cel_offset = value.items(value.get(cel.fields, "offset"));
    let alpha = json.lookup(cel.fields, "opacity").fold(fn(v) => value.number(v), fn(unit) => 255.0f64);
    return Placement { x: offset(layer_offset, 0) + offset(cel_offset, 0),
        y: offset(layer_offset, 1) + offset(cel_offset, 1), opacity: alpha / 255.0f64 };
}

fn offset(pair: List<json.Json>, index: u32) -> i32 {
    return value.integer(pair.at_or(index, json.null()), -1000000, 1000000).fold(fn(n) => n, fn(unit) => 0);
}

fn source_index(g: mask.Grid, p: u32, move: Placement) -> u32 {
    let x = f64_from_u32(rem_or(p, g.width, 0)) - f64_from_i32(move.x);
    let y = f64_from_u32(quot_or(p, g.width, 0)) - f64_from_i32(move.y);
    if x < 0.0f64 || y < 0.0f64 || x >= f64_from_u32(g.width) || y >= f64_from_u32(g.height) {
        return mask.size(g);
    }
    return value.as_word(y) * g.width + value.as_word(x);
}

fn translated(g: mask.Grid, raw: paint.Raw, move: Placement) -> paint.Raw {
    if (move.x == 0 && move.y == 0) || raw.issue != "" { return raw; }
    let slots: Buffer<i32> = buffer_fill(mask.size(g), -1);
    let mapped = repeat_until(mask.size(g), slots, fn(out) => false, fn(p) => fn(out) =>
        out.set(p, raw.slots.at_or(source_index(g, p, move), -1)));
    if length(raw.alpha) == 0 {
        return paint.Raw { ..raw, slots: mapped.freeze() };
    }
    let alpha: Buffer<u32> = buffer_fill(mask.size(g), 255);
    let bytes = repeat_until(mask.size(g), alpha, fn(out) => false, fn(p) => fn(out) =>
        out.set(p, raw.alpha.at_or(source_index(g, p, move), 255)));
    return paint.Raw { ..raw, slots: mapped.freeze(), alpha: bytes.freeze() };
}

fn channel(front: u32, back: u32, amount: f64, behind: f64, overlap: f64, blend: String) -> u32 {
    let a = f64_from_u32(front);
    let b = f64_from_u32(back);
    let combined = if blend == "multiply" { a * b / 255.0f64 } else {
        if blend == "screen" { 255.0f64 - (255.0f64 - a) * (255.0f64 - b) / 255.0f64 } else {
            if blend == "overlay" {
                if b <= 127.5f64 { 2.0f64 * a * b / 255.0f64 }
                else { 255.0f64 - 2.0f64 * (255.0f64 - a) * (255.0f64 - b) / 255.0f64 }
            } else { if blend == "add" { value.min(255.0f64, a + b) } else { a } }
        }
    };
    return value.round_byte((a * amount + (combined - a) * overlap + b * behind) / (amount + behind));
}

fn byte(rgb: u32, shift: u32) -> u32 { return word_and(wrapping_shr(rgb, shift), 255); }

fn mix(front: u32, back: Pixel, strength: f64, style: Style) -> u32 {
    let behind = f64_from_u32(back.alpha) * (255.0f64 - strength) / 255.0f64;
    if behind == 0.0f64 && (style.blend == "normal" || back.alpha == 0) { return front; }
    let overlap = strength * f64_from_u32(back.alpha) / 255.0f64;
    return repeat_until(3, 0, fn(rgb) => false, fn(i) => fn(rgb) =>
        mix_channel(rgb, front, back.color, i * 8, strength, behind, overlap, style.blend));
}

fn mix_channel(rgb: u32, front: u32, back: u32, shift: u32, amount: f64, behind: f64, overlap: f64, blend: String) -> u32 {
    let mixed = channel(byte(front, shift), byte(back, shift), amount, behind, overlap, blend);
    return word_or(rgb, wrapping_shl(mixed, shift));
}

fn decimal(n: u32) -> String {
    let stop: u32 = if n < 10 { 0 } else { if n < 100 { 1 } else { 2 } };
    return repeat_until(stop + 1, "", fn(out) => false, fn(i) => fn(out) =>
        string_concat(digit_at(n, i), out));
}

fn digit_at(n: u32, place: u32) -> String {
    let divisor: u32 = if place == 0 { 1 } else { if place == 1 { 10 } else { 100 } };
    let digit = rem_or(quot_or(n, divisor, 0), 10, 0);
    return string_slice("0123456789", digit, digit + 1).fold(fn(s) => s, fn(unit) => "");
}

fn color_at(colors: List<u32>, slot: i32) -> u32 {
    return colors.at_or(value.as_word(f64_from_i32(slot)), 0);
}

fn paint_cell(g: mask.Grid, source: Source, style: Style, colors: List<u32>, clip: List<u32>,
    p: u32, layer_id: String, out: Overlay) -> Overlay {
    let group = style.kind == "group";
    let cell = source.group.at_or(p, blank());
    let raw = if group { cell.slot } else { source.raw.slots.at_or(p, -1) };
    let cover = clip.at_or(p, 255);
    if raw == -1 || cover == 0 { return out; }
    let weight = style.opacity * (f64_from_u32(cover) / 255.0f64);
    let base = if group { cell.alpha } else { source.raw.alpha.at_or(p, 255) };
    let erase = raw == -2;
    let amount = if erase { 0 } else { value.round_byte(weight * f64_from_u32(base)) };
    if !erase && amount == 0 { return out; }
    let coverage = out.coverage.set(p, if style.kind == "mask" || group { amount } else { if amount > 0 { 255 } else { 0 } });
    let touched = Overlay { ..out, coverage: coverage };
    if style.kind == "mask" { return touched; }
    let rear = touched.pixels.at_or(p, blank());
    let slot: i32 = if erase { -1 } else { raw };
    if rear.locked {
        if slot != rear.slot {
            let at = string_concat(decimal(rem_or(p, g.width, 0)), string_concat(",", decimal(quot_or(p, g.width, 0))));
            return Overlay { ..touched, issue: string_concat(layer_id, string_concat(" changes a protected pixel at ", at)) };
        }
        return touched;
    }
    if erase && weight < 1.0f64 {
        let faded = value.round_byte(f64_from_u32(rear.alpha) * (1.0f64 - weight));
        if faded > 0 { return Overlay { ..touched, pixels: touched.pixels.set(p, Pixel { ..rear, alpha: faded }) }; }
    }
    let front = if group { cell.color } else { color_at(colors, slot) };
    let strength = f64_from_u32(amount);
    let behind = f64_from_u32(rear.alpha) * (255.0f64 - strength) / 255.0f64;
    let color = if amount == 0 { 0 } else { mix(front, rear, strength, style) };
    let opacity = if amount == 0 { 0 } else { value.round_byte(strength + behind) };
    return Overlay { ..touched, pixels: touched.pixels.set(p,
        Pixel { slot: slot, color: color, alpha: opacity, locked: style.protect || (group && cell.locked) }) };
}

fn opaque_cell(slots: List<i32>, colors: List<u32>, protect: Bool, p: u32, out: Overlay) -> Overlay {
    let slot = slots.at_or(p, -1);
    if slot == -1 { return out; }
    let cell = if slot == -2 { Pixel { ..blank(), locked: protect } }
        else { Pixel { slot: slot, color: color_at(colors, slot), alpha: 255, locked: protect } };
    return Overlay { ..out, pixels: out.pixels.set(p, cell), coverage: out.coverage.set(p, if slot == -2 { 0 } else { 255 }) };
}

fn clip_index(layers: List<Layer>, id: String, limit: u32) -> u32 {
    return repeat_until(limit, 4294967295, fn(slot) => slot != 4294967295, fn(i) => fn(slot) =>
        if layers.at_or(i, empty_layer()).id == id { i } else { slot });
}

fn empty_layer() -> Layer {
    return Layer { id: "", kind: "", parent: "", clip: "", blend: "normal", protect: false,
        locked: false, visible: false, opacity: 0.0f64 };
}

fn empty_canvas(art: Artwork, shown: Bool) -> Canvas {
    return Canvas { pixels: buffer_fill(mask.size(art.grid), blank()), masks: buffer_fill(length(art.layers), []),
        shown: shown, protected: false };
}

fn visible(layer: Layer, shown: Bool, opacity: f64) -> Bool {
    return shown && layer.visible && opacity > 0.0f64 && layer.kind != "reference";
}

fn children(layers: List<Layer>, parent: String, todo: Buffer<Job>) -> Buffer<Job> {
    let size = length(layers);
    return repeat_until(size, todo, fn(next) => false, fn(i) => fn(next) =>
        add_child(layers, parent, size - 1 - i, next));
}

fn add_child(layers: List<Layer>, parent: String, ordinal: u32, todo: Buffer<Job>) -> Buffer<Job> {
    if layers.at_or(ordinal, empty_layer()).parent != parent { return todo; }
    return todo.push(Job { ordinal: ordinal, closing: false });
}

fn open_group(art: Artwork, ordinal: u32, layer: Layer, old: Scene) -> Scene {
    let shown = visible(layer, old.canvas.shown, layer.opacity);
    let parent = Parked { pixels: old.canvas.pixels.freeze(), masks: old.canvas.masks.freeze(),
        shown: old.canvas.shown, protected: old.canvas.protected };
    let todo = children(art.layers, layer.id, old.todo.push(Job { ordinal: ordinal, closing: true }));
    return Scene { ..old, ancestors: old.ancestors.push(parent), canvas: empty_canvas(art, shown), todo: todo };
}

fn apply_layer(art: Artwork, scope: Scope, ordinal: u32, layer: Layer, opacity: f64, source: Source, has_protected: Bool, old: Scene) -> Scene {
    let canvas = old.canvas;
    let clip: List<u32> = if layer.clip == "" { [] } else { canvas.masks.at_or(clip_index(art.layers, layer.clip, ordinal), []) };
    let capture = if layer.kind != "group" && scope.layer == layer.id {
        Captured { found: true, slots: source.raw.slots, alpha: source.raw.alpha, clipping: clip }
    } else { old.capture };
    let coverage: Buffer<u32> = buffer_fill(mask.size(art.grid), 0);
    if !visible(layer, canvas.shown, opacity) {
        return Scene { ..old, capture: capture, canvas: Canvas { ..canvas, masks: canvas.masks.set(ordinal, coverage.freeze()) } };
    }
    let style = Style { opacity: opacity, blend: layer.blend, kind: layer.kind, protect: layer.protect };
    let start = Overlay { pixels: canvas.pixels, coverage: coverage, issue: "" };
    let result = draw_layer(art, layer.id, source, style, clip, canvas.protected, start);
    return Scene { ..old, canvas: Canvas { pixels: result.pixels, masks: canvas.masks.set(ordinal, result.coverage.freeze()),
        shown: canvas.shown, protected: canvas.protected || layer.protect || has_protected },
        capture: capture, issue: result.issue };
}

fn draw_layer(art: Artwork, id: String, source: Source, style: Style, clip: List<u32>, protected: Bool, start: Overlay) -> Overlay {
    let cells = mask.size(art.grid);
    if !protected && style.kind != "group" && style.kind != "mask" && style.blend == "normal" &&
        style.opacity == 1.0f64 && length(clip) == 0 && length(source.raw.alpha) == 0 {
        return repeat_until(cells, start, fn(out) => false, fn(p) => fn(out) =>
            opaque_cell(source.raw.slots, art.colors, style.protect, p, out));
    }
    return repeat_until(cells, start, fn(out) => out.issue != "", fn(p) => fn(out) =>
        paint_cell(art.grid, source, style, art.colors, clip, p, id, out));
}

fn close_group(art: Artwork, scope: Scope, ordinal: u32, layer: Layer, scene: Scene) -> Scene {
    let ancestor = scene.ancestors.at_or(scene.ancestors.len() - 1, Parked { pixels: [], masks: [], shown: false, protected: false });
    let group_protected = scene.canvas.protected;
    let source = Source { group: scene.canvas.pixels.freeze(),
        raw: paint.Raw { slots: [], alpha: [], work: scene.work, issue: "" } };
    let old = Scene { ..scene, ancestors: scene.ancestors.pop(),
        canvas: Canvas { pixels: buffer(ancestor.pixels), masks: buffer(ancestor.masks), shown: ancestor.shown, protected: ancestor.protected } };
    return apply_layer(art, scope, ordinal, layer, layer.opacity, source, group_protected, old);
}

fn step(art: Artwork, scope: Scope, scene: Scene) -> Scene {
    let job = scene.todo.at_or(scene.todo.len() - 1, Job { ordinal: 0, closing: false });
    let old = Scene { ..scene, todo: scene.todo.pop() };
    let layer = art.layers.at_or(job.ordinal, empty_layer());
    if job.closing { return close_group(art, scope, job.ordinal, layer, old); }
    if layer.kind == "group" { return open_group(art, job.ordinal, layer, old); }
    let active = active_cel(art.cels, scope.frame, layer.id);
    let place = placement(art.inputs.at_or(job.ordinal, json.null()), active);
    let raw = translated(art.grid, paint.raster(art.grid, art.ids, content(art.cels, active), old.work), place);
    if raw.issue != "" { return Scene { ..old, issue: raw.issue }; }
    let next = Scene { ..old, work: raw.work };
    return apply_layer(art, scope, job.ordinal, layer, layer.opacity * place.opacity, Source { raw: raw, group: [] }, false, next);
}

fn composite(art: Artwork, scope: Scope) -> Scene {
    let todo: Buffer<Job> = Buffer.empty();
    let initial = Scene { canvas: empty_canvas(art, true), ancestors: Buffer.empty(),
        todo: children(art.layers, "", todo), capture: no_capture(), work: paint.untouched(), issue: "" };
    return repeat_until(length(art.layers) * 2, initial, fn(scene) => scene.issue != "" || scene.todo.len() == 0,
        fn(i) => fn(scene) => step(art, scope, scene));
}

fn frame_name(row: json.Json) -> String { return value.text(value.get(value.fields(row), "id")); }

fn rgba(rgb: u32, opacity: u32) -> u32 { return word_or(wrapping_shl(rgb, 8), opacity); }

fn raw_rgba(capture: Captured, colors: List<u32>, i: u32, slot: i32) -> u32 {
    if slot < 0 || capture.clipping.at_or(i, 255) == 0 { return 0; }
    return rgba(color_at(colors, slot), capture.alpha.at_or(i, 255));
}

fn finish(art: Artwork, scene: Scene, scope: Scope) -> Result<Raster, String> {
    if scene.issue != "" { return Err(scene.issue); }
    return finish_view(art, PaintView { captured: scene.capture, pixels: scene.canvas.pixels.freeze() }, scope);
}

fn finish_view(art: Artwork, view: PaintView, scope: Scope) -> Result<Raster, String> {
    let capture = view.captured;
    let pixels = view.pixels;
    if scope.layer != "" && !capture.found { return Err(string_concat("Unknown pixel layer ", scope.layer)); }
    let slots = if capture.found { capture.slots } else { pixels.map(fn(cell) => cell.slot) };
    let alpha = if capture.found { capture.alpha } else { pixels.map(fn(cell) => cell.alpha) };
    let words = if capture.found { slots.map_indexed(fn(i) => fn(slot) => raw_rgba(capture, art.colors, i, slot)) }
        else { pixels.map(fn(cell) => rgba(cell.color, cell.alpha)) };
    let palette = mask.PaletteRaster { slots: slots, alpha: alpha, clipping: capture.clipping, ids: art.ids };
    return Ok(Raster { width: art.grid.width, height: art.grid.height, frame: scope.frame,
        image: selection.Image { palette: palette, rgba: words } });
}

fn empty_artwork() -> Artwork {
    return Artwork { grid: mask.Grid { width: 0, height: 0 }, layers: [], ids: [], colors: [],
        cels: [], locations: [], frames: [], inputs: [] };
}

fn artwork_grid(art: Artwork) -> mask.Grid { return art.grid; }

fn prepare(document: json.Json) -> Artwork {
    let spec = value.fields(document);
    let frames = value.items(value.get(spec, "frames"));
    let palette = value.fields(value.get(spec, "palette"));
    let layers = value.items(value.get(spec, "layers"));
    let g = mask.Grid { width: value.word(value.get(spec, "width"), 512),
        height: value.word(value.get(spec, "height"), 512) };
    let cels = all_cels(frames);
    return Artwork { grid: g, layers: layers.map(fn(raw) => layer_spec(raw)),
        ids: palette.map(fn(swatch) => swatch.key), colors: palette.map(fn(swatch) => palette_color(swatch.value)),
        cels: cels, locations: cels.map(fn(cel) => Location { id: cel.id, frame: cel.frame, layer: cel.layer }), frames: frames.map(fn(row) => frame_name(row)), inputs: layers };
}

fn known_frame(frames: List<String>, frame: String) -> Bool {
    return foldl(frames, false, fn(id) => fn(found) => found || id == frame);
}

fn optional_scope(id: String) -> Option<String> { return if id == "" { None } else { Some(id) }; }

fn location(rows: List<Location>, id: String) -> Location {
    let missing = Location { id: "", frame: "", layer: "" };
    return repeat_until(length(rows), missing, fn(found) => found.frame != "",
        fn(i) => fn(found) => lookup_location(rows.at_or(i, missing), id, found));
}

fn lookup_location(row: Location, id: String, found: Location) -> Location {
    return if row.id == id { row } else { found };
}

fn resolve(art: Artwork, frame: Option<String>, layer: Option<String>, cel: Option<String>) -> Result<Scope, String> {
    let layer_set = layer.fold(fn(id) => true, fn(unit) => false);
    let cel_set = cel.fold(fn(id) => true, fn(unit) => false);
    if layer_set && cel_set { return Err("Select from the composite, a layer or a cel"); }
    let chosen = frame.fold(fn(id) => id, fn(unit) => "");
    if !frame.fold(fn(id) => known_frame(art.frames, id), fn(unit) => true) {
        return Err(string_concat("Unknown pixel frame ", chosen));
    }
    if cel_set { return cel_scope(art.locations, chosen, cel.fold(fn(id) => id, fn(unit) => "")); }
    let target = layer.fold(fn(id) => id, fn(unit) => "");
    if layer_set && target == "" { return Err("Unknown pixel layer "); }
    let active = if chosen == "" { art.frames.at_or(0, "") } else { chosen };
    return Ok(Scope { frame: active, layer: target });
}

fn cel_scope(locations: List<Location>, frame: String, cel: String) -> Result<Scope, String> {
    let selected = location(locations, cel);
    if selected.frame == "" || (frame != "" && frame != selected.frame) {
        let suffix = if frame == "" { "" } else { string_concat(" on frame ", frame) };
        return Err(string_concat("Unknown pixel cel ", string_concat(cel, suffix)));
    }
    return Ok(Scope { frame: selected.frame, layer: selected.layer });
}

fn raster(art: Artwork, scope: Scope) -> Result<Raster, String> {
    let result = composite(art, scope);
    return finish(art, result, scope);
}

fn paint_view(art: Artwork, scope: Scope) -> Result<PaintView, String> {
    let scene = composite(art, scope);
    if scene.issue != "" { return Err(scene.issue); }
    return Ok(PaintView { captured: scene.capture, pixels: scene.canvas.pixels.freeze() });
}

fn compile(document: json.Json, frame: String, layer: String, cel: String) -> Result<Raster, String> {
    let art = prepare(document);
    let scope = resolve(art, optional_scope(frame), optional_scope(layer), optional_scope(cel))?;
    return raster(art, scope);
}
