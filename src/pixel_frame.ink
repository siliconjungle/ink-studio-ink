module StudioPixelFrame;

import "std:json" as json;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;
import "pixel_raster.ink" as paint;
import "pixel_selection.ink" as selection;

record Location { id: String, frame: String, layer: String, }
record Cel { id: String, layer: String, frame: String, fields: List<json.Member>, runs: List<paint.RunMark>,
    prepared: List<paint.RunMark>, plane: u32, run_plane: u32, }
record SlotPlane { frame: String, layer: String, pixels: List<i32>, }
record RunPlane { frame: String, layer: String, marks: List<List<u32>>, }
record SlotOwner { frame: String, layer: String, plane: u32, }
record AttachedPlanes { cels: List<Cel>, ordinal: u32, issue: String, }
record Placement { x: i32, y: i32, opacity: f64, }
record Layer { id: String, kind: String, parent: String, clip: String, blend: String, protect: Bool,
    locked: Bool, visible: Bool, opacity: f64, }
record Artwork { grid: mask.Grid, layers: List<Layer>, ids: List<String>, colors: List<u32>,
    cels: List<Cel>, locations: List<Location>, frames: List<String>, inputs: List<json.Json>, planes: List<List<i32>>,
    run_planes: List<List<List<u32>>>, }
record Scope { frame: String, layer: String, }
record Captured { found: Bool, slots: List<i32>, alpha: List<u32>, clipping: List<u32>, }
record Pixel { slot: i32, color: u32, alpha: u32, locked: Bool, }
record Source { raw: paint.Raw, group: List<Pixel>, trace: List<u32>, uses_alpha: Bool, }
record Canvas { pixels: Buffer<Pixel>, masks: Buffer<List<u32>>, trace: Buffer<u32>,
    uses_alpha: Bool, shown: Bool, protected: Bool, }
record Parked { pixels: List<Pixel>, masks: List<List<u32>>, trace: List<u32>,
    uses_alpha: Bool, shown: Bool, protected: Bool, }
record Job { ordinal: u32, closing: Bool, }
record CaptureSpec { owners: Bool, layers: Bool, alpha: Bool, references: Bool, inspect: u32, sample_only: Bool, }
record RawLayer { owner: u32, view: Captured, }
record Observation { ordinal: u32, opacity: f64, visible: Bool, clip: u32, slot: i32, rgb: u32, alpha: u32,
    state: String, effective: Option<u32>, before: Option<Pixel>, after: Option<Pixel>, }
record Scene { canvas: Canvas, ancestors: Buffer<Parked>, todo: Buffer<Job>,
    capture: Captured, sources: Buffer<RawLayer>, observations: Buffer<Observation>,
    spec: CaptureSpec, work: paint.Work, issue: String, }
record Overlay { pixels: Buffer<Pixel>, coverage: Buffer<u32>, trace: Buffer<u32>, issue: String, }
enum Blend { Normal, Multiply, Screen, Overlay, Add, }
record Style { id: String, opacity: f64, blend: Blend, kind: String, protect: Bool, owner: u32, }
record Raster { width: u32, height: u32, frame: String, image: selection.Image, }
record PaintView { captured: Captured, pixels: List<Pixel>, }
record PreviewView { pixels: List<Pixel>, trace: List<u32>, uses_alpha: Bool, sources: List<RawLayer>, }
record ExportView { pixels: List<Pixel>, uses_alpha: Bool, raw: Captured, sources: List<RawLayer>, }
record Inspected { view: PreviewView, sample: u32, observations: List<Observation>, }

fn palette_color(raw: json.Json) -> u32 {
    let s = json.as_text(raw).fold(fn(color) => color, fn(issue) => value.text(value.get(value.fields(raw), "color")));
    return repeat_until(6, 0, fn(acc) => false, fn(i) => fn(acc) =>
        acc * 16 + hex_digit(string_byte_at(s, i + 1).fold(fn(byte) => byte, fn(unit) => 48)));
}

fn hex_digit(byte: u32) -> u32 {
    if byte <= 57 { return byte - 48; }
    return if byte <= 70 { byte - 55 } else { byte - 87 };
}

fn no_cel() -> Cel {
    return Cel { id: "", layer: "", frame: "", fields: [], runs: [], prepared: [], plane: 0, run_plane: 0 };
}
fn no_capture() -> Captured { return Captured { found: false, slots: [], alpha: [], clipping: [] }; }
fn blank() -> Pixel { return Pixel { slot: -1, color: 0, alpha: 0, locked: false }; }

fn cel_entry(frame: String, row: json.Member) -> Cel {
    let spec = value.fields(row.value);
    let id = json.lookup(spec, "id").fold(fn(v) => value.text(v), fn(unit) =>
        string_concat(string_concat(frame, "/"), row.key));
    return Cel { id: id, frame: frame, layer: row.key, fields: spec, runs: [], prepared: [], plane: 0, run_plane: 0 };
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
    return fold_until(cels, no_cel(), fn(row) => fn(found) => found.id != "", fn(row) => fn(found) =>
        if row.id == id { row } else { found });
}

fn active_cel(cels: List<Cel>, frame: String, layer: String) -> Cel {
    return fold_until(cels, no_cel(), fn(row) => fn(found) => found.id != "", fn(row) => fn(found) =>
        if row.frame == frame && row.layer == layer { row } else { found });
}

fn resolved_cel(cels: List<Cel>, start: Cel) -> Cel {
    return repeat_until(length(cels), start, fn(cel) => !value.has(cel.fields, "hold"),
        fn(i) => fn(cel) => find_cel(cels, value.text(value.get(cel.fields, "hold"))));
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

// A translated axis is (source start, destination start, shared extent).
fn translated_axis(extent: u32, offset: i32) -> Vec3<u32> {
    let distance = value.as_word(if offset < 0 { -f64_from_i32(offset) } else { f64_from_i32(offset) });
    let shared = if distance < extent { extent - distance } else { 0 };
    return if offset < 0 { vec3(distance, 0, shared) } else { vec3(0, distance, shared) };
}

fn translated_row<T>(values: List<T>, fill: T, count: u32, from: u32, to: u32, output: Buffer<T>) -> Buffer<T> {
    return repeat_until(count, output, fn(out) => false, fn(x) => fn(out) =>
        out.set(to + x, values.at_or(from + x, fill)));
}

fn translated_plane<T>(g: mask.Grid, values: List<T>, fill: T, x: Vec3<u32>, y: Vec3<u32>) -> List<T> {
    let start: Buffer<T> = buffer_fill(mask.size(g), fill);
    if x.z == 0 { return start.freeze(); }
    let from = y.x * g.width + x.x;
    let to = y.y * g.width + x.y;
    return repeat_until(y.z, start, fn(out) => false, fn(row) => fn(out) =>
        translated_row<T>(values, fill, x.z, from + row * g.width, to + row * g.width, out)).freeze();
}

fn translated(g: mask.Grid, raw: paint.Raw, move: Placement) -> paint.Raw {
    if (move.x == 0 && move.y == 0) || raw.issue != "" { return raw; }
    let x = translated_axis(g.width, move.x);
    let y = translated_axis(g.height, move.y);
    let slots = translated_plane<i32>(g, raw.slots, -1, x, y);
    let alpha: List<u32> = if length(raw.alpha) == 0 { [] } else { translated_plane<u32>(g, raw.alpha, 255, x, y) };
    return paint.Raw { ..raw, slots: slots, alpha: alpha };
}

fn translated_sample(g: mask.Grid, raw: paint.Raw, move: Placement, p: u32) -> paint.Raw {
    let x = translated_axis(g.width, move.x);
    let y = translated_axis(g.height, move.y);
    let col = rem_or(p, g.width, 0);
    let row = quot_or(p, g.width, 0);
    let source: u32 = if col < x.y || col >= x.y + x.z || row < y.y || row >= y.y + y.z { 4294967295 }
        else { (row - y.y + y.x) * g.width + col - x.y + x.x };
    let alpha: List<u32> = if length(raw.alpha) == 0 { [] } else { [raw.alpha.at_or(source, 255)] };
    return paint.Raw { ..raw, slots: [raw.slots.at_or(source, -1)], alpha: alpha };
}

fn blend_mode(name: String) -> Blend {
    if name == "multiply" { return Blend.Multiply; }
    if name == "screen" { return Blend.Screen; }
    if name == "overlay" { return Blend.Overlay; }
    if name == "add" { return Blend.Add; }
    return Blend.Normal;
}

fn channel(front: u32, back: u32, amount: f64, behind: f64, overlap: f64, blend: Blend) -> u32 {
    let a = f64_from_u32(front);
    let b = f64_from_u32(back);
    let combined = match blend {
        Blend.Normal => a,
        Blend.Multiply => a * b / 255.0f64,
        Blend.Screen => 255.0f64 - (255.0f64 - a) * (255.0f64 - b) / 255.0f64,
        Blend.Overlay => if b <= 127.5f64 { 2.0f64 * a * b / 255.0f64 }
            else { 255.0f64 - 2.0f64 * (255.0f64 - a) * (255.0f64 - b) / 255.0f64 },
        Blend.Add => value.min(255.0f64, a + b),
    };
    return value.round_byte((a * amount + (combined - a) * overlap + b * behind) / (amount + behind));
}

fn byte(rgb: u32, shift: u32) -> u32 { return word_and(wrapping_shr(rgb, shift), 255); }

fn mix(front: u32, back: Pixel, strength: f64, behind: f64, blend: Blend) -> u32 {
    if behind == 0.0f64 && (blend == Blend.Normal || back.alpha == 0) { return front; }
    let overlap = strength * f64_from_u32(back.alpha) / 255.0f64;
    return repeat_until(3, 0, fn(rgb) => false, fn(i) => fn(rgb) =>
        mix_channel(rgb, front, back.color, i * 8, strength, behind, overlap, blend));
}

fn mix_channel(rgb: u32, front: u32, back: u32, shift: u32, amount: f64, behind: f64, overlap: f64, blend: Blend) -> u32 {
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

// The two seven-bit owner IDs are one-based layer ordinals. The remaining
// bits store the previous swatch plus one, with zero representing blank.
fn owner(trace: u32) -> u32 { return word_and(trace, 127); }
fn under_owner(trace: u32) -> u32 { return owner(wrapping_shr(trace, 7)); }
fn under_swatch(trace: u32) -> u32 { return wrapping_shr(trace, 14); }

fn pack_trace(front: u32, rear: u32, slot: i32) -> u32 {
    let swatch = value.as_word(f64_from_i32(slot + 1));
    return front + wrapping_shl(owner(rear), 7) + wrapping_shl(swatch, 14);
}

fn stamp_trace(front: u32, slot: i32, p: u32, trace: Buffer<u32>) -> Buffer<u32> {
    let packed = pack_trace(front, trace.at_or(p, 0), slot);
    return trace.set(p, packed);
}

fn overlay_trace(source: Source, style: Style, rear: Pixel, p: u32, trace: Buffer<u32>) -> Buffer<u32> {
    if style.owner == 0 { return trace; }
    let inner = source.trace.at_or(p, 0);
    if under_owner(inner) != 0 { return trace.set(p, inner); }
    let front = if style.kind == "group" { owner(inner) } else { style.owner };
    return stamp_trace(front, rear.slot, p, trace);
}

fn paint_cell(g: mask.Grid, source: Source, style: Style, colors: List<u32>, clip: List<u32>,
    p: u32, out: Overlay) -> Overlay {
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
    if rear.locked && style.kind != "reference" {
        if slot != rear.slot {
            let at = string_concat(decimal(rem_or(p, g.width, 0)), string_concat(",", decimal(quot_or(p, g.width, 0))));
            return Overlay { ..touched, issue: string_concat(style.id, string_concat(" changes a protected pixel at ", at)) };
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
    let color = if amount == 0 { 0 } else { mix(front, rear, strength, behind, style.blend) };
    let opacity = if amount == 0 { 0 } else { value.round_byte(strength + behind) };
    return Overlay { ..touched, trace: overlay_trace(source, style, rear, p, touched.trace), pixels: touched.pixels.set(p,
        Pixel { slot: slot, color: color, alpha: opacity, locked: style.protect || (group && cell.locked) }) };
}

fn opaque_cell(slots: List<i32>, colors: List<u32>, style: Style, p: u32, out: Overlay) -> Overlay {
    let slot = slots.at_or(p, -1);
    if slot == -1 { return out; }
    let cell = if slot == -2 { Pixel { ..blank(), locked: style.protect } }
        else { Pixel { slot: slot, color: color_at(colors, slot), alpha: 255, locked: style.protect } };
    let trace = if style.owner == 0 { out.trace }
        else { stamp_trace(style.owner, out.pixels.at_or(p, blank()).slot, p, out.trace) };
    return Overlay { ..out, trace: trace, pixels: out.pixels.set(p, cell),
        coverage: out.coverage.set(p, if slot == -2 { 0 } else { 255 }) };
}

fn clip_index(layers: List<Layer>, id: String, limit: u32) -> u32 {
    return repeat_until(limit, 4294967295, fn(slot) => slot != 4294967295, fn(i) => fn(slot) =>
        if layers.at_or(i, empty_layer()).id == id { i } else { slot });
}

fn empty_layer() -> Layer {
    return Layer { id: "", kind: "", parent: "", clip: "", blend: "normal", protect: false,
        locked: false, visible: false, opacity: 0.0f64 };
}

fn empty_canvas(art: Artwork, cells: u32, shown: Bool, preview: Bool) -> Canvas {
    return Canvas { pixels: buffer_fill(cells, blank()), masks: buffer_fill(length(art.layers), []),
        trace: if preview { buffer_fill(cells, 0) } else { Buffer.empty() },
        uses_alpha: false, shown: shown, protected: false };
}

fn visible(layer: Layer, shown: Bool, opacity: f64, references: Bool) -> Bool {
    return shown && layer.visible && opacity > 0.0f64 && (references || layer.kind != "reference");
}

fn observation_status(row: Observation, layer: Layer, parent_shown: Bool) -> String {
    if !parent_shown { return "parent-hidden"; }
    if !layer.visible { return "hidden"; }
    if row.opacity == 0.0f64 { return "zero-opacity"; }
    if !row.visible && layer.kind == "reference" { return "reference-disabled"; }
    if row.slot == -1 { return "empty"; }
    if row.clip == 0 { return "clipped"; }
    return "transparent";
}

fn observe(ordinal: u32, layer: Layer, opacity: f64, shown: Bool, visible: Bool, source: Source, colors: List<u32>,
    clip: List<u32>, point: u32, before: Pixel, after: Pixel, rows: Buffer<Observation>) -> Buffer<Observation> {
    let group = layer.kind == "group";
    let group_pixel = source.group.at_or(point, blank());
    let slot = if group { group_pixel.slot } else { source.raw.slots.at_or(point, -1) };
    let rgb = if group { group_pixel.color } else { color_at(colors, slot) };
    let alpha = if group { group_pixel.alpha } else { source.raw.alpha.at_or(point, 255) };
    let row = Observation { ordinal: ordinal, opacity: opacity, visible: visible, clip: clip.at_or(point, 255),
        slot: slot, rgb: rgb, alpha: alpha, state: "", effective: None, before: None, after: None };
    return rows.push(observe_write(row, layer, shown, before, after));
}

fn observe_write(row: Observation, layer: Layer, shown: Bool, before: Pixel, after: Pixel) -> Observation {
    let status = observation_status(row, layer, shown);
    let weight = row.opacity * (f64_from_u32(row.clip) / 255.0f64);
    let erase = row.slot == -2;
    let alpha = value.round_byte(weight * f64_from_u32(if erase { 255 } else { row.alpha }));
    if !row.visible || row.slot == -1 || row.clip == 0 || !erase && alpha == 0 {
        return Observation { ..row, state: status };
    }
    let color_mask = layer.kind == "mask";
    let locked = before.locked && layer.kind != "reference";
    let state = if color_mask { "mask" } else {
        if locked { "protected" } else { if erase { "knockout" } else { "paint" } }
    };
    return Observation { ..row, state: state, effective: Some(alpha), before: Some(before),
        after: if color_mask || locked { None } else { Some(after) } };
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
    let shown = visible(layer, old.canvas.shown, layer.opacity, old.spec.references);
    let parent = Parked { pixels: old.canvas.pixels.freeze(), masks: old.canvas.masks.freeze(),
        trace: old.canvas.trace.freeze(), uses_alpha: old.canvas.uses_alpha,
        shown: old.canvas.shown, protected: old.canvas.protected };
    let todo = children(art.layers, layer.id, old.todo.push(Job { ordinal: ordinal, closing: true }));
    return Scene { ..old, ancestors: old.ancestors.push(parent),
        canvas: empty_canvas(art, length(parent.pixels), shown, length(parent.trace) != 0), todo: todo };
}

fn apply_layer(art: Artwork, scope: Scope, ordinal: u32, layer: Layer, opacity: f64, source: Source, has_protected: Bool, old: Scene) -> Scene {
    let canvas = old.canvas;
    let clip_from = if layer.clip == "" { 4294967295 } else { clip_index(art.layers, layer.clip, ordinal) };
    let clip: List<u32> = canvas.masks.at_or(clip_from, []);
    let raw = Captured { found: true, slots: source.raw.slots, alpha: source.raw.alpha, clipping: clip };
    let capture = if layer.kind != "group" && scope.layer == layer.id { raw } else { old.capture };
    let sources = if old.spec.layers && layer.kind != "group" {
        old.sources.push(RawLayer { owner: ordinal + 1, view: raw })
    } else { old.sources };
    let coverage: Buffer<u32> = buffer_fill(canvas.pixels.len(), 0);
    let seen = visible(layer, canvas.shown, opacity, old.spec.references);
    let point = if old.spec.sample_only { 0 } else { old.spec.inspect };
    let before = if point == 4294967295 { blank() } else { canvas.pixels.at_or(point, blank()) };
    if !seen {
        let observations = if point == 4294967295 { old.observations } else {
            observe(ordinal, layer, opacity, canvas.shown, false, source, art.colors,
                clip, point, before, before, old.observations)
        };
        return Scene { ..old, capture: capture, sources: sources, observations: observations,
            canvas: Canvas { ..canvas, masks: canvas.masks.set(ordinal, coverage.freeze()) } };
    }
    let tracking = canvas.trace.len() != 0;
    let style = Style { id: layer.id, opacity: opacity, blend: blend_mode(layer.blend), kind: layer.kind,
        protect: layer.protect, owner: if tracking { ordinal + 1 } else { 0 } };
    let start = Overlay { pixels: canvas.pixels, coverage: coverage, trace: canvas.trace, issue: "" };
    let result = draw_layer(art, source, style, clip, canvas.protected, start);
    let observations = if point == 4294967295 { old.observations } else {
        observe(ordinal, layer, opacity, canvas.shown, true, source, art.colors,
            clip, point, before, result.pixels.at_or(point, blank()), old.observations)
    };
    let uses_alpha = canvas.uses_alpha || old.spec.alpha && (opacity != 1.0f64 || layer.blend != "normal" ||
        if layer.kind == "group" { source.uses_alpha } else {
            length(source.raw.alpha) != 0 || art.layers.at_or(clip_from, empty_layer()).kind == "mask"
        });
    return Scene { ..old, canvas: Canvas { pixels: result.pixels, masks: canvas.masks.set(ordinal, result.coverage.freeze()),
        trace: result.trace, uses_alpha: uses_alpha, shown: canvas.shown,
        protected: canvas.protected || layer.protect || has_protected },
        capture: capture, sources: sources, observations: observations, issue: result.issue };
}

fn draw_layer(art: Artwork, source: Source, style: Style, clip: List<u32>, protected: Bool, start: Overlay) -> Overlay {
    let cells = start.pixels.len();
    if !protected && style.kind != "group" && style.kind != "mask" && style.blend == Blend.Normal &&
        style.opacity == 1.0f64 && length(clip) == 0 && length(source.raw.alpha) == 0 {
        return repeat_until(cells, start, fn(out) => false, fn(p) => fn(out) =>
            opaque_cell(source.raw.slots, art.colors, style, p, out));
    }
    return repeat_until(cells, start, fn(out) => out.issue != "", fn(p) => fn(out) =>
        paint_cell(art.grid, source, style, art.colors, clip, p, out));
}

fn close_group(art: Artwork, scope: Scope, ordinal: u32, layer: Layer, scene: Scene) -> Scene {
    let ancestor = scene.ancestors.at_or(scene.ancestors.len() - 1,
        Parked { pixels: [], masks: [], trace: [], uses_alpha: false, shown: false, protected: false });
    let group_protected = scene.canvas.protected;
    let source = Source { group: scene.canvas.pixels.freeze(), trace: scene.canvas.trace.freeze(),
        uses_alpha: scene.canvas.uses_alpha,
        raw: paint.Raw { slots: [], alpha: [], work: scene.work, issue: "" } };
    let old = Scene { ..scene, ancestors: scene.ancestors.pop(),
        canvas: Canvas { pixels: buffer(ancestor.pixels), masks: buffer(ancestor.masks), trace: buffer(ancestor.trace),
            uses_alpha: ancestor.uses_alpha, shown: ancestor.shown, protected: ancestor.protected } };
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
    let source = resolved_cel(art.cels, active);
    let slots: List<i32> = if source.plane == 0 { [] } else { art.planes.at_or(source.plane - 1, []) };
    let runs: List<List<u32>> = if source.run_plane == 0 { [] } else { art.run_planes.at_or(source.run_plane - 1, []) };
    let raster = paint.raster(art.grid, art.ids, source.fields, slots, runs, source.prepared, source.runs, old.work);
    let raw = if old.spec.sample_only { translated_sample(art.grid, raster, place, old.spec.inspect) }
        else { translated(art.grid, raster, place) };
    if raw.issue != "" { return Scene { ..old, issue: raw.issue }; }
    let next = Scene { ..old, work: raw.work };
    let input = Source { raw: raw, group: [], trace: [], uses_alpha: false };
    return apply_layer(art, scope, job.ordinal, layer, layer.opacity * place.opacity, input, false, next);
}

fn compose(art: Artwork, scope: Scope, spec: CaptureSpec) -> Scene {
    let todo: Buffer<Job> = Buffer.empty();
    let cells = if spec.sample_only { 1 } else { mask.size(art.grid) };
    let initial = Scene { canvas: empty_canvas(art, cells, true, spec.owners), ancestors: Buffer.empty(),
        todo: children(art.layers, "", todo), capture: no_capture(), sources: Buffer.empty(), observations: Buffer.empty(), spec: spec,
        work: paint.untouched(), issue: "" };
    return repeat_until(length(art.layers) * 2, initial, fn(scene) => scene.issue != "" || scene.todo.len() == 0,
        fn(i) => fn(scene) => step(art, scope, scene));
}

fn composite(art: Artwork, scope: Scope) -> Scene {
    return compose(art, scope, CaptureSpec { owners: false, layers: false, alpha: false, references: false,
        inspect: 4294967295, sample_only: false });
}

fn preview_view(art: Artwork, id: String, exact: Bool) -> Result<PreviewView, String> {
    let scene = compose(art, Scope { frame: id, layer: "" },
        CaptureSpec { owners: true, layers: exact, alpha: true, references: false, inspect: 4294967295, sample_only: false });
    if scene.issue != "" { return Err(scene.issue); }
    return Ok(PreviewView { pixels: scene.canvas.pixels.freeze(), trace: scene.canvas.trace.freeze(),
        uses_alpha: scene.canvas.uses_alpha, sources: scene.sources.freeze() });
}

fn export_view(art: Artwork, scope: Scope, references: Bool, layers: Bool) -> Result<ExportView, String> {
    let scene = compose(art, scope,
        CaptureSpec { owners: false, layers: layers, alpha: true, references: references, inspect: 4294967295, sample_only: false });
    if scene.issue != "" { return Err(scene.issue); }
    return Ok(ExportView { pixels: scene.canvas.pixels.freeze(), raw: scene.capture,
        uses_alpha: scene.canvas.uses_alpha, sources: scene.sources.freeze() });
}

fn inspect_view(art: Artwork, scope: Scope, references: Bool, point: u32, check_gaps: Bool) -> Result<Inspected, String> {
    // Composition can reject conflicting protected paint anywhere in the frame.
    let sample_only = !check_gaps && length(art.layers.filter(fn(layer) => layer.protect)) == 0;
    let scene = compose(art, scope,
        CaptureSpec { owners: true, layers: false, alpha: true, references: references, inspect: point, sample_only: sample_only });
    if scene.issue != "" { return Err(scene.issue); }
    return Ok(Inspected { view: PreviewView { pixels: scene.canvas.pixels.freeze(), trace: scene.canvas.trace.freeze(),
        uses_alpha: scene.canvas.uses_alpha, sources: [] },
        sample: if sample_only { 0 } else { point }, observations: scene.observations.freeze() });
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
        cels: [], locations: [], frames: [], inputs: [], planes: [], run_planes: [] };
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
        cels: cels, locations: cels.map(fn(cel) => Location { id: cel.id, frame: cel.frame, layer: cel.layer }),
        frames: frames.map(fn(row) => frame_name(row)), inputs: layers, planes: [], run_planes: [] };
}

fn plan_runs(art: Artwork) -> Artwork {
    let cels = art.cels.map(fn(cel) => if cel.run_plane != 0 { cel } else {
        Cel { ..cel, prepared: paint.prepare_runs(art.grid, art.ids, cel.fields) }
    });
    return Artwork { ..art, cels: cels };
}

fn attach_planes(art: Artwork, planes: List<SlotPlane>) -> Result<Artwork, String> {
    if length(planes) == 0 { return Ok(art); }
    let count = mask.size(art.grid);
    let last = i32_from_f64(f64_from_u32(length(art.ids))).fold(fn(n) => n, fn(unit) => 0);
    let start = AttachedPlanes { cels: art.cels, ordinal: 0, issue: "" };
    let bound = fold_until(planes, start, fn(plane) => fn(out) => out.issue != "",
        fn(plane) => fn(out) => if out.issue != "" { out } else { attach_plane(out, plane, count, last) });
    if bound.issue != "" { return Err(bound.issue); }
    return Ok(Artwork { ..art, cels: bound.cels, planes: planes.map(fn(plane) => plane.pixels) });
}

fn attach_plane(out: AttachedPlanes, plane: SlotPlane, count: u32, last: i32) -> AttachedPlanes {
    let cel = active_cel(out.cels, plane.frame, plane.layer);
    let marker = json.lookup(cel.fields, "slots").fold(fn(raw) =>
        json.elements(raw).fold(fn(rows) => length(rows) == 0, fn(issue) => false), fn(unit) => false);
    if !marker || cel.plane != 0 || length(plane.pixels) != count {
        return AttachedPlanes { ..out, issue: "Pixel layer slots need a named swatch or null per art pixel" };
    }
    if fold_until(plane.pixels, false, fn(slot) => fn(invalid) => invalid,
        fn(slot) => fn(invalid) => invalid || slot < -1 || slot >= last) {
        return AttachedPlanes { ..out, issue: "Packed pixel layer contains an unknown swatch" };
    }
    let ordinal = out.ordinal + 1;
    let cels = out.cels.map(fn(row) => if row.id == cel.id { Cel { ..row, plane: ordinal } } else { row });
    return AttachedPlanes { cels: cels, ordinal: ordinal, issue: "" };
}

fn slot_owners(art: Artwork) -> List<SlotOwner> {
    return art.cels.filter(fn(cel) => cel.plane != 0).map(fn(cel) =>
        SlotOwner { frame: cel.frame, layer: cel.layer, plane: cel.plane });
}

fn attach_run_plane(out: AttachedPlanes, plane: RunPlane, grid: mask.Grid) -> AttachedPlanes {
    let cel = active_cel(out.cels, plane.frame, plane.layer);
    let marks = value.items(value.get(cel.fields, "marks"));
    if cel.id == "" || cel.run_plane != 0 || length(marks) != length(plane.marks) {
        return AttachedPlanes { ..out, issue: "Packed pixel runs do not match the authored cel" };
    }
    let valid = repeat_until(length(marks), true, fn(ok) => !ok, fn(i) => fn(ok) =>
        paint.valid_run_marker(grid, marks.at_or(i, json.null()), plane.marks.at_or(i, [])));
    if !valid { return AttachedPlanes { ..out, issue: "Packed pixel runs do not match the authored cel" }; }
    let ordinal = out.ordinal + 1;
    let cels = out.cels.map(fn(row) => if row.id == cel.id { Cel { ..row, run_plane: ordinal } } else { row });
    return AttachedPlanes { cels: cels, ordinal: ordinal, issue: "" };
}

fn attach_run_planes(art: Artwork, planes: List<RunPlane>) -> Result<Artwork, String> {
    if length(planes) == 0 { return Ok(art); }
    let start = AttachedPlanes { cels: art.cels, ordinal: 0, issue: "" };
    let bound = fold_until(planes, start, fn(plane) => fn(out) => out.issue != "",
        fn(plane) => fn(out) => if out.issue != "" { out } else { attach_run_plane(out, plane, art.grid) });
    if bound.issue != "" { return Err(bound.issue); }
    return Ok(Artwork { ..art, cels: bound.cels, run_planes: planes.map(fn(plane) => plane.marks) });
}

fn run_owners(art: Artwork) -> List<SlotOwner> {
    return art.cels.filter(fn(cel) => cel.run_plane != 0).map(fn(cel) =>
        SlotOwner { frame: cel.frame, layer: cel.layer, plane: cel.run_plane });
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

fn compile(document: json.Json, planes: List<SlotPlane>, runs: List<RunPlane>, frame: String, layer: String,
    cel: String) -> Result<Raster, String> {
    let slots = attach_planes(prepare(document), planes)?;
    let art = attach_run_planes(slots, runs)?;
    let scope = resolve(art, optional_scope(frame), optional_scope(layer), optional_scope(cel))?;
    return raster(art, scope);
}

fn can_paint(view: PaintView, protected: List<u32>, p: u32) -> Bool {
    return !view.pixels.at_or(p, blank()).locked && !mask.selected(protected, p) &&
        view.captured.clipping.at_or(p, 255) != 0;
}
