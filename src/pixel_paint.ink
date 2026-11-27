module StudioPixelPaint;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_motion.ink" as motion;
import "pixel_brush_paint.ink" as brush_paint;
import "pixel_drawing_grid.ink" as drawing;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_raster.ink" as raster;
import "pixel_selection.ink" as selection;
import "pixel_shapes.ink" as shape;
import "pixel_values.ink" as value;

record Tool { kind: String, slot: i32, perfect: Bool, selection: Option<String>,
    drawing: drawing.Drawing, points: List<drawing.Point>, geometry: json.Json,
    saved_brush: json.Json, samples: Option<json.Json>, shading: Option<json.Json>, }
record Constraint { limited: Bool, words: List<u32>, }
record Guard { drawn: frame.PaintView, protected: List<u32>, selected: Constraint, }
record Stroke { words: Buffer<u32>, previous: drawing.Point, tip: drawing.Point, issue: String, }
record Segment { pen: drawing.Pen, stroke: Stroke, }
record Runs { spans: Buffer<Vec3<u32>>, y: u32, x: u32, length: u32, }
record Report { frame: String, layer: String, cel: String, tool: String, pixelCount: u32,
    runs: List<Vec3<u32>>, pixelPerfect: Bool, selection: Option<String>, shape: Option<String>, shading: Option<String>,
    ramp: Option<String>, addedSwatches: List<String>, }
record Detail { id: String, kind: String, first: u32, last: u32, sites: List<u32>, }
record Details { rows: Buffer<Detail>, issue: String, }
record Changes { sites: List<u32>, marks: List<raster.RunMark>, added: List<brush.Swatch>, shading: brush_paint.Shading, }
record Ranks { positions: Buffer<u32>, slots: Buffer<u32>, }
record Groups { marks: Buffer<raster.RunMark>, index: u32, spans: Runs, }
record Appended { authored: json.Json, runs: raster.RunCache, }
record Edit { document: json.Json, artwork: frame.Artwork, report: Report,
    scope: frame.Scope, image: selection.Image, }

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

fn writable(guard: Guard, p: u32) -> Bool {
    return !guard.drawn.pixels.at_or(p, frame.blank()).locked && !mask.selected(guard.protected, p) &&
        guard.drawn.captured.clipping.at_or(p, 255) != 0;
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
    if stroke.issue != "" || !selected(p, guard.selected) { return stroke; }
    if !writable(guard, p) { return Stroke { ..stroke, issue: "Paint tool cannot change this pixel" }; }
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
    return repeat_until(steps, start, fn(state) => state.stroke.issue != "", fn(i) => fn(state) =>
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

fn stroke(tool: Tool, guard: Guard) -> Result<List<u32>, String> {
    let init = Stroke { words: mask.blank(tool.drawing.grid), previous: drawing.absent(), tip: drawing.absent(), issue: "" };
    let path = foldl(tool.points, init, fn(p) => fn(old) =>
        if old.issue != "" { old } else { join_point(tool, guard, p, old) });
    let traced = emit(tool, guard, path.tip, path);
    if traced.issue != "" { return Err(traced.issue); }
    return Ok(traced.words.freeze());
}

fn paint_mask(tool: Tool, guard: Guard) -> Result<List<u32>, String> {
    if tool.kind == "fill" { return fill(tool, guard); }
    if tool.kind != "shape" { return stroke(tool, guard); }
    let coverage = shape.coverage(tool.drawing, tool.geometry)?;
    let init = Stroke { words: mask.blank(tool.drawing.grid), previous: drawing.absent(), tip: drawing.absent(), issue: "" };
    let traced = foldl(mask.indices(coverage), init, fn(p) => fn(out) => plot(guard, tool.slot, p, out));
    if traced.issue != "" { return Err(traced.issue); }
    return Ok(traced.words.freeze());
}

fn basic_changes(tool: Tool, guard: Guard) -> Result<Changes, String> {
    let changed = paint_mask(tool, guard)?;
    let sites = mask.indices(changed);
    let marks: List<raster.RunMark> = if length(sites) == 0 { [] } else {
        [raster.RunMark { slot: tool.slot, alpha: None, spans: runs(tool.drawing.grid, sites) }]
    };
    return Ok(Changes { sites: sites, marks: marks, added: [], shading: brush_paint.unshaded() });
}

fn brushed(source: json.Json, art: frame.Artwork, tool: Tool, guard: Guard, slots: List<i32>) -> Result<Changes, String> {
    let b = brush.decode(tool.saved_brush, slots)?;
    let traced = tool.samples.fold(fn(raw) => motion.trace(tool.drawing, b, raw),
        fn(unit) => brush.static_path(tool.drawing, b, tool.points));
    let stamps = traced?;
    let parsed: Result<brush_paint.Shading, String> = tool.shading.fold(fn(raw) => brush_paint.read_shading(source, art.ids, raw),
        fn(unit) => Ok(brush_paint.unshaded()));
    let shade = parsed?;
    let aimed = stamps.filter(fn(row) => selected(row.pixel, guard.selected)).map(fn(row) =>
        brush_paint.shaded(row, guard.drawn.captured, shade)).filter(fn(row) => row.slot >= 0);
    if length(aimed.filter(fn(row) => !writable(guard, row.pixel))) != 0 {
        return Err("Paint tool cannot change this pixel");
    }
    return brush_changes(art, tool.slot, b, shade, aimed, guard.drawn.captured);
}

fn brush_changes(art: frame.Artwork, override: i32, b: brush.Brush, shade: brush_paint.Shading,
    aimed: List<brush.Stamp>, captured: frame.Captured) -> Result<Changes, String> {
    if shade.mode == "alpha" {
        let sites = aimed.map(fn(row) => row.pixel).sort();
        let marks: List<raster.RunMark> = if length(sites) == 0 { [] } else { [raster.RunMark { slot: -1, alpha: Some(shade.opacity), spans: runs(art.grid, sites) }] };
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
        .map(fn(row) => wrapping_shl(row.pixel, 8) + drawing.unsigned(row.slot)).sort();
    let sites = keys.map(fn(key) => wrapping_shr(key, 8));
    let marks = grouped_marks(art.grid, length(art.ids) + length(palette.added), keys);
    return Ok(Changes { sites: sites, marks: marks, added: palette.added, shading: shade });
}

fn brush_rank(key: u32, old: Ranks) -> Ranks {
    let slot = word_and(key, 255);
    if old.positions.at_or(slot, 4294967295) != 4294967295 { return old; }
    let i = old.slots.len();
    return Ranks { slots: old.slots.push(slot), positions: old.positions.set(slot, i) };
}

fn grouped_marks(g: mask.Grid, count: u32, keys: List<u32>) -> List<raster.RunMark> {
    if length(keys) == 0 { return []; }
    let seed = Ranks { positions: buffer_fill(count, 4294967295), slots: Buffer.empty() };
    let rank = foldl(keys, seed, fn(k) => fn(out) => brush_rank(k, out));
    let positions = rank.positions.freeze();
    let slots = rank.slots.freeze();
    // Eight palette bits and eighteen canvas bits fit in one sortable word.
    let ordered = keys.map(fn(key) =>
        wrapping_shl(positions.at_or(word_and(key, 255), 0), 18) + wrapping_shr(key, 8)).sort();
    let init = Groups { marks: Buffer.empty(), index: 4294967295, spans: empty_runs() };
    let groups = foldl(ordered, init, fn(key) => fn(out) =>
        group_visit(g, slots, wrapping_shr(key, 18), word_and(key, 262143), out));
    return end_group(slots, groups).freeze();
}

fn end_group(slots: List<u32>, old: Groups) -> Buffer<raster.RunMark> {
    if old.index == 4294967295 { return old.marks; }
    let slot = drawing.signed(slots.at_or(old.index, 0));
    return old.marks.push(raster.RunMark { slot: slot, alpha: None, spans: emit_span(old.spans).freeze() });
}

fn group_visit(g: mask.Grid, slots: List<u32>, i: u32, p: u32, old: Groups) -> Groups {
    if old.index == i { return Groups { ..old, spans: add_span(g, p, old.spans) }; }
    return Groups { index: i, marks: end_group(slots, old), spans: add_span(g, p, empty_runs()) };
}


fn seed_status(seeds: List<u32>, guard: Guard) -> Bool {
    return foldl(seeds, true, fn(p) => fn(ok) => ok && (!selected(p, guard.selected) || writable(guard, p)));
}

fn fill(tool: Tool, guard: Guard) -> Result<List<u32>, String> {
    let seeds = drawing.copies(tool.drawing, tool.points.at_or(0, drawing.absent()));
    if !seed_status(seeds, guard) { return Err("Paint tool cannot change this pixel"); }
    let grid = tool.drawing.grid;
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

fn target(art: frame.Artwork, spec: List<json.Member>, frame_id: Option<String>, cel: Option<String>) -> Result<frame.Scope, String> {
    let layer = value.text(value.get(spec, "layer"));
    let by_cel = cel.fold(fn(id) => true, fn(unit) => false);
    let invalid = "Choose an existing raster layer or cel for the paint tool";
    if (by_cel && value.has(spec, "layer")) || (!by_cel && layer == "") { return Err(invalid); }
    let scope = frame.resolve(art, frame_id, frame.optional_scope(layer), cel)?;
    let row = find_layer(art.layers, scope.layer);
    if row.id == "" { return Err(invalid); }
    if locked_layer(art.layers, row) { return Err(string_concat("Layer ", string_concat(row.id, " does not accept pixel edits"))); }
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
    return Ok(Detail { id: id, kind: kind, first: range.x, last: range.y, sites: sites });
}

fn site(g: mask.Grid, raw: json.Json) -> u32 {
    let point = selection.point(value.items(raw), g);
    return if selection.inside(point, g) { mask.index(g, point) } else { 4294967295 };
}

fn protections(document: json.Json, art: frame.Artwork) -> Result<List<Detail>, String> {
    let doc = value.fields(document);
    let parsed: Result<List<json.Json>, String> = json.lookup(doc, "protectedDetails").fold(fn(raw) =>
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

fn compare_details(g: mask.Grid, details: List<Detail>, before: List<frame.Pixel>, after: List<frame.Pixel>) -> String {
    return foldl(details, "", fn(row) => fn(issue) =>
        if issue != "" { issue } else { compare_detail(g, row, before, after) });
}

fn compare_detail(g: mask.Grid, row: Detail, before: List<frame.Pixel>, after: List<frame.Pixel>) -> String {
    let p: u32 = repeat_until(length(row.sites), 4294967295, fn(found) => found != 4294967295,
        fn(i) => fn(found) => changed_site(row.sites.at_or(i, 0), before, after, found));
    if p == 4294967295 { return ""; }
    return string_concat("Edit would change protected detail ", string_concat(row.id, string_concat(" at ", issue_at(g, p))));
}

fn changed_site(p: u32, before: List<frame.Pixel>, after: List<frame.Pixel>, fallback: u32) -> u32 {
    return if pigment_diff(before.at_or(p, frame.blank()), after.at_or(p, frame.blank())) { p } else { fallback };
}

fn check_dependent_frames(prior: frame.Artwork, next: frame.Artwork, details: List<Detail>) -> Result<Unit, String> {
    if length(details) == 0 || length(prior.cels.filter(fn(cel) => value.has(cel.fields, "hold"))) == 0 { return Ok(()); }
    let result = repeat_until(length(prior.frames), "", fn(issue) => issue != "",
        fn(i) => fn(issue) => compare_frame(prior, next, i, active_details(details, i)).fold(fn(unit) => "", fn(problem) => problem));
    if result != "" { return Err(result); }
    return Ok(());
}

fn compare_frame(prior: frame.Artwork, next: frame.Artwork, index: u32, details: List<Detail>) -> Result<Unit, String> {
    if length(details) == 0 { return Ok(()); }
    let scope = frame.Scope { frame: prior.frames.at_or(index, ""), layer: "" };
    let before = frame.paint_view(prior, scope)?;
    let after = frame.paint_view(next, scope)?;
    let issue = compare_details(prior.grid, details, before.pixels, after.pixels);
    if issue != "" { return Err(issue); }
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

fn encoded_run(row: Vec3<u32>) -> json.Json {
    return json.array([json.number(number(row.x)), json.number(number(row.y)), json.number(number(row.z))]);
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

fn encode_mark(ids: List<String>, row: raster.RunMark) -> json.Json {
    let pigment = if row.slot < 0 { member("clear", json.boolean(true)) }
        else { member("swatch", json.text(ids.at_or(drawing.unsigned(row.slot), ""))) };
    let mark = row.alpha.fold(fn(a) => member("alpha", json.number(number(a))), fn(unit) => pigment);
    return json.object([mark, member("runs", json.array(row.spans.map(fn(span) => encoded_run(span))))]);
}

fn append_marks(art: frame.Artwork, scope: frame.Scope, marks: List<raster.RunMark>, cel: String) -> Result<Appended, String> {
    let target = frame.active_cel(art.cels, scope.frame, scope.layer);
    let ordinal = frame.clip_index(art.layers, scope.layer, length(art.layers));
    let offset = frame.placement(art.inputs.at_or(ordinal, json.null()), target);
    let rows = marks.map(fn(row) => local_mark(art.grid, offset, row));
    if length(rows.filter(fn(row) => row.fold(fn(mark) => false, fn(issue) => true))) != 0 {
        return Err("Edit lies outside the shifted cel grid");
    }
    let fallback = raster.RunMark { slot: -1, alpha: None, spans: [] };
    let local = rows.map(fn(row) => row.fold(fn(mark) => mark, fn(issue) => fallback));
    let added = local.map(fn(row) => encode_mark(art.ids, row));
    let source = frame.resolved_cel(art.cels, target);
    let next = raster.append_runs(source.fields, source.runs, local);
    return Ok(Appended { authored: authored_cel(scope, target, source.fields, cel, added), runs: next });
}

fn authored_cel(scope: frame.Scope, target: frame.Cel, source: List<json.Member>, id: String, added: List<json.Json>) -> json.Json {
    let prior = value.items(value.get(source, "marks"));
    let active = target.fields.filter(fn(item) => item.key != "hold");
    let base = if target.id == "" && id != default_id(scope) { replace(active, "id", json.text(id)) } else { active };
    let revised = replace(base, "marks", json.array(prior.concat(added)));
    let slots = json.lookup(source, "slots");
    if value.has(target.fields, "hold") {
        return json.object(slots.fold(fn(raw) => replace(revised, "slots", raw), fn(unit) => revised));
    }
    return json.object(revised);
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

fn replace_frame(row: json.Json, scope: frame.Scope, cel: json.Json) -> json.Json {
    let fields = value.fields(row);
    if value.text(value.get(fields, "id")) != scope.frame { return row; }
    let cels = value.fields(value.get(fields, "cels"));
    return json.object(replace(fields, "cels", json.object(replace(cels, scope.layer, cel))));
}

fn revise(source: json.Json, scope: frame.Scope, cel: json.Json, added: List<brush.Swatch>) -> json.Json {
    let base = value.fields(source);
    let extra = added.map(fn(row) => member(row.id, json.text(brush_paint.color_text(row.color))));
    let old_palette = value.fields(value.get(base, "palette"));
    let items = if length(extra) == 0 { base } else { replace(base, "palette", json.object(old_palette.concat(extra))) };
    let authored = value.items(value.get(items, "frames"));
    return json.object(replace(items, "frames", json.array(authored.map(fn(row) => replace_frame(row, scope, cel)))));
}

fn attach(art: frame.Artwork, scope: frame.Scope, id: String, added: Appended) -> frame.Artwork {
    let cel = frame.Cel { id: id, frame: scope.frame, layer: scope.layer, fields: value.fields(added.authored),
        runs: added.runs };
    if frame.location(art.locations, id).id != "" {
        return frame.Artwork { ..art, cels: art.cels.map(fn(row) => if row.id == id { cel } else { row }) };
    }
    return frame.Artwork { ..art, cels: art.cels.concat([cel]),
        locations: art.locations.concat([frame.Location { id: id, frame: scope.frame, layer: scope.layer }]) };
}

fn paint(source: json.Json, art: frame.Artwork, named: selection.Named, operation: json.Json,
    slots: List<i32>, frame_id: Option<String>, cel: Option<String>, cached: frame.Scope) -> Result<Edit, String> {
    let error = "A raster tool needs a layer or cel and a pencil, eraser, fill, shape or brush operation";
    let parsed: Result<List<json.Member>, String> = json.members(operation).fold(fn(rows) => Ok(rows), fn(issue) => Err(error));
    let spec = parsed?;
    if !value.only(spec, ["tool", "layer", "at", "points", "samples", "swatch", "pixelPerfect", "shape",
        "brush", "shading", "drawing", "selection"]) { return Err(error); }
    let scope = target(art, spec, frame_id, cel)?;
    let tool = decode(art.grid, art.ids, spec)?;
    return paint_target(source, art, named, scope, tool, slots, cached);
}

fn paint_target(source: json.Json, art: frame.Artwork, named: selection.Named, scope: frame.Scope, tool: Tool, slots: List<i32>, cached: frame.Scope) -> Result<Edit, String> {
    let details = protections(source, art)?;
    let limit = constraint(art.grid, named, scope.frame, tool.selection)?;
    let drawn = frame.paint_view(art, scope)?;
    let active = active_details(details, selection.named_slot(art.frames, scope.frame));
    let issue = gap_issue(art.grid, active, drawn.pixels);
    if issue != "" { return Err(issue); }
    let guard = Guard { drawn: drawn, protected: locked_pixels(art.grid, active), selected: limit };
    let delta: Result<Changes, String> = if tool.kind == "brush" { brushed(source, art, tool, guard, slots) }
        else { basic_changes(tool, guard) };
    let changes = delta?;
    let report = Report { frame: scope.frame, layer: scope.layer, cel: choose_cel(art, scope), tool: tool.kind,
        pixelCount: length(changes.sites), runs: runs(art.grid, changes.sites), pixelPerfect: tool.perfect, selection: tool.selection,
        shape: if tool.kind == "shape" { Some(shape.kind(tool.geometry)) } else { None },
        shading: optional_text(changes.shading.mode), ramp: optional_text(changes.shading.named),
        addedSwatches: changes.added.map(fn(row) => row.id) };
    if report.pixelCount == 0 {
        return Ok(Edit { document: json.null(), artwork: frame.empty_artwork(), report: report, scope: cached,
            image: selection.Image { rgba: [], palette: mask.no_palette() } });
    }
    let retained = if cached.frame == scope.frame { cached } else { frame.Scope { frame: scope.frame, layer: "" } };
    return commit_paint(source, art, scope, changes, report, details, active, retained);
}

fn optional_text(text: String) -> Option<String> { return if text == "" { None } else { Some(text) }; }

fn commit_paint(source: json.Json, art: frame.Artwork, scope: frame.Scope, changes: Changes, report: Report,
    details: List<Detail>, active: List<Detail>, retained: frame.Scope) -> Result<Edit, String> {
    let palette = if length(changes.added) == 0 { art } else {
        frame.Artwork { ..art, ids: art.ids.concat(changes.added.map(fn(row) => row.id)),
            colors: art.colors.concat(changes.added.map(fn(row) => row.color)) }
    };
    let cel = append_marks(palette, scope, changes.marks, report.cel)?;
    let next = attach(palette, scope, report.cel, cel);
    let checked: Unit = check_dependent_frames(art, next, details)?;
    let canvas = frame.paint_view(next, retained)?;
    let issue = gap_issue(art.grid, active, canvas.pixels);
    if issue != "" { return Err(issue); }
    let updated = frame.finish_view(next, canvas, retained)?;
    return Ok(Edit { document: revise(source, scope, cel.authored, changes.added), artwork: next, report: report, scope: retained,
        image: updated.image });
}
