module StudioPixelPaint;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_motion.ink" as motion;
import "pixel_brush_paint.ink" as brush_paint;
import "pixel_drawing_grid.ink" as drawing;
import "pixel_frame.ink" as frame;
import "pixel_fault.ink" as fault;
import "pixel_mask.ink" as mask;
import "pixel_raster.ink" as raster;
import "pixel_rgba_edit.ink" as rgba;
import "pixel_selection.ink" as selection;
import "pixel_shapes.ink" as shape;
import "pixel_values.ink" as value;
import "pixel_transform.ink" as transforms;

record Tool { kind: String, slot: i32, perfect: Bool, selection: Option<String>,
    drawing: drawing.Drawing, points: List<drawing.Point>, geometry: json.Json,
    saved_brush: json.Json, samples: Option<json.Json>, shading: Option<json.Json>, }
record Constraint { limited: Bool, words: List<u32>, }
record Guard { drawn: frame.PaintView, protected: List<u32>, selected: Constraint, }
record CachedView { scope: frame.Scope, view: frame.PaintView, }
record EditContext { guard: Guard, details: List<Detail>, active: List<Detail>, }
record RgbaInput { pixels: List<u32>, names: List<String>, }
record Stroke { words: Buffer<u32>, previous: drawing.Point, tip: drawing.Point, blocked: u32, }
record Segment { pen: drawing.Pen, stroke: Stroke, }
record Runs { spans: Buffer<Vec3<u32>>, y: u32, x: u32, length: u32, }
record Report { frame: String, layer: String, cel: String, tool: String, pixelCount: u32,
    runs: List<Vec3<u32>>, pixelPerfect: Bool, selection: Option<String>, shape: Option<String>, shading: Option<String>,
    ramp: Option<String>, addedSwatches: List<String>, from: Option<String>, to: Option<String>, transform: Option<TransformReport>, }
record TransformReport { mode: Option<String>, bounds: Vec4<i32>, clippedPixels: u32,
    resultSelection: Option<String>, selectionRuns: List<Vec3<u32>>, carriedProtection: List<CarriedReport>, }
record CarriedReport { id: String, kind: String, frame: String, pixels: List<Vec2<u32>>, }
record ResultMask { id: String, words: List<u32>, }
record Detail { id: String, kind: String, frame_id: String, first: u32, last: u32, sites: List<u32>, }
record Details { rows: Buffer<Detail>, issue: String, }
record Changes { sites: List<u32>, marks: List<raster.RunMark>, added: List<brush.Swatch>, shading: brush_paint.Shading, }
record Ranks { positions: Buffer<u32>, slots: Buffer<u32>, }
record Groups { marks: Buffer<raster.RunMark>, index: u32, spans: Runs, }
record Appended { fields: List<json.Member>, runs: List<raster.RunMark>, prepared: List<raster.RunMark>, plane: u32, }
record SavedCel { frame: String, layer: String, authored: json.Json, }
record SnapshotMark { swatch: Option<String>, knockout: Bool, alpha: Option<u32>, runs: List<Vec3<u32>>, point: Bool, }
record SnapshotCel { frame: String, layer: String, marks: List<SnapshotMark>, }
record RasterSnapshot { source: json.Json, edits: List<SnapshotCel>, }
record Edit { document: json.Json, artwork: frame.Artwork, report: Report,
    cache: CachedView, result_mask: Option<ResultMask>, }

fn decode(g: mask.Grid, ids: List<String>, items: List<json.Member>) -> Result<Tool, String> {
    let kind = value.text(value.get(items, "tool"));
    if value.has(items, "pixelPerfect") && (kind != "pencil" || !drawing.bool_field(items, "pixelPerfect")) {
        return Err("Pixel-perfect cleanup is a boolean pencil option");
    }
    let grid = drawing.drawing(g, items)?;
    return decode_points(grid, ids, kind, items);
}

fn decode_points(grid: drawing.Drawing, ids: List<String>, kind: String, items: List<json.Member>) -> Result<Tool, String> {
    let swatch = value.text(value.get(items, "swatch"));
    let slot: i32 = if kind == "eraser" { -1 } else { selection.find_swatch(ids, swatch) };
    let brushing = kind == "brush";
    let precise = kind == "shape";
    let has_swatch = value.has(items, "swatch");
    let allowed = brushing || precise || kind == "pencil" || kind == "fill" || kind == "eraser";
    if !allowed || (if kind == "eraser" { has_swatch } else { (!brushing || has_swatch) && slot < 0 }) {
        return Err("Paint tools need a known swatch or saved brush colors. Eraser clears the active layer.");
    }
    if value.has(items, "brush") != brushing { return Err("A brush operation needs a saved brush"); }
    let shade = value.get(items, "shading");
    let shading = json.lookup(items, "shading");
    if value.has(items, "shading") && (!brushing || has_swatch && value.text(value.get(value.fields(shade), "mode")) != "recolor") {
        return Err("Brush shading needs a saved tip. Only recolor accepts a swatch override.");
    }
    let at = value.has(items, "at");
    let has_points = value.has(items, "points");
    if if precise { at || has_points } else { value.has(items, "shape") } {
        return Err("Put shape geometry in the shape operation");
    }
    let sampled = value.has(items, "samples");
    if sampled && (!brushing || at || has_points) { return Err("Sampled brush motion replaces both at and points"); }
    let single = kind == "fill" || brushing && at;
    let decoded: Result<List<drawing.Point>, String> = if precise || sampled { Ok([]) } else { read_points(grid, single, items) };
    let points = decoded?;
    let selected: Option<String> = json.lookup(items, "selection").fold(fn(raw) => Some(value.text(raw)), fn(unit) => None);
    return Ok(Tool { kind: kind, slot: slot, perfect: value.flag(items, "pixelPerfect", false),
        selection: selected, drawing: grid, points: points, geometry: value.get(items, "shape"),
        saved_brush: value.get(items, "brush"), samples: json.lookup(items, "samples"), shading: shading });
}

fn read_points(grid: drawing.Drawing, single: Bool, items: List<json.Member>) -> Result<List<drawing.Point>, String> {
    let points = if single { [value.get(items, "at")] } else { value.items(value.get(items, "points")) };
    if (if single { value.has(items, "points") } else { value.has(items, "at") || length(points) == 0 || length(points) > 4096 }) {
        return Err("Fill needs a seed pixel. Brush accepts one position or a path. Pencil and eraser need a path.");
    }
    let decoded = points.map(fn(p) => drawing.point(p, grid));
    if length(decoded.filter(fn(p) => !drawing.inside(p, grid))) != 0 {
        return Err("A paint tool needs points inside the native grid or its wrapping neighbors");
    }
    return Ok(decoded);
}

fn selected(p: u32, limit: Constraint) -> Bool { return !limit.limited || mask.selected(limit.words, p); }

fn guard_fault(g: mask.Grid, guard: Guard, layer: String, p: u32) -> fault.Fault {
    return fault.blocked(g, guard.drawn, guard.protected, layer, p, "Paint tool cannot change this pixel");
}

fn writable(guard: Guard, p: u32) -> Bool {
    return frame.can_paint(guard.drawn, guard.protected, p);
}

fn emit(tool: Tool, guard: Guard, p: drawing.Point, old: Stroke) -> Stroke {
    let grid = tool.drawing;
    if grid.x.mirror == -2 && grid.y.mirror == -2 {
        let index = drawing.position(grid.grid, drawing.normalize(p.x, grid.x), drawing.normalize(p.y, grid.y));
        return plot(guard, tool.slot, index, old);
    }
    return foldl(drawing.copies(tool.drawing, p), old, fn(index) => fn(stroke) =>
        plot(guard, tool.slot, index, stroke));
}

fn plot(guard: Guard, slot: i32, p: u32, stroke: Stroke) -> Stroke {
    if stroke.blocked != 4294967295 || !selected(p, guard.selected) { return stroke; }
    if !writable(guard, p) { return Stroke { ..stroke, blocked: p }; }
    if guard.drawn.captured.slots.at_or(p, -1) == slot { return stroke; }
    return Stroke { ..stroke, words: mask.mark(stroke.words, p) };
}

fn corner(previous: drawing.Point, tip: drawing.Point, next: drawing.Point) -> Bool {
    if previous.x == -30000 { return false; }
    let x = tip.x - previous.x;
    let y = tip.y - previous.y;
    let u = next.x - tip.x;
    let v = next.y - tip.y;
    return (drawing.abs(x) == 1 && y == 0 && u == 0 && drawing.abs(v) == 1) ||
        (x == 0 && drawing.abs(y) == 1 && drawing.abs(u) == 1 && v == 0);
}

fn join_point(tool: Tool, guard: Guard, next: drawing.Point, stroke: Stroke) -> Stroke {
    if stroke.tip.x == -30000 { return Stroke { ..stroke, tip: next }; }
    let previous = stroke.tip;
    let pen = drawing.segment(previous, next);
    let start = Segment { pen: pen, stroke: stroke };
    let steps = drawing.steps(previous, next);
    return repeat_until(steps, start, fn(state) => state.stroke.blocked != 4294967295, fn(i) => fn(state) =>
        step_pen(tool, guard, state)).stroke;
}

fn step_pen(tool: Tool, guard: Guard, state: Segment) -> Segment {
    let pen = drawing.advance(state.pen);
    let next = pen.position;
    let stroke = state.stroke;
    let advanced = if tool.perfect && corner(stroke.previous, stroke.tip, next) { stroke }
        else { emit(tool, guard, stroke.tip, Stroke { ..stroke, previous: stroke.tip }) };
    return Segment { pen: pen, stroke: Stroke { ..advanced, tip: next } };
}

fn stroke(tool: Tool, guard: Guard, layer: String) -> Result<List<u32>, fault.Fault> {
    let init = Stroke { words: mask.blank(tool.drawing.grid), previous: drawing.absent(), tip: drawing.absent(), blocked: 4294967295 };
    let path = foldl(tool.points, init, fn(p) => fn(old) =>
        if old.blocked != 4294967295 { old } else { join_point(tool, guard, p, old) });
    let traced = emit(tool, guard, path.tip, path);
    if traced.blocked != 4294967295 { return Err(guard_fault(tool.drawing.grid, guard, layer, traced.blocked)); }
    return Ok(traced.words.freeze());
}

fn paint_mask(tool: Tool, guard: Guard, layer: String) -> Result<List<u32>, fault.Fault> {
    if tool.kind == "fill" { return fill(tool, guard, layer); }
    if tool.kind != "shape" { return stroke(tool, guard, layer); }
    let coverage = shape.coverage(tool.drawing, tool.geometry).map_err(fn(issue) => fault.invalid(issue))?;
    let init = Stroke { words: mask.blank(tool.drawing.grid), previous: drawing.absent(), tip: drawing.absent(), blocked: 4294967295 };
    let traced = foldl(mask.indices(coverage), init, fn(p) => fn(out) => plot(guard, tool.slot, p, out));
    if traced.blocked != 4294967295 { return Err(guard_fault(tool.drawing.grid, guard, layer, traced.blocked)); }
    return Ok(traced.words.freeze());
}

fn basic_changes(tool: Tool, guard: Guard, layer: String) -> Result<Changes, fault.Fault> {
    let changed = paint_mask(tool, guard, layer)?;
    let sites = mask.indices(changed);
    let marks: List<raster.RunMark> = if length(sites) == 0 { [] } else {
        [raster.RunMark { slot: tool.slot, alpha: None, spans: runs(tool.drawing.grid, sites), point: false }]
    };
    return Ok(Changes { sites: sites, marks: marks, added: [], shading: brush_paint.unshaded() });
}

fn brushed(source: json.Json, art: frame.Artwork, tool: Tool, guard: Guard, slots: List<i32>, layer: String) -> Result<Changes, fault.Fault> {
    let b = brush.decode(tool.saved_brush, slots).map_err(fn(issue) => fault.invalid(issue))?;
    let traced = tool.samples.fold(fn(raw) => motion.trace(tool.drawing, b, raw),
        fn(unit) => brush.static_path(tool.drawing, b, tool.points));
    let stamps = traced.map_err(fn(issue) => fault.invalid(issue))?;
    let parsed: Result<brush_paint.Shading, String> = tool.shading.fold(fn(raw) => brush_paint.read_shading(source, art.ids, raw),
        fn(unit) => Ok(brush_paint.unshaded()));
    let shade = parsed.map_err(fn(issue) => fault.invalid(issue))?;
    let aimed = stamps.filter(fn(row) => selected(row.pixel, guard.selected)).map(fn(row) =>
        brush_paint.shaded(row, guard.drawn.captured, shade)).filter(fn(row) => row.slot >= 0);
    let denied: u32 = foldl(aimed, 4294967295, fn(row) => fn(found) =>
        if found == 4294967295 && !writable(guard, row.pixel) { row.pixel } else { found });
    if denied != 4294967295 {
        return Err(guard_fault(art.grid, guard, layer, denied));
    }
    return brush_changes(art, tool.slot, b, shade, aimed, guard.drawn.captured).map_err(fn(issue) => fault.invalid(issue));
}

fn brush_changes(art: frame.Artwork, override: i32, b: brush.Brush, shade: brush_paint.Shading,
    aimed: List<brush.Stamp>, captured: frame.Captured) -> Result<Changes, String> {
    if shade.mode == "alpha" {
        let sites = aimed.map(fn(row) => row.pixel).sort();
        let marks: List<raster.RunMark> = if length(sites) == 0 { [] } else { [raster.RunMark { slot: -1, alpha: Some(shade.opacity), spans: runs(art.grid, sites), point: false }] };
        return Ok(Changes { sites: sites, marks: marks, added: [], shading: shade });
    }
    let empty = brush_paint.Colors { palette: [], slots: [], added: [], issue: "" };
    let resolved: Result<brush_paint.Colors, String> = if shade.mode == "ramp" { Ok(empty) }
        else { brush_paint.palette(art, b, aimed, override) };
    let palette = resolved?;
    let stamps = if shade.mode == "ramp" { aimed } else {
        aimed.map(fn(row) => brush.Stamp { ..row, slot: palette.slots.at_or(drawing.unsigned(row.slot), -1) })
    };
    let keys = stamps.filter(fn(row) => captured.slots.at_or(row.pixel, -1) != row.slot)
        .map(fn(row) => wrapping_shl(row.pixel, 9) + drawing.unsigned(row.slot + 2)).sort();
    let sites = keys.map(fn(key) => wrapping_shr(key, 9));
    let marks = grouped_marks(art.grid, keys, false);
    return Ok(Changes { sites: sites, marks: marks, added: palette.added, shading: shade });
}

fn rank_group(key: u32, old: Ranks) -> Ranks {
    let slot = word_and(key, 511);
    if old.positions.at_or(slot, 4294967295) != 4294967295 { return old; }
    let i = old.slots.len();
    return Ranks { slots: old.slots.push(slot), positions: old.positions.set(slot, i) };
}

fn grouped_marks(g: mask.Grid, keys: List<u32>, opacity: Bool) -> List<raster.RunMark> {
    if length(keys) == 0 { return []; }
    let seed = Ranks { positions: buffer_fill(257, 4294967295), slots: Buffer.empty() };
    let rank = foldl(keys, seed, fn(k) => fn(out) => rank_group(k, out));
    let positions = rank.positions.freeze();
    let slots = rank.slots.freeze();
    // Nine channel bits cover the full palette, a clear, and a knockout.
    let ordered = keys.map(fn(key) =>
        wrapping_shl(positions.at_or(word_and(key, 511), 0), 18) + wrapping_shr(key, 9)).sort();
    let init = Groups { marks: Buffer.empty(), index: 4294967295, spans: empty_runs() };
    let groups = foldl(ordered, init, fn(key) => fn(out) =>
        group_visit(g, slots, opacity, wrapping_shr(key, 18), word_and(key, 262143), out));
    return end_group(slots, opacity, groups).freeze();
}

fn end_group(slots: List<u32>, opacity: Bool, old: Groups) -> Buffer<raster.RunMark> {
    if old.index == 4294967295 { return old.marks; }
    let channel = slots.at_or(old.index, 0);
    let slot: i32 = if opacity { -1 } else { drawing.signed(channel) - 2 };
    return old.marks.push(raster.RunMark { slot: slot, alpha: if opacity { Some(channel) } else { None },
        spans: emit_span(old.spans).freeze(), point: false });
}

fn group_visit(g: mask.Grid, slots: List<u32>, opacity: Bool, i: u32, p: u32, old: Groups) -> Groups {
    if old.index == i { return Groups { ..old, spans: add_span(g, p, old.spans) }; }
    return Groups { index: i, marks: end_group(slots, opacity, old), spans: add_span(g, p, empty_runs()) };
}


fn fill(tool: Tool, guard: Guard, layer: String) -> Result<List<u32>, fault.Fault> {
    let seeds = drawing.copies(tool.drawing, tool.points.at_or(0, drawing.absent()));
    let denied: u32 = foldl(seeds, 4294967295, fn(p) => fn(found) =>
        if found == 4294967295 && selected(p, guard.selected) && !writable(guard, p) { p } else { found });
    let grid = tool.drawing.grid;
    if denied != 4294967295 { return Err(guard_fault(grid, guard, layer, denied)); }
    return Ok(foldl(seeds, mask.blank(grid).freeze(), fn(seed) => fn(old) => fill_seed(tool, guard, seed, old)));
}

fn fill_seed(tool: Tool, guard: Guard, seed: u32, old: List<u32>) -> List<u32> {
    let slot = guard.drawn.captured.slots.at_or(seed, -1);
    if slot == tool.slot || !selected(seed, guard.selected) || mask.selected(old, seed) { return old; }
    let grid = tool.drawing.grid;
    let candidates = repeat_until(mask.size(grid), mask.blank(grid), fn(out) => false, fn(p) => fn(out) =>
        if guard.drawn.captured.slots.at_or(p, -1) == slot && selected(p, guard.selected) && writable(guard, p) {
            mask.mark(out, p)
        } else { out }).freeze();
    let reached = mask.cluster_on_grid(grid, candidates, seed, mask.Wrap { x: tool.drawing.x.wrap, y: tool.drawing.y.wrap });
    return mask.merge(old, reached, "combine");
}

fn add_span(g: mask.Grid, p: u32, old: Runs) -> Runs {
    let x = rem_or(p, g.width, 0);
    let y = quot_or(p, g.width, 0);
    if old.length != 0 && old.y == y && old.x + old.length == x { return Runs { ..old, length: old.length + 1 }; }
    let spans = emit_span(old);
    return Runs { spans: spans, y: y, x: x, length: 1 };
}

fn emit_span(old: Runs) -> Buffer<Vec3<u32>> {
    return if old.length == 0 { old.spans } else { old.spans.push(vec3(old.y, old.x, old.length)) };
}

fn empty_runs() -> Runs { return Runs { spans: Buffer.empty(), y: 0, x: 0, length: 0 }; }

fn runs(g: mask.Grid, sites: List<u32>) -> List<Vec3<u32>> {
    let initial = empty_runs();
    let collected = foldl(sites, initial, fn(p) => fn(out) => add_span(g, p, out));
    return emit_span(collected).freeze();
}

fn find_layer(layers: List<frame.Layer>, id: String) -> frame.Layer {
    let index = frame.clip_index(layers, id, length(layers));
    return layers.at_or(index, frame.empty_layer());
}

fn locked_layer(layers: List<frame.Layer>, row: frame.Layer) -> Bool {
    if row.kind == "group" || row.kind == "reference" || row.locked { return true; }
    let owner = repeat_until(length(layers), row, fn(layer) => layer.parent == "" || layer.locked,
        fn(i) => fn(layer) => find_layer(layers, layer.parent));
    return owner.locked;
}

fn target(art: frame.Artwork, spec: List<json.Member>, frame_id: Option<String>, cel: Option<String>) -> Result<frame.Scope, fault.Fault> {
    let layer = value.text(value.get(spec, "layer"));
    let by_cel = cel.fold(fn(id) => true, fn(unit) => false);
    let invalid = "Choose an existing raster layer or cel for the paint tool";
    if (by_cel && value.has(spec, "layer")) || (!by_cel && layer == "") { return Err(fault.invalid(invalid)); }
    let scope = frame.resolve(art, frame_id, frame.optional_scope(layer), cel).map_err(fn(issue) => fault.invalid(issue))?;
    let row = find_layer(art.layers, scope.layer);
    if row.id == "" { return Err(fault.invalid(invalid)); }
    if locked_layer(art.layers, row) { return Err(fault.locked(row.id)); }
    return Ok(scope);
}

fn constraint(g: mask.Grid, named: selection.Named, active: String, id: Option<String>) -> Result<Constraint, String> {
    return id.fold(fn(name) => named_constraint(g, named, active, name),
        fn(unit) => Ok(Constraint { limited: false, words: [] }));
}

fn named_constraint(g: mask.Grid, named: selection.Named, active: String, id: String) -> Result<Constraint, String> {
    let picked = selection.recall_named(g, named, active, id);
    if picked.issue != "" { return Err(picked.issue); }
    return Ok(Constraint { limited: true, words: picked.mask });
}

fn detail_scope(items: List<json.Member>, frames: List<String>) -> Vec2<u32> {
    let invalid: Vec2<u32> = vec2(4294967295, 4294967295);
    if value.has(items, "frame") {
        if value.has(items, "frames") { return invalid; }
        let id = selection.named_slot(frames, value.text(value.get(items, "frame")));
        return vec2(id, id);
    }
    if value.has(items, "frames") {
        let range = value.items(value.get(items, "frames"));
        if length(range) != 2 { return invalid; }
        return vec2(selection.named_slot(frames, value.text(range.at_or(0, json.null()))),
            selection.named_slot(frames, value.text(range.at_or(1, json.null()))));
    }
    return vec2(0, length(frames) - 1);
}

fn detail(art: frame.Artwork, raw: json.Json) -> Result<Detail, String> {
    let diagnostic = "Protected pixel details need unique IDs, pixel lists, and optional known frames in document order";
    let items = value.fields(raw);
    let id = value.text(value.get(items, "id"));
    let kind = value.text(value.get(items, "kind"));
    let range = detail_scope(items, art.frames);
    let coords = value.get(items, "pixels");
    if id == "" || !value.only(items, ["id", "kind", "frame", "frames", "pixels"]) || range.x > range.y || range.y >= length(art.frames) {
        return Err(diagnostic);
    }
    let decoded: Result<List<json.Json>, String> = json.elements(coords).fold(fn(rows) => Ok(rows), fn(issue) => Err(diagnostic));
    let rows = decoded?;
    if value.has(items, "kind") && (!(kind == "pixel" || kind == "gap" || kind == "contour" || kind == "accent") || length(rows) == 0) {
        return Err(diagnostic);
    }
    let sites = rows.map(fn(raw) => site(art.grid, raw));
    if length(sites.filter(fn(p) => p >= mask.size(art.grid))) != 0 {
        return Err(string_concat("Protected detail ", string_concat(id, " has a pixel outside the native grid")));
    }
    return Ok(Detail { id: id, kind: kind, frame_id: value.text(value.get(items, "frame")),
        first: range.x, last: range.y, sites: sites });
}

fn site(g: mask.Grid, raw: json.Json) -> u32 {
    let point = selection.point(value.items(raw), g);
    return if selection.inside(point, g) { mask.index(g, point) } else { 4294967295 };
}

fn protections(document: json.Json, art: frame.Artwork) -> Result<List<Detail>, String> {
    let parsed: Result<List<json.Json>, String> = value.property(document, "protectedDetails").fold(fn(raw) =>
        json.elements(raw).fold(fn(rows) => Ok(rows), fn(issue) => Err("Protected pixel details must be an array")),
        fn(unit) => Ok([]));
    let rows = parsed?;
    let init = Details { rows: Buffer.empty(), issue: "" };
    let checked = foldl(rows, init, fn(raw) => fn(out) =>
        if out.issue != "" { out } else { add_detail(art, raw, out) });
    if checked.issue != "" { return Err(checked.issue); }
    return Ok(checked.rows.freeze());
}

fn add_detail(art: frame.Artwork, raw: json.Json, old: Details) -> Details {
    return detail(art, raw).fold(fn(row) => Details { ..old, rows: old.rows.push(row) },
        fn(issue) => Details { ..old, issue: issue });
}

fn active_details(protected: List<Detail>, index: u32) -> List<Detail> {
    return protected.filter(fn(row) => row.first <= index && index <= row.last);
}

fn locked_pixels(g: mask.Grid, details: List<Detail>) -> List<u32> {
    if length(details) == 0 { return []; }
    return foldl(details, mask.blank(g), fn(row) => fn(out) =>
        foldl(row.sites, out, fn(p) => fn(words) => mask.mark(words, p))).freeze();
}

fn pigment_diff(a: frame.Pixel, b: frame.Pixel) -> Bool {
    if a.alpha == 0 && b.alpha == 0 { return false; }
    return a.alpha != b.alpha || a.slot != b.slot || a.color != b.color;
}

fn issue_at(g: mask.Grid, p: u32) -> String {
    return string_concat(frame.decimal(rem_or(p, g.width, 0)), string_concat(", ", frame.decimal(quot_or(p, g.width, 0))));
}

fn gap_issue(g: mask.Grid, details: List<Detail>, pixels: List<frame.Pixel>) -> String {
    return foldl(details, "", fn(row) => fn(issue) =>
        if issue != "" || row.kind != "gap" { issue } else { gap_detail(g, row, pixels) });
}

fn gap_detail(g: mask.Grid, row: Detail, pixels: List<frame.Pixel>) -> String {
    let p: u32 = repeat_until(length(row.sites), 4294967295, fn(found) => found != 4294967295,
        fn(i) => fn(found) => visible_site(pixels, row.sites.at_or(i, 0), found));
    if p == 4294967295 { return ""; }
    return string_concat("Protected gap ", string_concat(row.id, string_concat(" must be transparent at ", issue_at(g, p))));
}

fn visible_site(pixels: List<frame.Pixel>, p: u32, otherwise: u32) -> u32 {
    let cell = pixels.at_or(p, frame.blank());
    return if cell.slot >= 0 && cell.alpha > 0 { p } else { otherwise };
}

record DetailChange { detail: String, pixel: u32, }

fn no_detail_change() -> DetailChange { return DetailChange { detail: "", pixel: 4294967295 }; }

fn compare_details(details: List<Detail>, before: List<frame.Pixel>, after: List<frame.Pixel>) -> DetailChange {
    return foldl(details, no_detail_change(), fn(row) => fn(issue) =>
        if issue.detail != "" { issue } else { compare_detail(row, before, after) });
}

fn compare_detail(row: Detail, before: List<frame.Pixel>, after: List<frame.Pixel>) -> DetailChange {
    let p: u32 = repeat_until(length(row.sites), 4294967295, fn(found) => found != 4294967295,
        fn(i) => fn(found) => changed_site(row.sites.at_or(i, 0), before, after, found));
    return if p == 4294967295 { no_detail_change() } else { DetailChange { detail: row.id, pixel: p } };
}

fn changed_site(p: u32, before: List<frame.Pixel>, after: List<frame.Pixel>, fallback: u32) -> u32 {
    return if pigment_diff(before.at_or(p, frame.blank()), after.at_or(p, frame.blank())) { p } else { fallback };
}

fn check_dependent_frames(prior: frame.Artwork, next: frame.Artwork, details: List<Detail>,
    skip: String) -> Result<Unit, fault.Fault> {
    if length(details) == 0 || length(prior.cels.filter(fn(cel) => value.has(cel.fields, "hold"))) == 0 { return Ok(()); }
    let initial: Option<fault.Fault> = None;
    let result = repeat_until(length(prior.frames), initial, fn(issue) => issue.fold(fn(failed) => true, fn(unit) => false),
        fn(i) => fn(issue) => if prior.frames.at_or(i, "") == skip { None } else {
            compare_frame(prior, next, i, active_details(details, i)).fold(fn(unit) => None, fn(problem) => Some(problem))
        });
    return result.fold(fn(issue) => Err(issue), fn(unit) => Ok(()));
}

fn compare_frame(prior: frame.Artwork, next: frame.Artwork, index: u32, details: List<Detail>) -> Result<Unit, fault.Fault> {
    if length(details) == 0 { return Ok(()); }
    let scope = frame.Scope { frame: prior.frames.at_or(index, ""), layer: "" };
    let before = frame.paint_view(prior, scope).map_err(fn(issue) => fault.invalid(issue))?;
    let after = frame.paint_view(next, scope).map_err(fn(issue) => fault.invalid(issue))?;
    let issue = compare_details(details, before.pixels, after.pixels);
    if issue.detail != "" { return Err(fault.dependent(prior.grid, scope.frame, issue.detail, issue.pixel)); }
    return Ok(());
}

record Decimal { text: String, value: u32, }

fn number(n: u32) -> String {
    if n == 0 { return "0"; }
    let init = Decimal { text: "", value: n };
    return repeat_until(10, init, fn(out) => out.value == 0, fn(i) => fn(out) =>
        Decimal { text: string_concat(frame.digit_at(out.value, 0), out.text), value: quot_or(out.value, 10, 0) }).text;
}

fn local_run(g: mask.Grid, p: frame.Placement, span: Vec3<u32>) -> Result<Vec3<u32>, String> {
    let x = drawing.signed(span.y) - p.x;
    let y = drawing.signed(span.x) - p.y;
    if x < 0 || y < 0 || x + drawing.signed(span.z) > drawing.signed(g.width) || y >= drawing.signed(g.height) {
        return Err("Edit lies outside the shifted cel grid");
    }
    return Ok(vec3(drawing.unsigned(y), drawing.unsigned(x), span.z));
}

fn is_valid_run(span: Result<Vec3<u32>, String>) -> Bool {
    return span.fold(fn(row) => true, fn(issue) => false);
}

fn member(key: String, raw: json.Json) -> json.Member { return json.Member { key: key, value: raw }; }

fn replace(items: List<json.Member>, key: String, raw: json.Json) -> List<json.Member> {
    if !value.has(items, key) { return items.concat([member(key, raw)]); }
    return items.map(fn(item) => if item.key == key { member(key, raw) } else { item });
}

fn local_mark(g: mask.Grid, offset: frame.Placement, row: raster.RunMark) -> Result<raster.RunMark, String> {
    let local = row.spans.map(fn(span) => local_run(g, offset, span));
    if length(local.filter(fn(span) => !is_valid_run(span))) != 0 { return Err("Edit lies outside the shifted cel grid"); }
    let spans = local.map(fn(out) => out.fold(fn(span) => span, fn(issue) => vec3(0, 0, 0)));
    return Ok(raster.RunMark { ..row, spans: spans });
}

fn append_marks(art: frame.Artwork, scope: frame.Scope, marks: List<raster.RunMark>, cel: String) -> Result<Appended, String> {
    let target = frame.active_cel(art.cels, scope.frame, scope.layer);
    let ordinal = frame.clip_index(art.layers, scope.layer, length(art.layers));
    let offset = frame.placement(art.inputs.at_or(ordinal, json.null()), target);
    let rows = marks.map(fn(row) => local_mark(art.grid, offset, row));
    if length(rows.filter(fn(row) => row.fold(fn(mark) => false, fn(issue) => true))) != 0 {
        return Err("Edit lies outside the shifted cel grid");
    }
    let fallback = raster.RunMark { slot: -1, alpha: None, spans: [], point: false };
    let local = rows.map(fn(row) => row.fold(fn(mark) => mark, fn(issue) => fallback));
    return Ok(append_local_marks(art, scope, target, local, cel));
}

fn append_local_marks(art: frame.Artwork, scope: frame.Scope, target: frame.Cel, local: List<raster.RunMark>, cel: String) -> Appended {
    let source = frame.resolved_cel(art.cels, target);
    let fields = independent_fields(scope, target, source.fields, cel);
    return Appended { fields: fields, runs: source.runs.concat(local), prepared: source.prepared, plane: source.plane };
}

fn independent_fields(scope: frame.Scope, target: frame.Cel, source: List<json.Member>, id: String) -> List<json.Member> {
    let prior = value.items(value.get(source, "marks"));
    let active = target.fields.filter(fn(item) => item.key != "hold");
    let base = if target.id == "" && id != default_id(scope) { replace(active, "id", json.text(id)) } else { active };
    let revised = replace(base, "marks", json.array(prior));
    let slots = json.lookup(source, "slots");
    if value.has(target.fields, "hold") {
        return slots.fold(fn(raw) => replace(revised, "slots", raw), fn(unit) => revised);
    }
    return revised;
}

fn default_id(scope: frame.Scope) -> String { return string_concat(scope.frame, string_concat("/", scope.layer)); }

fn choose_cel(art: frame.Artwork, scope: frame.Scope) -> String {
    let existing = frame.active_cel(art.cels, scope.frame, scope.layer).id;
    if existing != "" { return existing; }
    let standard = default_id(scope);
    if frame.location(art.locations, standard).id == "" { return standard; }
    return repeat_until(length(art.locations) + 1, "", fn(id) => id != "",
        fn(i) => fn(id) => unused_cel(art.locations, scope, i + 2));
}

fn unused_cel(locations: List<frame.Location>, scope: frame.Scope, index: u32) -> String {
    let suffix = string_concat("-", number(index));
    let max = 64 - string_byte_len(suffix);
    let layer = if string_byte_len(scope.layer) > max { string_slice(scope.layer, 0, max).fold(fn(s) => s, fn(unit) => scope.layer) }
        else { scope.layer };
    let id = string_concat(scope.frame, string_concat("/", string_concat(layer, suffix)));
    return if frame.location(locations, id).id == "" { id } else { "" };
}

fn serialize_mark(ids: List<String>, row: raster.RunMark) -> SnapshotMark {
    let swatch: Option<String> = if row.slot < 0 { None } else { Some(ids.at_or(drawing.unsigned(row.slot), "")) };
    return SnapshotMark { swatch: swatch, knockout: row.slot == -2, alpha: row.alpha, runs: row.spans, point: row.point };
}

fn saved_frame(row: json.Json, edits: List<SavedCel>) -> json.Json {
    let fields = value.fields(row);
    let id = value.text(value.get(fields, "id"));
    let own = edits.filter(fn(cel) => cel.frame == id);
    if length(own) == 0 { return row; }
    let initial = value.fields(value.get(fields, "cels"));
    let current = foldl(own, initial, fn(cel) => fn(cels) => replace(cels, cel.layer, cel.authored));
    return json.object(replace(fields, "cels", json.object(current)));
}

// Resolve cel order and swatch IDs before the hosts serialize the typed runs.
fn snapshot(source: json.Json, art: frame.Artwork) -> RasterSnapshot {
    let edited = art.cels.filter(fn(cel) => length(cel.runs) != 0);
    if length(edited) == 0 { return RasterSnapshot { source: source, edits: [] }; }
    let exported = edited.map(fn(cel) => SavedCel { frame: cel.frame, layer: cel.layer, authored: json.object(cel.fields) });
    let items = value.fields(source);
    let frames = value.items(value.get(items, "frames"));
    let doc = json.object(replace(items, "frames", json.array(frames.map(fn(row) => saved_frame(row, exported)))));
    let edits = edited.map(fn(cel) => SnapshotCel { frame: cel.frame, layer: cel.layer,
        marks: cel.runs.map(fn(row) => serialize_mark(art.ids, row)) });
    return RasterSnapshot { source: doc, edits: edits };
}

fn revised_palette(source: json.Json, added: List<brush.Swatch>) -> json.Json {
    if length(added) == 0 { return json.null(); }
    let items = value.fields(source);
    let extra = added.map(fn(row) => member(row.id, json.text(brush_paint.color_text(row.color))));
    let base = value.fields(value.get(items, "palette"));
    return json.object(replace(items, "palette", json.object(base.concat(extra))));
}

fn attach(art: frame.Artwork, scope: frame.Scope, id: String, added: Appended) -> frame.Artwork {
    let cel = frame.Cel { id: id, frame: scope.frame, layer: scope.layer, fields: added.fields,
        runs: added.runs, prepared: added.prepared, plane: added.plane };
    if frame.location(art.locations, id).id != "" {
        return frame.Artwork { ..art, cels: art.cels.map(fn(row) => if row.id == id { cel } else { row }) };
    }
    return frame.Artwork { ..art, cels: art.cels.concat([cel]),
        locations: art.locations.concat([frame.Location { id: id, frame: scope.frame, layer: scope.layer }]) };
}

fn empty_cache() -> CachedView {
    return CachedView { scope: frame.Scope { frame: "", layer: "" },
        view: frame.PaintView { captured: frame.no_capture(), pixels: [] } };
}

fn render_after_edit(art: frame.Artwork, scope: frame.Scope) -> Result<CachedView, fault.Fault> {
    let view = frame.paint_view(art, scope).map_err(fn(issue) => fault.invalid(issue))?;
    return Ok(CachedView { scope: scope, view: view });
}

fn selection_image(art: frame.Artwork, cache: CachedView, scope: frame.Scope) -> Result<selection.Image, String> {
    let saved = cache.scope.frame == scope.frame && (scope.layer == "" || scope.layer == cache.scope.layer);
    if !saved { return frame.raster(art, scope).map(fn(found) => found.image); }
    let view = if scope.layer == "" { frame.PaintView { ..cache.view, captured: frame.no_capture() } }
        else { cache.view };
    return frame.finish_view(art, view, scope).map(fn(found) => found.image);
}

fn begin_edit(source: json.Json, art: frame.Artwork, named: selection.Named, scope: frame.Scope,
    wanted: Option<String>, cache: CachedView) -> Result<EditContext, String> {
    let details = protections(source, art)?;
    let limit = constraint(art.grid, named, scope.frame, wanted)?;
    let current: Result<frame.PaintView, String> = if scope == cache.scope { Ok(cache.view) } else { frame.paint_view(art, scope) };
    let drawn = current?;
    let active = active_details(details, selection.named_slot(art.frames, scope.frame));
    let issue = gap_issue(art.grid, active, drawn.pixels);
    if issue != "" { return Err(issue); }
    let guard = Guard { drawn: drawn, protected: locked_pixels(art.grid, active), selected: limit };
    return Ok(EditContext { guard: guard, details: details, active: active });
}

fn apply_color(source: json.Json, art: frame.Artwork, named: selection.Named, spec: List<json.Member>,
    input: RgbaInput, frame_id: Option<String>, cel: Option<String>, kind: String, authored: List<List<u32>>, cache: CachedView) -> Result<Edit, fault.Fault> {
    if kind == "rgba" {
        if !value.only(spec, ["tool", "layer", "pixels"]) || length(input.pixels) == 0 ||
            rem_or(length(input.pixels), 3, 0) != 0 || length(input.pixels) > mask.size(art.grid) * 3 {
            return Err(fault.invalid("An RGBA edit needs a layer or cel and native pixels"));
        }
        let scope = target(art, spec, frame_id, cel)?;
        let ctx = begin_edit(source, art, named, scope, None, cache).map_err(fn(issue) => fault.invalid(issue))?;
        let changes = rgba_changes(art, ctx.guard, input, scope.layer)?;
        let report = color_report(art, scope, kind, changes);
        return finish_edit(source, art, scope, changes, report, ctx);
    }
    let name = value.text(value.get(spec, "selection"));
    if !value.only(spec, ["tool", "layer", "selection", "from", "to"]) || !brush.stable_id(name) {
        return Err(fault.invalid("Swatch replacement needs a layer or cel and a saved selection"));
    }
    let from = value.text(value.get(spec, "from"));
    let to = value.text(value.get(spec, "to"));
    let prior = selection.find_swatch(art.ids, from);
    let next = selection.find_swatch(art.ids, to);
    if prior < 0 || next < 0 || prior == next { return Err(fault.invalid("Choose two distinct existing swatch IDs")); }
    let scope = target(art, spec, frame_id, cel)?;
    let ctx = begin_edit(source, art, named, scope, Some(name), cache).map_err(fn(issue) => fault.invalid(issue))?;
    let order = authored.at_or(selection.named_slot(named.ids, name), []);
    let changes = replace_changes(art.grid, ctx.guard, prior, next, scope.layer, order)?;
    let base = color_report(art, scope, kind, changes);
    let report = Report { ..base, selection: Some(name), from: Some(from), to: Some(to) };
    return finish_edit(source, art, scope, changes, report, ctx);
}

fn color_report(art: frame.Artwork, scope: frame.Scope, tool: String, changes: Changes) -> Report {
    return Report { frame: scope.frame, layer: scope.layer, cel: choose_cel(art, scope), tool: tool,
        runs: runs(art.grid, changes.sites), pixelCount: length(changes.sites), pixelPerfect: false, shape: None,
        selection: None, shading: None, ramp: None, addedSwatches: changes.added.map(fn(row) => row.id),
        from: None, to: None, transform: None };
}

record TransformSpec { paste: Bool, mode: String, carrying: Bool, selection: Option<String>,
    result_id: String, raw: json.Json, settings: json.Json, }

fn transform_options(spec: List<json.Member>, paste: Bool) -> Result<TransformSpec, String> {
    let common = ["tool", "layer", "transform", "resultSelection"];
    let fields = if paste { common.concat(["clipboard"]) } else { common.concat(["selection", "mode", "carryProtection"]) };
    if !value.only(spec, fields) {
        return Err("A transform needs a named selection or an indexed clipboard to paste");
    }
    let mode = json.lookup(spec, "mode").fold(fn(raw) => value.text(raw), fn(unit) => "move");
    let carrying = value.flag(spec, "carryProtection", false);
    if !drawing.bool_field(spec, "carryProtection") || (carrying && mode != "move") {
        return Err("Only a selection move can carry protection");
    }
    let result_id = value.text(value.get(spec, "resultSelection"));
    if (!paste && !(mode == "move" || mode == "copy")) || (value.has(spec, "resultSelection") && !brush.stable_id(result_id)) {
        return Err("Use move or copy and an optional result selection ID in a version 2 document");
    }
    let settings = json.lookup(spec, "transform").fold(fn(raw) => raw, fn(unit) => json.object([]));
    return Ok(TransformSpec { paste: paste, mode: mode, carrying: carrying, selection: None,
        result_id: result_id, raw: value.get(spec, "clipboard"), settings: settings });
}

fn apply_transform(source: json.Json, art: frame.Artwork, named: selection.Named, spec: List<json.Member>,
    packed: transforms.PackedClip, frame_id: Option<String>, cel: Option<String>, paste: Bool, cache: CachedView) -> Result<Edit, fault.Fault> {
    let decoded = transform_options(spec, paste).map_err(fn(issue) => fault.invalid(issue))?;
    let scope = target(art, spec, frame_id, cel)?;
    let wanted: Result<Option<String>, String> = if paste { Ok(None) }
        else { transforms.selection_name(spec).fold(fn(id) => Ok(Some(id)), fn(issue) => Err(issue)) };
    let name = wanted.map_err(fn(issue) => fault.invalid(issue))?;
    let options = TransformSpec { ..decoded, selection: name };
    let ctx = begin_edit(source, art, named, scope, options.selection, cache).map_err(fn(issue) => fault.invalid(issue))?;
    let captured = ctx.guard.drawn.captured;
    let input: Result<transforms.Clip, String> = if paste { transforms.clipboard(options.raw, packed) }
        else { transforms.capture(art, captured, ctx.guard.selected.words) };
    let clip = input.map_err(fn(issue) => fault.invalid(issue))?;
    let plan = transforms.stage(art, captured, clip, options.settings, !paste && options.mode == "move").map_err(fn(issue) => fault.invalid(issue))?;
    let carry = if options.carrying { plan_carry(art.grid, scope.frame, ctx.active, ctx.guard.selected.words, plan.hits) }
        else { Ok(no_carry()) };
    let moved = carry.map_err(fn(issue) => fault.invalid(issue))?;
    return commit_transform(source, art, scope, ctx, options, plan, moved);
}

fn commit_transform(source: json.Json, art: frame.Artwork, scope: frame.Scope, ctx: EditContext,
    options: TransformSpec, plan: transforms.Plan, moved: Carry) -> Result<Edit, fault.Fault> {
    let locked = if length(moved.rows) == 0 { ctx.guard.protected }
        else { locked_pixels(art.grid, ctx.active.filter(fn(row) => !contains_moved(moved, row.id))) };
    let denied: u32 = foldl(plan.writes, 4294967295, fn(row) => fn(found) =>
        if found == 4294967295 && !frame.can_paint(ctx.guard.drawn, locked, row.pixel) { row.pixel } else { found });
    if denied != 4294967295 {
        return Err(fault.blocked(art.grid, ctx.guard.drawn, locked, scope.layer, denied, "Transform cannot change this pixel"));
    }
    let changes = write_changes(art.grid, ctx.guard.drawn.captured, plan.writes, plan.added, true);
    let tool = if options.paste { "paste" } else { "transform" };
    let base = color_report(art, scope, tool, changes);
    let result_id = options.result_id;
    let result: Option<ResultMask> = if result_id == "" { None } else { Some(ResultMask { id: result_id, words: plan.mask }) };
    let placement = TransformReport { mode: if options.paste { None } else { Some(options.mode) }, bounds: plan.bounds,
        clippedPixels: plan.clipped, resultSelection: optional_text(result_id),
        selectionRuns: if result_id == "" { [] } else { runs(art.grid, mask.indices(plan.mask)) },
        carriedProtection: moved.reports };
    let report = Report { ..base, selection: options.selection, transform: Some(placement) };
    let pending = if length(moved.rows) == 0 { finish_edit(source, art, scope, changes, report, ctx) }
        else { finish_carried(source, art, scope, changes, report, ctx, moved) };
    let edit = pending?;
    return Ok(Edit { ..edit, result_mask: result });
}

record SourceBuild { heads: Buffer<u32>, links: Buffer<u32>, }
record SourceIndex { heads: List<u32>, links: List<u32>, }
record MovedDetail { before: Detail, after: Detail, }
record Carry { rows: List<MovedDetail>, reports: List<CarriedReport>, sources: SourceIndex, }
record CarryBuild { rows: Buffer<MovedDetail>, reports: Buffer<CarriedReport>, issue: String, }
record Destinations { words: Buffer<u32>, missing: Bool, }
record SourceVisit { words: Buffer<u32>, pixel: u32, }

fn no_carry() -> Carry { return Carry { rows: [], reports: [], sources: SourceIndex { heads: [], links: [] } }; }

fn index_source(hit: transforms.Hit, old: SourceBuild) -> SourceBuild {
    let head = old.heads.at_or(hit.source, 4294967295);
    return SourceBuild { heads: old.heads.set(hit.source, hit.pixel), links: old.links.set(hit.pixel, head) };
}

fn contains_moved(moved: Carry, id: String) -> Bool {
    return length(moved.rows.filter(fn(row) => row.before.id == id)) != 0;
}

fn plan_carry(g: mask.Grid, active: String, details: List<Detail>, words: List<u32>, hits: List<transforms.Hit>) -> Result<Carry, String> {
    let involved = details.filter(fn(row) => length(row.sites.filter(fn(p) => mask.selected(words, p))) != 0);
    if length(involved) == 0 { return Ok(no_carry()); }
    let init = SourceBuild { heads: buffer_fill(mask.size(g), 4294967295), links: buffer_fill(mask.size(g), 4294967295) };
    let indexed = foldl(hits, init, fn(hit) => fn(old) => index_source(hit, old));
    let sources = SourceIndex { heads: indexed.heads.freeze(), links: indexed.links.freeze() };
    let seed = CarryBuild { rows: Buffer.empty(), reports: Buffer.empty(), issue: "" };
    let result = foldl(involved, seed, fn(row) => fn(old) =>
        if old.issue != "" { old } else { carry_detail(g, active, row, words, sources, old) });
    if result.issue != "" { return Err(result.issue); }
    return Ok(Carry { rows: result.rows.freeze(), reports: result.reports.freeze(), sources: sources });
}

fn carry_detail(g: mask.Grid, active: String, row: Detail, words: List<u32>, sources: SourceIndex, old: CarryBuild) -> CarryBuild {
    if row.kind == "" || row.frame_id != active || length(row.sites.filter(fn(p) => !mask.selected(words, p))) != 0 {
        return CarryBuild { ..old, issue: string_concat("Select all pixels of a detail locked to this frame to carry ", row.id) };
    }
    let seed = Destinations { words: mask.blank(g), missing: false };
    let mapped = foldl(row.sites, seed, fn(p) => fn(out) =>
        if out.missing { out } else { carry_site(sources, p, out) });
    if mapped.missing { return CarryBuild { ..old, issue: string_concat("Transform would discard protected detail ", row.id) }; }
    let sites = mask.indices(mapped.words.freeze());
    let after = Detail { ..row, sites: sites };
    let result = CarriedReport { id: row.id, kind: row.kind, frame: active, pixels: sites.map(fn(p) =>
        vec2(rem_or(p, g.width, 0), quot_or(p, g.width, 0))) };
    return CarryBuild { ..old, reports: old.reports.push(result), rows: old.rows.push(MovedDetail { before: row, after: after }) };
}

fn carry_site(sources: SourceIndex, p: u32, old: Destinations) -> Destinations {
    let first = sources.heads.at_or(p, 4294967295);
    if first == 4294967295 { return Destinations { ..old, missing: true }; }
    let recent = repeat_until(length(sources.links), SourceVisit { words: old.words, pixel: first },
        fn(out) => out.pixel == 4294967295, fn(i) => fn(out) =>
            SourceVisit { words: mask.mark(out.words, out.pixel), pixel: sources.links.at_or(out.pixel, 4294967295) });
    return Destinations { words: recent.words, missing: false };
}

fn moved_site_changed(sources: SourceIndex, p: u32, prior: List<frame.Pixel>, next: List<frame.Pixel>) -> u32 {
    let invalid: u32 = 4294967295;
    let start: Vec2<u32> = vec2(sources.heads.at_or(p, invalid), invalid);
    let pigment = prior.at_or(p, frame.blank());
    let issue = repeat_until(length(sources.links), start, fn(out) => out.x == invalid, fn(i) => fn(out) =>
        vec2(sources.links.at_or(out.x, invalid),
            if pigment_diff(pigment, next.at_or(out.x, frame.blank())) { mask.min(out.x, out.y) } else { out.y }));
    return issue.y;
}

fn carried_issue(moved: Carry, prior: List<frame.Pixel>, next: List<frame.Pixel>) -> DetailChange {
    return foldl(moved.rows, no_detail_change(), fn(row) => fn(issue) =>
        if issue.detail != "" { issue } else { carried_row_issue(row.before, moved.sources, prior, next) });
}

fn carried_row_issue(row: Detail, sources: SourceIndex, prior: List<frame.Pixel>, next: List<frame.Pixel>) -> DetailChange {
    let p: u32 = repeat_until(length(row.sites), 4294967295, fn(found) => found != 4294967295,
        fn(i) => fn(found) => moved_site_changed(sources, row.sites.at_or(i, 0), prior, next));
    return DetailChange { detail: if p == 4294967295 { "" } else { row.id }, pixel: p };
}

fn revise_protection(source: json.Json, moved: Carry) -> json.Json {
    let fields = value.fields(source);
    let rows = value.items(value.get(fields, "protectedDetails"));
    let updated = rows.map(fn(row) => moved_row(row, moved.reports));
    return json.object(replace(fields, "protectedDetails", json.array(updated)));
}

fn moved_row(raw: json.Json, reports: List<CarriedReport>) -> json.Json {
    let fields = value.fields(raw);
    let id = value.text(value.get(fields, "id"));
    let index: u32 = repeat_until(length(reports), 4294967295, fn(found) => found != 4294967295, fn(i) => fn(found) =>
        if reports.at_or(i, CarriedReport { id: "", kind: "", frame: "", pixels: [] }).id == id { i } else { found });
    if index == 4294967295 { return raw; }
    let row = reports.at_or(index, CarriedReport { id: "", kind: "", frame: "", pixels: [] });
    let points = row.pixels.map(fn(p) => json.array([json.number(frame.decimal(p.x)), json.number(frame.decimal(p.y))]));
    return json.object(replace(fields, "pixels", json.array(points)));
}

fn finish_carried(source: json.Json, art: frame.Artwork, scope: frame.Scope, changes: Changes, report: Report,
    ctx: EditContext, moved: Carry) -> Result<Edit, fault.Fault> {
    let edited: Result<frame.Artwork, String> = if report.pixelCount == 0 { Ok(art) }
        else { stage_artwork(art, scope, changes, report.cel) };
    let next = edited.map_err(fn(issue) => fault.invalid(issue))?;
    if report.pixelCount != 0 { let checked: Unit = check_dependent_frames(art, next, ctx.details, scope.frame)?; }
    let rendered = render_after_edit(next, scope)?;
    let issue = carried_issue(moved, ctx.guard.drawn.pixels, rendered.view.pixels);
    if issue.detail != "" { return Err(fault.moved(art.grid, scope.layer, issue.detail, issue.pixel)); }
    let active = ctx.active.filter(fn(row) => !contains_moved(moved, row.id)).concat(moved.rows.map(fn(row) => row.after));
    let gap = gap_issue(art.grid, active, rendered.view.pixels);
    if gap != "" { return Err(fault.invalid(gap)); }
    let metadata = revised_palette(source, changes.added);
    return Ok(Edit { document: revise_protection(if metadata == json.null() { source } else { metadata }, moved),
        artwork: next, report: report, cache: rendered, result_mask: None });
}

fn replace_changes(g: mask.Grid, guard: Guard, from: i32, to: i32, layer: String, authored: List<u32>) -> Result<Changes, fault.Fault> {
    let pixels = mask.indices(guard.selected.words).filter(fn(p) => guard.drawn.captured.slots.at_or(p, -1) == from);
    let denied: u32 = foldl(pixels, 4294967295, fn(p) => fn(found) =>
        if found == 4294967295 && !writable(guard, p) { p } else { found });
    if denied != 4294967295 {
        let first: u32 = repeat_until(length(authored), 4294967295, fn(found) => found != 4294967295,
            fn(i) => fn(found) => denied_swatch_site(guard, from, authored.at_or(i, 0)));
        let p = if first == 4294967295 { denied } else { first };
        return Err(fault.blocked(g, guard.drawn, guard.protected, layer, p, "Swatch replacement cannot change this pixel"));
    }
    let marks: List<raster.RunMark> = if length(pixels) == 0 { [] }
        else { [raster.RunMark { slot: to, alpha: None, spans: runs(g, pixels), point: false }] };
    return Ok(Changes { sites: pixels, marks: marks, added: [], shading: brush_paint.unshaded() });
}

fn denied_swatch_site(guard: Guard, from: i32, p: u32) -> u32 {
    return if guard.drawn.captured.slots.at_or(p, -1) == from && !writable(guard, p) { p } else { 4294967295 };
}

fn rgba_changes(art: frame.Artwork, guard: Guard, input: RgbaInput, layer: String) -> Result<Changes, fault.Fault> {
    let plan = rgba.plan(art, guard.drawn, guard.protected, input.pixels, input.names, layer)?;
    return Ok(write_changes(art.grid, guard.drawn.captured, plan.writes, plan.added, false));
}

fn write_changes(g: mask.Grid, previous: frame.Captured, writes: List<rgba.Write>, added: List<brush.Swatch>, ordered: Bool) -> Changes {
    let sites = writes.map(fn(row) => row.pixel);
    let color_keys = writes.filter(fn(row) => row.slot != previous.slots.at_or(row.pixel, -1))
        .map(fn(row) => wrapping_shl(row.pixel, 9) + drawing.unsigned(row.slot + 2));
    let alpha_keys = writes.filter(fn(row) => opacity_changed(previous, row))
        .map(fn(row) => wrapping_shl(row.pixel, 9) + row.alpha);
    let pigments = if ordered { color_keys } else { color_keys.sort() };
    let alpha = if ordered { alpha_keys } else { alpha_keys.sort() };
    let marks = grouped_marks(g, pigments, false).concat(grouped_marks(g, alpha, true));
    return Changes { sites: if ordered { sites } else { sites.sort() },
        marks: marks, added: added, shading: brush_paint.unshaded() };
}

fn opacity_changed(previous: frame.Captured, row: rgba.Write) -> Bool {
    if row.slot < 0 { return false; }
    let alpha: u32 = if previous.slots.at_or(row.pixel, -1) < 0 { 255 } else { previous.alpha.at_or(row.pixel, 255) };
    return row.alpha != alpha;
}


fn paint(source: json.Json, art: frame.Artwork, named: selection.Named, operation: json.Json,
    packed: transforms.PackedClip, input: RgbaInput, frame_id: Option<String>, cel: Option<String>, authored: List<List<u32>>, cache: CachedView) -> Result<Edit, fault.Fault> {
    let error = "A raster tool needs a layer or cel and a pencil, eraser, fill, shape or brush operation";
    let parsed: Result<List<json.Member>, fault.Fault> = json.members(operation).fold(fn(rows) => Ok(rows), fn(issue) => Err(fault.invalid(error)));
    let spec = parsed?;
    let kind = value.text(value.get(spec, "tool"));
    if kind == "transform" || kind == "paste" {
        return apply_transform(source, art, named, spec, packed, frame_id, cel, kind == "paste", cache);
    }
    if kind == "rgba" || kind == "replace-swatch" {
        return apply_color(source, art, named, spec, input, frame_id, cel, kind, authored, cache);
    }
    if !value.only(spec, ["tool", "layer", "at", "points", "samples", "swatch", "pixelPerfect", "shape",
        "brush", "shading", "drawing", "selection"]) { return Err(fault.invalid(error)); }
    let scope = target(art, spec, frame_id, cel)?;
    let tool = decode(art.grid, art.ids, spec).map_err(fn(issue) => fault.invalid(issue))?;
    return paint_target(source, art, named, scope, tool, packed.slots, cache);
}

fn paint_target(source: json.Json, art: frame.Artwork, named: selection.Named, scope: frame.Scope, tool: Tool, slots: List<i32>, cache: CachedView) -> Result<Edit, fault.Fault> {
    let ctx = begin_edit(source, art, named, scope, tool.selection, cache).map_err(fn(issue) => fault.invalid(issue))?;
    let delta: Result<Changes, fault.Fault> = if tool.kind == "brush" { brushed(source, art, tool, ctx.guard, slots, scope.layer) }
        else { basic_changes(tool, ctx.guard, scope.layer) };
    let changes = delta?;
    let report = Report { frame: scope.frame, layer: scope.layer, cel: choose_cel(art, scope), tool: tool.kind,
        pixelCount: length(changes.sites), runs: runs(art.grid, changes.sites), pixelPerfect: tool.perfect, selection: tool.selection,
        shape: if tool.kind == "shape" { Some(shape.kind(tool.geometry)) } else { None },
        shading: optional_text(changes.shading.mode), ramp: optional_text(changes.shading.named),
        addedSwatches: changes.added.map(fn(row) => row.id), from: None, to: None, transform: None };
    return finish_edit(source, art, scope, changes, report, ctx);
}

fn finish_edit(source: json.Json, art: frame.Artwork, scope: frame.Scope, changes: Changes, report: Report,
    ctx: EditContext) -> Result<Edit, fault.Fault> {
    if report.pixelCount == 0 {
        return Ok(Edit { document: json.null(), artwork: frame.empty_artwork(), report: report,
            cache: empty_cache(), result_mask: None });
    }
    return commit_paint(source, art, scope, changes, report, ctx.details, ctx.active);
}

fn optional_text(text: String) -> Option<String> { return if text == "" { None } else { Some(text) }; }

fn commit_paint(source: json.Json, art: frame.Artwork, scope: frame.Scope, changes: Changes, report: Report,
    details: List<Detail>, active: List<Detail>) -> Result<Edit, fault.Fault> {
    let next = stage_artwork(art, scope, changes, report.cel).map_err(fn(issue) => fault.invalid(issue))?;
    let checked: Unit = check_dependent_frames(art, next, details, "")?;
    let rendered = render_after_edit(next, scope)?;
    let issue = gap_issue(art.grid, active, rendered.view.pixels);
    if issue != "" { return Err(fault.invalid(issue)); }
    return Ok(Edit { document: revised_palette(source, changes.added), artwork: next, report: report,
        cache: rendered, result_mask: None });
}

fn stage_artwork(art: frame.Artwork, scope: frame.Scope, changes: Changes, id: String) -> Result<frame.Artwork, String> {
    let palette = if length(changes.added) == 0 { art } else {
        frame.Artwork { ..art, ids: art.ids.concat(changes.added.map(fn(row) => row.id)),
            colors: art.colors.concat(changes.added.map(fn(row) => row.color)) }
    };
    let cel = append_marks(palette, scope, changes.marks, id)?;
    return Ok(attach(palette, scope, id, cel));
}
