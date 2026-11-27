module StudioPixelCanvasEdit;

import "std:json" as json;
import "pixel_canvas.ink" as canvas;
import "pixel_drawing_grid.ink" as drawing;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_png_import.ink" as colors;
import "pixel_values.ink" as value;

record Target { data: json.Json, sx: f64, sy: f64, }
record Edited { source: json.Json, positions: List<List<u32>>, slots: List<frame.SlotPlane>, runs: List<frame.RunPlane>,
    target: Target, changed: Bool, }
record Built { rows: List<json.Json>, slots: List<frame.SlotPlane>, runs: List<frame.RunPlane>, }
record Cel { row: json.Member, slots: frame.SlotPlane, runs: frame.RunPlane, }
record Frame { row: json.Json, slots: List<frame.SlotPlane>, runs: List<frame.RunPlane>, }
record Region { pixels: List<u32>, discarded: u32, }
record Registers { x: List<List<u32>>, y: List<List<u32>>, }
record Hard { input: u32, outputs: List<u32>, }
record Detail { row: json.Json, mapped: List<u32>, dropped: u32, hard: List<Hard>, first: u32, last: u32, }
record Choices { source: Map<u32, u32>, issue: String, }
record Rect { x: u32, y: u32, w: u32, h: u32, }

fn number(n: u32) -> json.Json { return json.number(frame.decimal(n)); }
fn signed(n: i32) -> json.Json {
    return json.number(if n < 0 { string_concat("-", frame.decimal(drawing.unsigned(0 - n))) }
        else { frame.decimal(drawing.unsigned(n)) });
}

fn half_number(n: f64) -> json.Json {
    let halves = i32_from_f64(floor(n * 2.0f64 + 0.5f64)).fold(fn(v) => v, fn(unit) => 0);
    let count = drawing.unsigned(if halves < 0 { 0 - halves } else { halves });
    let stem = frame.decimal(quot_or(count, 2, 0));
    let text = if rem_or(count, 2, 0) == 0 { stem } else { string_concat(stem, ".5") };
    return json.number(if halves < 0 { string_concat("-", text) } else { text });
}

fn grid_json(g: mask.Grid) -> json.Json { return json.array([number(g.width), number(g.height)]); }

fn coords(g: mask.Grid, p: u32) -> json.Json {
    return json.array([number(rem_or(p, g.width, 0)), number(quot_or(p, g.width, 0))]);
}

fn coordinates(g: mask.Grid, p: u32) -> String {
    return string_concat(frame.decimal(rem_or(p, g.width, 0)),
        string_concat(", ", frame.decimal(quot_or(p, g.width, 0))));
}

fn extent(source: List<json.Member>, art: frame.Artwork, details: List<paint.Detail>) -> Result<canvas.Bounds, String> {
    let initial: Result<canvas.Bounds, String> = Ok(canvas.empty_bounds(art.grid));
    let painted = foldl(art.frames.map_indexed(fn(i) => fn(id) => i), initial, fn(i) => fn(out) =>
        frame_extent(art, i, paint.active_details(details, i), out))?;
    return Ok(foldl(value.items(value.get(source, "slices")), painted, fn(row) => fn(out) =>
        foldl(value.items(value.get(value.fields(row), "keys")), out, fn(key) => fn(bounds) => slice_extent(key, bounds))));
}

fn slice_extent(key: json.Json, bounds: canvas.Bounds) -> canvas.Bounds {
    let rectangle = bounds_rect(value.get(value.fields(key), "bounds"));
    if rectangle.w == 0 || rectangle.h == 0 || rectangle.w > 512 || rectangle.h > 512 { return bounds; }
    return canvas.include(canvas.include(bounds, rectangle.x, rectangle.y),
        rectangle.x + rectangle.w - 1, rectangle.y + rectangle.h - 1);
}

fn frame_extent(art: frame.Artwork, i: u32, details: List<paint.Detail>, progress: Result<canvas.Bounds, String>)
    -> Result<canvas.Bounds, String> {
    let prior = progress?;
    let id = art.frames.at_or(i, "");
    let image = frame.preview_view(art, id, false)?;
    let locks = paint.locked_pixels(art.grid, details);
    return Ok(repeat_until(mask.size(art.grid), prior, fn(out) => false, fn(p) => fn(out) =>
        extent_pixel(art.grid, image.pixels.at_or(p, frame.blank()), mask.selected(locks, p), p, out)));
}

fn extent_pixel(g: mask.Grid, cell: frame.Pixel, locked: Bool, p: u32, out: canvas.Bounds) -> canvas.Bounds {
    if !locked && !cell.locked && (cell.slot < 0 || cell.alpha == 0) { return out; }
    return canvas.include(out, rem_or(p, g.width, 0), quot_or(p, g.width, 0));
}

fn source_axis(p: u32, offset: i32, scale: f64) -> i32 {
    return i32_from_f64(floor(f64_from_i32(offset) + (f64_from_u32(p) + 0.5f64) * scale)).fold(fn(n) => n, fn(unit) => -1);
}

fn register_axis(before: u32, after: u32, offset: i32, scale: f64) -> List<List<u32>> {
    let bins: Buffer<List<u32>> = buffer_fill(before, []);
    let mapped = repeat_until(after, bins, fn(out) => false, fn(p) => fn(out) =>
        register_point(source_axis(p, offset, scale), p, out));
    return mapped.freeze();
}

fn register_point(old: i32, next: u32, out: Buffer<List<u32>>) -> Buffer<List<u32>> {
    let index = drawing.unsigned(old);
    if old < 0 || index >= out.len() { return out; }
    let found = out.at_or(index, []).concat([next]);
    return out.set(index, found);
}

fn registers(map: canvas.Canvas) -> Registers {
    return Registers { x: register_axis(map.before.width, map.grid.width, map.offset.x, map.sx),
        y: register_axis(map.before.height, map.grid.height, map.offset.y, map.sy) };
}

fn points(map: canvas.Canvas, pixels: List<u32>, guide: Registers) -> Region {
    if length(pixels) == 0 { return Region { pixels: [], discarded: 0 }; }
    let membership = foldl(pixels, mask.blank(map.before), fn(p) => fn(out) => mask.mark(out, p)).freeze();
    let output: Buffer<u32> = Buffer.empty();
    let chosen = foldl(map.index.map_indexed(fn(p) => fn(src) => if src >= 0 && mask.selected(membership, drawing.unsigned(src)) { p } else { 4294967295 }),
        output, fn(p) => fn(out) => if p == 4294967295 { out } else { out.push(p) });
    let removed = length(pixels.filter(fn(p) => length(guide.x.at_or(rem_or(p, map.before.width, 0), [])) == 0 ||
        length(guide.y.at_or(quot_or(p, map.before.width, 0), [])) == 0));
    return Region { pixels: chosen.freeze(), discarded: removed };
}

fn hard_point(map: canvas.Canvas, slots: Registers, p: u32) -> Hard {
    let x = rem_or(p, map.before.width, 0);
    let y = quot_or(p, map.before.width, 0);
    let gx = slots.x.at_or(x, []);
    let gy = slots.y.at_or(y, []);
    if length(gx) != 0 && length(gy) != 0 {
        let empty: List<u32> = [];
        let outputs = foldl(gy, empty, fn(row) => fn(out) => out.concat(gx.map(fn(col) => row * map.grid.width + col)));
        return Hard { input: p, outputs: outputs };
    }
    let u = floor((f64_from_u32(x) + 0.5f64 - f64_from_i32(map.offset.x)) / map.sx);
    let v = floor((f64_from_u32(y) + 0.5f64 - f64_from_i32(map.offset.y)) / map.sy);
    if u < 0.0f64 || v < 0.0f64 || u >= f64_from_u32(map.grid.width) || v >= f64_from_u32(map.grid.height) {
        return Hard { input: p, outputs: [] };
    }
    return Hard { input: p, outputs: [value.as_word(v) * map.grid.width + value.as_word(u)] };
}

fn detail(map: canvas.Canvas, slots: Registers, authored: json.Json, raw: paint.Detail) -> Result<Detail, String> {
    let row = value.fields(authored);
    if raw.kind == "" {
        let output = points(map, raw.sites, slots);
        return Ok(Detail { row: rewritten_detail(row, map.grid, output.pixels), mapped: output.pixels,
            dropped: output.discarded, hard: [], first: raw.first, last: raw.last });
    }
    let hard = raw.sites.map(fn(p) => hard_point(map, slots, p));
    let lost = hard.filter(fn(p) => length(p.outputs) == 0);
    if length(lost) != 0 {
        let p = lost.at_or(0, Hard { input: 0, outputs: [] });
        return Err(string_concat("Canvas transform would discard protected detail ", string_concat(raw.id,
            string_concat(" at ", coordinates(map.before, p.input)))));
    }
    let selected = foldl(hard, mask.blank(map.grid), fn(p) => fn(out) =>
        foldl(p.outputs, out, fn(q) => fn(found) => mask.mark(found, q))).freeze();
    let sites = mask.indices(selected);
    return Ok(Detail { row: rewritten_detail(row, map.grid, sites), mapped: sites, dropped: 0,
        hard: hard, first: raw.first, last: raw.last });
}

fn rewritten_detail(row: List<json.Member>, g: mask.Grid, sites: List<u32>) -> json.Json {
    return json.object(paint.replace(row, "pixels", json.array(sites.map(fn(p) => coords(g, p)))));
}

fn details(map: canvas.Canvas, slots: Registers, raw: List<json.Json>, rules: List<paint.Detail>) -> Result<List<Detail>, String> {
    let initial: Result<List<Detail>, String> = Ok([]);
    let all = raw.map_indexed(fn(i) => fn(row) => detail(map, slots, row, rules.at_or(i, empty_detail())));
    return foldl(all, initial, fn(row) => fn(progress) => keep_detail(row, progress));
}

fn empty_detail() -> paint.Detail { return paint.Detail { id: "", kind: "", frame_id: "", first: 0, last: 0, sites: [] }; }

fn keep_detail(item: Result<Detail, String>, progress: Result<List<Detail>, String>) -> Result<List<Detail>, String> {
    let prior = progress?;
    let row = item?;
    return Ok(prior.concat([row]));
}

fn same_pigment(a: frame.Pixel, b: frame.Pixel) -> Bool {
    if a.alpha == 0 && b.alpha == 0 { return true; }
    return a.slot == b.slot && a.alpha == b.alpha && a.color == b.color;
}

fn pin(g: mask.Grid, pixels: List<frame.Pixel>, p: u32, src: u32, out: Choices) -> Choices {
    if out.issue != "" { return out; }
    let old = out.source.get_or(p, 4294967295);
    if old != 4294967295 && !same_pigment(pixels.at_or(old, frame.blank()), pixels.at_or(src, frame.blank())) {
        return Choices { ..out, issue: string_concat("Canvas transform would combine different protected pixels at ", coordinates(g, p)) };
    }
    return Choices { ..out, source: out.source.set(p, src) };
}

fn pins(g: mask.Grid, pixels: List<frame.Pixel>, rules: List<Detail>, i: u32) -> Result<List<i32>, String> {
    let active = rules.filter(fn(row) => row.first <= i && i <= row.last && length(row.hard) != 0);
    if length(active) == 0 { return Ok([]); }
    let initial = Choices { source: Map.empty(), issue: "" };
    let chosen = foldl(active, initial, fn(row) => fn(out) => foldl(row.hard, out, fn(site) => fn(res) =>
        foldl(site.outputs, res, fn(p) => fn(acc) => pin(g, pixels, p, site.input, acc))));
    if chosen.issue != "" { return Err(chosen.issue); }
    let blank: Buffer<i32> = buffer_fill(mask.size(g), -1);
    let complete = foldl(chosen.source.keys(), blank, fn(p) => fn(out) =>
        out.set(p, drawing.signed(chosen.source.get_or(p, 0))));
    return Ok(complete.freeze());
}

fn opacity_mark(mark: colors.Mark) -> json.Json {
    let style = if mark.alpha == 255 { paint.member("swatch", json.null()) } else { paint.member("alpha", number(mark.alpha)) };
    return json.object([style, paint.member("runs", json.array([]))]);
}

fn cel_planes(plan: canvas.Sampling, kept: List<i32>, raw: frame.Captured, id: String, row: json.Member) -> Cel {
    let image = canvas.raster(plan, raw, kept);
    let removed = image.slots.map_indexed(fn(i) => fn(slot) => if slot == -2 { i } else { 4294967295 })
        .filter(fn(i) => i != 4294967295);
    let packed = colors.packed_marks(plan.canvas.grid.width, image.slots, image.alpha, removed);
    let marks = packed.marks.filter(fn(mark) => mark.alpha == 255).concat(packed.marks.filter(fn(mark) => mark.alpha != 255));
    let spec = value.fields(row.value).filter(fn(item) => item.key != "hold" && item.key != "offset");
    let cells = paint.replace(paint.replace(spec, "slots", json.array([])), "marks", json.array(marks.map(fn(mark) => opacity_mark(mark))));
    return Cel { row: paint.member(row.key, json.object(cells)), slots: frame.SlotPlane { frame: id, layer: row.key,
        pixels: image.slots.map(fn(slot) => if slot < 0 { -1 } else { slot }) },
        runs: frame.RunPlane { frame: id, layer: row.key, marks: marks.map(fn(mark) => packed.spans.drop(mark.first).take(mark.length)) } };
}

fn raw_layer(art: frame.Artwork, layers: List<frame.RawLayer>, name: String) -> frame.Captured {
    let ordinal = frame.clip_index(art.layers, name, length(art.layers)) + 1;
    return foldl(layers, frame.no_capture(), fn(row) => fn(found) => if row.owner == ordinal { row.view } else { found });
}

fn update_frame(plan: canvas.Sampling, art: frame.Artwork, raw: json.Json, rules: List<Detail>, i: u32) -> Result<Frame, String> {
    let fields = value.fields(raw);
    let id = value.text(value.get(fields, "id"));
    let capture = frame.export_view(art, frame.Scope { frame: id, layer: "" }, true, true)?;
    let kept = pins(plan.canvas.grid, capture.pixels, rules, i)?;
    let edited = value.fields(value.get(fields, "cels")).map(fn(row) =>
        cel_planes(plan, kept, raw_layer(art, capture.sources, row.key), id, row));
    return Ok(Frame { row: json.object(paint.replace(fields, "cels", json.object(edited.map(fn(cel) => cel.row)))),
        slots: edited.map(fn(cel) => cel.slots), runs: edited.filter(fn(cel) => length(cel.runs.marks) != 0).map(fn(cel) => cel.runs) });
}

fn build_frames(plan: canvas.Sampling, art: frame.Artwork, source: List<json.Member>, rules: List<Detail>) -> Result<Built, String> {
    let initial: Result<Built, String> = Ok(Built { rows: [], slots: [], runs: [] });
    let list = value.items(value.get(source, "frames")).map_indexed(fn(i) => fn(row) => update_frame(plan, art, row, rules, i));
    return foldl(list, initial, fn(row) => fn(out) => append_frame(out, row));
}

fn append_frame(progress: Result<Built, String>, frame_result: Result<Frame, String>) -> Result<Built, String> {
    let old = progress?;
    let next = frame_result?;
    return Ok(Built { rows: old.rows.concat([next.row]), slots: old.slots.concat(next.slots), runs: old.runs.concat(next.runs) });
}

fn bounds_rect(raw: json.Json) -> Rect {
    let values = value.items(raw);
    return Rect { x: canvas.read_word(values, 0, 512), y: canvas.read_word(values, 1, 512),
        w: canvas.read_word(values, 2, 512), h: canvas.read_word(values, 3, 512) };
}

fn axis(grid: mask.Grid, i: u32) -> u32 { return if i == 0 { grid.width } else { grid.height }; }
fn offset(map: canvas.Canvas, i: u32) -> f64 { return f64_from_i32(if i == 0 { map.offset.x } else { map.offset.y }); }
fn scale(map: canvas.Canvas, i: u32) -> f64 { return if i == 0 { map.sx } else { map.sy }; }
fn center(map: canvas.Canvas, n: f64, i: u32) -> f64 {
    return (n + 0.5f64 - offset(map, i)) / scale(map, i) - 0.5f64;
}

fn guide(map: canvas.Canvas, raw: json.Json) -> json.Json {
    let row = value.fields(raw);
    let kind = value.text(value.get(row, "kind"));
    let at = value.get(row, "at");
    if kind == "axis" {
        let i: u32 = if value.text(value.get(row, "axis")) == "y" { 1 } else { 0 };
        return json.object(paint.replace(row, "at", half_number(center(map, value.number(at), i))));
    }
    if kind == "grid" {
        let origin = value.items(at).map_indexed(fn(i) => fn(n) =>
            half_number(floor((value.number(n) - offset(map, i)) / scale(map, i) + 0.5f64)));
        let spacing = value.items(value.get(row, "step")).map_indexed(fn(i) => fn(n) =>
            half_number(value.min(8192.0f64, value.max(1.0f64, floor(value.number(n) / scale(map, i) + 0.5f64)))));
        return json.object(paint.replace(paint.replace(row, "at", json.array(origin)), "step", json.array(spacing)));
    }
    return json.object(paint.replace(row, "at", json.array(value.items(at).map_indexed(fn(i) => fn(p) =>
        half_number(center(map, value.number(p), i))))));
}

fn edge(map: canvas.Canvas, n: u32, i: u32, upper: Bool) -> u32 {
    let p = (f64_from_u32(n) - offset(map, i)) / scale(map, i);
    let rounded = if upper { ceil(p - 0.000000001f64) } else { floor(p + 0.000000001f64) };
    return value.as_word(value.max(0.0f64, value.min(f64_from_u32(axis(map.grid, i)), rounded)));
}

fn rectangle(map: canvas.Canvas, raw: Rect) -> Rect {
    let x = edge(map, raw.x, 0, false);
    let y = edge(map, raw.y, 1, false);
    return Rect { x: x, y: y, w: edge(map, raw.x + raw.w, 0, true) - x,
        h: edge(map, raw.y + raw.h, 1, true) - y };
}

fn rect_array(row: Rect) -> json.Json { return json.array([number(row.x), number(row.y), number(row.w), number(row.h)]); }

fn slice_error(name: String, raw: List<json.Member>, stretch: Bool) -> String {
    let lead = if stretch { "Canvas edit would remove the stretch area of slice " } else { "Canvas edit would remove slice " };
    return string_concat(lead, string_concat(name, string_concat(" on frame ", value.text(value.get(raw, "frame")))));
}

fn slice_key(map: canvas.Canvas, raw: json.Json, name: String) -> Result<json.Json, String> {
    let row = value.fields(raw);
    let raw_bounds = value.get(row, "bounds");
    if raw_bounds == json.null() { return Ok(raw); }
    let before = bounds_rect(raw_bounds);
    let next = rectangle(map, before);
    if next.w == 0 || next.h == 0 { return Err(slice_error(name, row, false)); }
    let changed = paint.replace(row, "bounds", rect_array(next));
    let pivot = value.items(value.get(row, "pivot"));
    let result = if length(pivot) != 0 {
        paint.replace(changed, "pivot", json.array(pivot.map_indexed(fn(i) => fn(p) => pivot_location(map, before, next, i, p))))
    } else { changed };
    let stretch = value.items(value.get(row, "nineSlice"));
    if length(stretch) == 0 { return Ok(json.object(result)); }
    return slice_stretch(map, row, result, name, before, next, stretch);
}

fn pivot_location(map: canvas.Canvas, before: Rect, next: Rect, i: u32, p: json.Json) -> json.Json {
    let old = if i == 0 { before.x } else { before.y };
    let moved = if i == 0 { next.x } else { next.y };
    return half_number(center(map, value.number(p) + f64_from_u32(old), i) - f64_from_u32(moved));
}

fn slice_stretch(map: canvas.Canvas, raw: List<json.Member>, result: List<json.Member>, name: String,
    before: Rect, next: Rect, stretch: List<json.Json>) -> Result<json.Json, String> {
    let a = canvas.read_word(stretch, 0, 512);
    let b = canvas.read_word(stretch, 1, 512);
    let inside = rectangle(map, Rect { x: before.x + a, y: before.y + b, w: before.w - a - canvas.read_word(stretch, 2, 512),
        h: before.h - b - canvas.read_word(stretch, 3, 512) });
    if inside.w == 0 || inside.h == 0 { return Err(slice_error(name, raw, true)); }
    let values = [number(inside.x - next.x), number(inside.y - next.y),
        number(next.x + next.w - inside.x - inside.w), number(next.y + next.h - inside.y - inside.h)];
    return Ok(json.object(paint.replace(result, "nineSlice", json.array(values))));
}

fn collect(raw: List<Result<json.Json, String>>) -> Result<List<json.Json>, String> {
    let initial: Result<List<json.Json>, String> = Ok([]);
    return foldl(raw, initial, fn(row) => fn(out) => add_row(row, out));
}

fn add_row(raw: Result<json.Json, String>, progress: Result<List<json.Json>, String>) -> Result<List<json.Json>, String> {
    let out = progress?;
    let row = raw?;
    return Ok(out.concat([row]));
}

fn transform_slice(map: canvas.Canvas, raw: json.Json) -> Result<json.Json, String> {
    let row = value.fields(raw);
    let name = value.text(value.get(row, "id"));
    let keys = collect(value.items(value.get(row, "keys")).map(fn(key) => slice_key(map, key, name)))?;
    return Ok(json.object(paint.replace(row, "keys", json.array(keys))));
}

fn source_positions(map: canvas.Canvas, raw: json.Json, saved: List<u32>) -> List<u32> {
    if length(saved) != 0 { return saved; }
    return value.items(value.get(value.fields(raw), "pixels")).map(fn(p) => paint.site(map.before, p));
}

fn named_positions(map: canvas.Canvas, inverse: Registers, rows: List<json.Json>, stored: List<List<u32>>) -> List<List<u32>> {
    return rows.map_indexed(fn(i) => fn(row) => points(map, source_positions(map, row, stored.at_or(i, [])), inverse).pixels);
}

fn optional_rows(fields: List<json.Member>, key: String, rows: List<json.Json>) -> List<json.Member> {
    return if value.has(fields, key) { paint.replace(fields, key, json.array(rows)) } else { fields };
}

fn remapped_metadata(map: canvas.Canvas, source: List<json.Member>, layers: List<json.Json>, rows: List<json.Json>, routed: List<Detail>)
    -> Result<List<json.Member>, String> {
    if value.has(source, "directional") {
        if map.sx != map.sy { return Err("Directional view registration needs uniform canvas resampling"); }
        return Err("Canvas edits for directional views are not implemented");
    }
    let sized = paint.replace(paint.replace(source, "width", number(map.grid.width)), "height", number(map.grid.height));
    let base = paint.replace(paint.replace(sized, "layers", json.array(layers)), "frames", json.array(rows));
    let guides = value.items(value.get(source, "guides")).map(fn(row) => guide(map, row));
    let slices = collect(value.items(value.get(source, "slices")).map(fn(row) => transform_slice(map, row)))?;
    let selections = value.items(value.get(source, "selections")).map(fn(row) => rewritten_detail(value.fields(row), map.grid, []));
    return Ok(optional_rows(optional_rows(optional_rows(optional_rows(base, "guides", guides), "slices", slices),
        "selections", selections), "protectedDetails", routed.map(fn(row) => row.row)));
}

fn reframe_binding(map: canvas.Canvas, inverse: Registers, raw: json.Json) -> json.Json {
    let fields = value.fields(raw);
    let stale = stale_sites(map.before, value.items(value.get(fields, "stale")));
    let mapped = points(map, stale, inverse);
    let unbound = fields.filter(fn(row) => row.key != "canvas" && row.key != "stale");
    if length(mapped.pixels) == 0 { return json.object(unbound); }
    let spans = paint.runs(map.grid, mapped.pixels).map(fn(span) => json.array([number(span.x), number(span.y), number(span.z)]));
    return json.object(paint.replace(unbound, "stale", json.array(spans)));
}

fn stale_sites(g: mask.Grid, rows: List<json.Json>) -> List<u32> {
    let blank: List<u32> = [];
    return foldl(rows, blank, fn(row) => fn(out) => out.concat(stale_run(g, value.items(row))));
}

fn stale_run(g: mask.Grid, fields: List<json.Json>) -> List<u32> {
    let y = canvas.read_word(fields, 0, g.height - 1);
    let x = canvas.read_word(fields, 1, g.width - 1);
    let n = canvas.read_word(fields, 2, g.width);
    if x >= g.width || y >= g.height || n > g.width - x { return []; }
    let empty: Buffer<u32> = Buffer.empty();
    return repeat_until(n, empty, fn(out) => false, fn(i) => fn(out) => out.push(y * g.width + x + i)).freeze();
}

fn registration(map: canvas.Canvas, before: json.Json) -> Result<json.Json, String> {
    let fields = value.fields(before);
    let prior_scale = if before == json.null() { json.array([number(1), number(1)]) } else { value.get(fields, "scale") };
    let prior_offset = value.items(value.get(fields, "offset"));
    let size = if before == json.null() { grid_json(map.before) } else { value.get(fields, "size") };
    let old_scale = value.items(prior_scale);
    if map.sx != 1.0f64 || map.sy != 1.0f64 || value.number(old_scale.at_or(0, number(1))) != 1.0f64
        || value.number(old_scale.at_or(1, number(1))) != 1.0f64 {
        if !canvas.changed(map) { return Ok(before); }
        return Err("Resampled canvas registrations are not implemented");
    }
    let x = value.number(prior_offset.at_or(0, number(0))) + offset(map, 0);
    let y = value.number(prior_offset.at_or(1, number(0))) + offset(map, 1);
    if x == 0.0f64 && y == 0.0f64 && size == grid_json(map.grid) { return Ok(json.null()); }
    if x == 0.5f64 * floor(x * 2.0f64) && y == 0.5f64 * floor(y * 2.0f64)
        && x >= -1000000.0f64 && x <= 1000000.0f64 && y >= -1000000.0f64 && y <= 1000000.0f64 {
        return Ok(json.object([paint.member("size", size),
            paint.member("offset", json.array([half_number(x), half_number(y)])), paint.member("scale", prior_scale)]));
    }
    if !canvas.changed(map) { return Ok(before); }
    return Err("Canvas registrations with fractional offsets are not implemented");
}

record Bindings { rows: List<json.Json>, reports: List<json.Json>, }

fn bindings(map: canvas.Canvas, inverse: Registers, rows: List<json.Json>, policy: String) -> Result<Bindings, String> {
    let initial: Result<Bindings, String> = Ok(Bindings { rows: [], reports: [] });
    return foldl(rows, initial, fn(row) => fn(out) => bind(map, inverse, row, policy, out));
}

fn bind(map: canvas.Canvas, inverse: Registers, raw: json.Json, policy: String, progress: Result<Bindings, String>) -> Result<Bindings, String> {
    let old = progress?;
    let row = value.fields(raw);
    let before = value.get(row, "canvas");
    let requested = if policy == "preserve" { registration(map, before) } else { Ok(json.null()) };
    let after = requested?;
    let reframed = if canvas.changed(map) { reframe_binding(map, inverse, raw) }
        else { json.object(row.filter(fn(item) => item.key != "canvas")) };
    let final = if after == json.null() { reframed } else { json.object(paint.replace(value.fields(reframed), "canvas", after)) };
    let report = json.object([paint.member("id", value.get(row, "id")), paint.member("policy", json.text(policy)),
        paint.member("before", before), paint.member("after", after)]);
    return Ok(Bindings { rows: old.rows.concat([final]), reports: old.reports.concat([report]) });
}

fn dropped_details(rows: List<Detail>) -> List<json.Json> {
    return rows.filter(fn(row) => row.dropped != 0).map(fn(row) => json.object([
        paint.member("id", value.get(value.fields(row.row), "id")), paint.member("pixels", number(row.dropped))]));
}

fn report(map: canvas.Canvas, tool: String, bound: Bindings, rows: List<Detail>, before: List<json.Member>, after: List<json.Member>) -> Target {
    let main = [paint.member("destination", json.text("canvas")), paint.member("kind", json.text("canvas")),
        paint.member("tool", json.text(tool)), paint.member("beforeGrid", grid_json(map.before)),
        paint.member("grid", grid_json(map.grid)), paint.member("offset", json.array([signed(map.offset.x), signed(map.offset.y)])),
        paint.member("filter", json.text(map.filter)), paint.member("bindings", json.array(bound.reports)),
        paint.member("droppedProtected", json.array(dropped_details(rows)))];
    let slices = value.get(before, "slices");
    let extra: List<json.Member> = if canvas.changed(map) && length(value.items(slices)) != 0 {
        [paint.member("slices", json.object([paint.member("before", slices), paint.member("after", value.get(after, "slices"))]))]
    } else { [] };
    return Target { data: json.object(main.concat(extra)), sx: map.sx, sy: map.sy };
}

fn apply(source: json.Json, art: frame.Artwork, stored: List<List<u32>>, raw: json.Json, scoped: Bool) -> Result<Edited, String> {
    if scoped { return Err("A canvas edit applies to the whole document"); }
    let params = canvas.members(raw)?;
    let before = value.fields(paint.snapshot(source, art).source);
    let registered = value.items(value.get(before, "sceneBindings"));
    let policy = value.text(value.get(params, "bindingPolicy"));
    if value.has(params, "bindingPolicy") && policy != "preserve" && policy != "reframe" {
        return Err("Choose preserve or reframe for canvas bindings");
    }
    if length(registered) != 0 && policy == "" { return Err("Use bindingPolicy preserve or reframe for a bound canvas"); }
    let rules = paint.protections(source, art)?;
    let tool = value.text(value.get(params, "type"));
    let limits = if tool == "trim" { extent(before, art, rules) } else { Ok(canvas.empty_bounds(art.grid)) };
    let bounds = limits?;
    let map = canvas.plan(art.grid, params.filter(fn(row) => row.key != "bindingPolicy"), bounds)?;
    return apply_plan(map, before, art, stored, rules, policy, tool);
}

fn apply_plan(map: canvas.Canvas, before: List<json.Member>, art: frame.Artwork, stored: List<List<u32>>,
    rules: List<paint.Detail>, policy: String, tool: String) -> Result<Edited, String> {
    let inverse = registers(map);
    let bound = bindings(map, inverse, value.items(value.get(before, "sceneBindings")), policy)?;
    if !canvas.changed(map) {
        let after = optional_rows(before, "sceneBindings", bound.rows);
        let data = report(map, tool, bound, [], before, after);
        return Ok(Edited { source: json.object(after), positions: stored, slots: [], runs: [], target: data, changed: false });
    }
    let rows = details(map, inverse, value.items(value.get(before, "protectedDetails")), rules)?;
    let ready = build_frames(canvas.sampling(map), art, before, rows)?;
    let layers = value.items(value.get(before, "layers")).map(fn(row) =>
        json.object(value.fields(row).filter(fn(field) => field.key != "offset")));
    let revised = remapped_metadata(map, before, layers, ready.rows, rows)?;
    let after = optional_rows(revised, "sceneBindings", bound.rows);
    let data = report(map, tool, bound, rows, before, after);
    let positions = named_positions(map, inverse, value.items(value.get(before, "selections")), stored);
    return Ok(Edited { source: json.object(after), positions: positions, slots: ready.slots, runs: ready.runs,
        target: data, changed: true });
}
