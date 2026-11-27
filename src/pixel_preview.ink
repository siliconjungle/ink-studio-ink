module StudioPixelPreview;

import "std:json" as json;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Page { source: json.Json, art: frame.Artwork, }
record Raster { grid: mask.Grid, view: frame.PreviewView, layers: List<String>, cels: List<String>,
    swatches: List<String>, protected: List<u32>, }
record Pair { id: String, grid: mask.Grid, before: Raster, after: Raster, same_owners: Bool, same_swatches: Bool, }
record Location { layer: String, cel: String, swatch: String, }
record Sample { location: Location, underneath: Location, rgb: u32, alpha: Option<u32>,
    protected: Bool, knockout: Bool, clip: u32, }
record Site { frame: String, at: Vec2<u32>, }
record CellChange { site: Site, layer: String, before: Option<Sample>, after: Option<Sample>, }
record Exact { cells: List<CellChange>, protectedCells: List<Site>, details: List<json.Json>, grids: List<json.Json>, }
record Report { pixelCount: u32, pixels: List<CellChange>, exact: Exact, guides: List<json.Json>, }
record Settings { limit: u32, exact: Bool, }
record Scan { count: u32, rows: Buffer<CellChange>, cells: Buffer<CellChange>,
    protected_cells: Buffer<Site>, issue: String, }

fn empty_page() -> Page { return Page { source: json.null(), art: frame.empty_artwork() }; }

fn member(key: String, raw: json.Json) -> json.Member { return json.Member { key: key, value: raw }; }
fn swatch_index(slot: i32) -> u32 { return value.as_word(f64_from_i32(slot + 1)); }

fn raster(art: frame.Artwork, id: String, details: List<paint.Detail>, exact: Bool) -> Result<Raster, String> {
    let view = frame.preview_view(art, id, exact)?;
    return Ok(index_view(art, id, details, view));
}

fn index_view(art: frame.Artwork, id: String, details: List<paint.Detail>, view: frame.PreviewView) -> Raster {
    let cels = art.layers.map(fn(layer) => frame.active_cel(art.cels, id, layer.id).id);
    return Raster { grid: art.grid, view: view, layers: [""].concat(art.layers.map(fn(layer) => layer.id)),
        cels: [""].concat(cels), swatches: [""].concat(art.ids), protected: paint.locked_pixels(art.grid, details) };
}

fn protected(r: Raster, p: u32, cell: frame.Pixel) -> Bool {
    return cell.locked || mask.selected(r.protected, p);
}

fn location(r: Raster, owner: u32, slot: u32) -> Location {
    return Location { layer: r.layers.at_or(owner, ""), cel: r.cels.at_or(owner, ""), swatch: r.swatches.at_or(slot, "") };
}

fn describe(r: Raster, cell: frame.Pixel, trace: u32, locked: Bool, underneath: Bool) -> Sample {
    return Sample { location: location(r, frame.owner(trace), swatch_index(cell.slot)),
        underneath: if underneath { location(r, frame.under_owner(trace), frame.under_swatch(trace)) } else { location(r, 0, 0) },
        rgb: cell.color, alpha: Some(cell.alpha),
        protected: locked, knockout: false, clip: 255 };
}

fn same_location(pair: Pair, a: u32, b: u32) -> Bool {
    if pair.same_owners { return a == b; }
    return pair.before.layers.at_or(a, "") == pair.after.layers.at_or(b, "") &&
        pair.before.cels.at_or(a, "") == pair.after.cels.at_or(b, "");
}

fn same_swatch(pair: Pair, a: i32, b: i32) -> Bool {
    if pair.same_swatches { return a == b; }
    return pair.before.swatches.at_or(swatch_index(a), "") == pair.after.swatches.at_or(swatch_index(b), "");
}

fn site(pair: Pair, p: u32) -> Site {
    return Site { frame: pair.id, at: vec2(rem_or(p, pair.grid.width, 0), quot_or(p, pair.grid.width, 0)) };
}

record Side { cell: frame.Pixel, trace: u32, locked: Bool, inside: Bool, }

fn at_grid(grid: mask.Grid, point: Vec2<u32>) -> u32 {
    if point.x >= grid.width || point.y >= grid.height { return 4294967295; }
    return point.y * grid.width + point.x;
}

fn read_side(r: Raster, located: Site) -> Side {
    let p = at_grid(r.grid, located.at);
    let cell = r.view.pixels.at_or(p, frame.blank());
    return Side { cell: cell, trace: r.view.trace.at_or(p, 0),
        locked: p != 4294967295 && protected(r, p, cell), inside: p != 4294967295 };
}

fn maybe_sample(side: Side, sample: Sample) -> Option<Sample> {
    return if side.inside { Some(sample) } else { None };
}

fn scan_pixel(pair: Pair, settings: Settings, p: u32, out: Scan) -> Scan {
    let located = site(pair, p);
    let left = read_side(pair.before, located);
    let right = read_side(pair.after, located);
    let changed = left.cell.color != right.cell.color || left.cell.alpha != right.cell.alpha ||
        !same_location(pair, frame.owner(left.trace), frame.owner(right.trace)) ||
        !same_swatch(pair, left.cell.slot, right.cell.slot) || left.locked != right.locked;
    let exact = settings.exact && (changed || left.inside != right.inside);
    let summary = changed && out.rows.len() < settings.limit;
    if !summary && !exact { return Scan { ..out, count: out.count + (if changed { 1 } else { 0 }) }; }
    let front = describe(pair.before, left.cell, left.trace, left.locked, summary);
    let back = describe(pair.after, right.cell, right.trace, right.locked, summary);
    return save_pixel(pair, located, left, right, front, back, changed, summary, exact, out);
}

fn save_pixel(pair: Pair, located: Site, left: Side, right: Side, front: Sample, back: Sample,
    changed: Bool, summary: Bool, exact: Bool, out: Scan) -> Scan {
    let cell = CellChange { site: located, layer: "", before: maybe_sample(left, front), after: maybe_sample(right, back) };
    let cells = if exact { out.cells.push(cell) } else { out.cells };
    let guards = if exact && (left.locked || right.locked) { out.protected_cells.push(located) } else { out.protected_cells };
    let counted = Scan { ..out, count: out.count + (if changed { 1 } else { 0 }), cells: cells, protected_cells: guards };
    if !summary { return counted; }
    let a = pair.before.view.uses_alpha;
    let b = pair.after.view.uses_alpha;
    let different = (a || b) && left.cell.alpha != right.cell.alpha;
    let x = if a || different { front } else { Sample { ..front, alpha: None } };
    let y = if b || different { back } else { Sample { ..back, alpha: None } };
    let row = CellChange { ..cell, before: maybe_sample(left, x), after: maybe_sample(right, y) };
    return Scan { ..counted, rows: counted.rows.push(row) };
}

fn describe_raw(r: Raster, layer: u32, slot: i32, alpha: u32, clip: u32, rgb: u32) -> Option<Sample> {
    if slot == -1 { return None; }
    return Some(Sample { location: location(r, layer, swatch_index(slot)), underneath: location(r, 0, 0),
        rgb: rgb, alpha: Some(alpha), protected: false, knockout: slot == -2, clip: clip });
}

fn raw_pixel(pair: Pair, palette_a: List<u32>, palette_b: List<u32>, a: frame.RawLayer, b: frame.RawLayer,
    p: u32, out: Scan) -> Scan {
    let at = site(pair, p);
    let src = at_grid(pair.before.grid, at.at);
    let dst = at_grid(pair.after.grid, at.at);
    let left = a.view.slots.at_or(src, -1);
    let right = b.view.slots.at_or(dst, -1);
    if left == -1 && right == -1 { return out; }
    let alpha_a = if left < 0 { 0 } else { a.view.alpha.at_or(src, 255) };
    let alpha_b = if right < 0 { 0 } else { b.view.alpha.at_or(dst, 255) };
    let clip_a = a.view.clipping.at_or(src, 255);
    let clip_b = b.view.clipping.at_or(dst, 255);
    let rgb_a = if left < 0 { 0 } else { frame.color_at(palette_a, left) };
    let rgb_b = if right < 0 { 0 } else { frame.color_at(palette_b, right) };
    if (left >= 0 && right >= 0 || left == right) && alpha_a == alpha_b && clip_a == clip_b && rgb_a == rgb_b &&
        same_location(pair, a.owner, b.owner) && same_swatch(pair, left, right) { return out; }
    let row = CellChange { site: at, layer: pair.after.layers.at_or(b.owner, ""),
        before: describe_raw(pair.before, a.owner, left, alpha_a, clip_a, rgb_a),
        after: describe_raw(pair.after, b.owner, right, alpha_b, clip_b, rgb_b) };
    return Scan { ..out, cells: out.cells.push(row) };
}

fn scan_layer(pair: Pair, a: List<u32>, b: List<u32>, i: u32, out: Scan) -> Scan {
    let empty = frame.RawLayer { owner: 0, view: frame.no_capture() };
    let left = pair.before.view.sources.at_or(i, empty);
    let right = pair.after.view.sources.at_or(i, empty);
    if left == right && pair.same_owners && pair.same_swatches && a == b { return out; }
    return repeat_until(mask.size(pair.grid), out, fn(next) => false,
        fn(p) => fn(next) => raw_pixel(pair, a, b, left, right, p, next));
}

fn unchanged(before: frame.Artwork, after: frame.Artwork, id: String) -> Bool {
    return repeat_until(length(after.layers), true, fn(same) => !same, fn(i) => fn(same) =>
        same_cel(before.cels, after.cels, id, after.layers.at_or(i, frame.empty_layer()).id));
}

fn same_cel(before: List<frame.Cel>, after: List<frame.Cel>, id: String, layer: String) -> Bool {
    let a = frame.active_cel(before, id, layer);
    let b = frame.active_cel(after, id, layer);
    return a == b && (!value.has(a.fields, "hold") || frame.resolved_cel(before, a) == frame.resolved_cel(after, b));
}

fn compare_frame(before: frame.Artwork, after: frame.Artwork, a: List<paint.Detail>, b: List<paint.Detail>,
    id: String, index: u32, prior_index: u32, same_stack: Bool, settings: Settings, out: Scan) -> Scan {
    let left_details = paint.active_details(a, prior_index);
    let right_details = paint.active_details(b, index);
    let existing = prior_index < length(before.frames);
    if existing && same_stack && left_details == right_details && unchanged(before, after, id) {
        return out;
    }
    let views = frame_pair(before, after, id, left_details, right_details, existing, settings.exact);
    return match views {
        Ok(pair) => scan_frame(pair, before.colors, after.colors, settings, out),
        Err(issue) => Scan { ..out, issue: issue },
    };
}

fn scan_frame(pair: Pair, a: List<u32>, b: List<u32>, settings: Settings, out: Scan) -> Scan {
    let composite = repeat_until(mask.size(pair.grid), out, fn(next) => false,
        fn(p) => fn(next) => scan_pixel(pair, settings, p, next));
    return repeat_until(length(pair.after.view.sources), composite, fn(next) => false,
        fn(i) => fn(next) => scan_layer(pair, a, b, i, next));
}

fn frame_pair(before: frame.Artwork, after: frame.Artwork, id: String,
    a: List<paint.Detail>, b: List<paint.Detail>, existing: Bool, exact: Bool) -> Result<Pair, String> {
    let prior: Result<Raster, String> = if existing { raster(before, id, a, exact) }
        else { Ok(index_view(frame.empty_artwork(), id, [], frame.PreviewView { pixels: [], trace: [], uses_alpha: false, sources: [] })) };
    let left = prior?;
    let right = raster(after, id, b, exact)?;
    let grid = mask.Grid { width: max_word(before.grid.width, after.grid.width),
        height: max_word(before.grid.height, after.grid.height) };
    return Ok(pair(id, grid, left, right));
}

fn pair(id: String, grid: mask.Grid, left: Raster, right: Raster) -> Pair {
    return Pair { id: id, grid: grid, before: left, after: right,
        same_owners: left.layers == right.layers && left.cels == right.cels,
        same_swatches: left.swatches == right.swatches };
}

fn composite_diff(pair: Pair, limit: u32) -> Report {
    let start = Scan { count: 0, rows: Buffer.empty(), cells: Buffer.empty(), protected_cells: Buffer.empty(), issue: "" };
    let settings = Settings { limit: limit, exact: false };
    let changes = repeat_until(mask.size(pair.grid), start, fn(out) => false,
        fn(p) => fn(out) => scan_pixel(pair, settings, p, out));
    return Report { pixelCount: changes.count, pixels: changes.rows.freeze(),
        exact: Exact { cells: [], protectedCells: [], details: [], grids: [] }, guides: [] };
}

fn details(source: json.Json) -> List<json.Member> {
    return value.items(value.get(value.fields(source), "protectedDetails")).map(fn(row) =>
        member(value.text(value.get(value.fields(row), "id")), row));
}

fn detail_diff(before: json.Json, after: json.Json) -> List<json.Json> {
    let a = details(before);
    let b = details(after);
    let keys = a.concat(b.filter(fn(row) => !value.has(a, row.key)));
    return keys.filter(fn(row) => value.get(a, row.key) != value.get(b, row.key)).map(fn(row) =>
        detail_row(row.key, json.lookup(a, row.key), json.lookup(b, row.key)));
}

fn detail_row(id: String, before: Option<json.Json>, after: Option<json.Json>) -> json.Json {
    let a = before.fold(fn(row) => [member("before", row)], fn(unit) => []);
    let b = after.fold(fn(row) => [member("after", row)], fn(unit) => []);
    return json.object([member("key", json.text(id))].concat(a).concat(b));
}

fn max_word(a: u32, b: u32) -> u32 { return if a > b { a } else { b }; }

fn grid_array(g: mask.Grid) -> json.Json {
    return json.array([json.number(frame.decimal(g.width)), json.number(frame.decimal(g.height))]);
}

fn changed_grids(before: frame.Artwork, after: frame.Artwork, added: List<String>, exact: Bool) -> List<json.Json> {
    if !exact || (before.grid == after.grid && length(added) == 0) { return []; }
    let left = grid_array(before.grid);
    let right = grid_array(after.grid);
    let common: List<String> = if before.grid == after.grid { [] } else { before.frames };
    return common.map(fn(id) => grid_change(id, left, right))
        .concat(added.map(fn(id) => grid_change(id, json.null(), right)));
}

fn grid_change(id: String, before: json.Json, after: json.Json) -> json.Json {
    return json.object([member("frame", json.text(id)), member("before", before), member("after", after)]);
}

fn append_new_frames<T>(rows: List<T>, added: List<String>, frame_id: fn(T) -> String) -> List<T> {
    if length(added) == 0 { return rows; }
    return rows.filter(fn(row) => !frame.known_frame(added, frame_id(row)))
        .concat(rows.filter(fn(row) => frame.known_frame(added, frame_id(row))));
}

fn guide_rows(source: json.Json) -> List<json.Member> {
    return value.items(value.get(value.fields(source), "guides")).map(fn(row) =>
        member(value.text(value.get(value.fields(row), "id")), row));
}

fn changed_guides(before: json.Json, after: json.Json) -> List<json.Json> {
    let a = guide_rows(before);
    let b = guide_rows(after);
    let keys = a.concat(b.filter(fn(row) => !value.has(a, row.key)));
    return keys.filter(fn(row) => !same_guide(value.get(a, row.key), value.get(b, row.key))).map(fn(row) =>
        guide_row(row.key, value.get(a, row.key), value.get(b, row.key)));
}

fn same_guide(before: json.Json, after: json.Json) -> Bool {
    if before == after { return true; }
    let left = value.fields(before);
    let right = value.fields(after);
    return length(left) == length(right) && foldl(left, true,
        fn(row) => fn(equal) => equal && value.get(right, row.key) == row.value);
}

fn guide_target(before: json.Json, after: json.Json) -> json.Json {
    let changes = changed_guides(before, after).map(fn(row) => json.object(
        value.fields(row).filter(fn(entry) => entry.key == "id" || entry.key == "change")));
    return json.object([member("kind", json.text("guides")), member("guides", json.array(changes))]);
}

fn guide_row(id: String, before: json.Json, after: json.Json) -> json.Json {
    let kind = if before == json.null() { "added" } else { if after == json.null() { "removed" } else { "modified" } };
    return json.object([member("id", json.text(id)), member("change", json.text(kind)),
        member("before", before), member("after", after)]);
}

fn compare(before: frame.Artwork, before_source: json.Json, after: frame.Artwork, after_source: json.Json,
    settings: Settings) -> Result<Report, String> {
    let a = paint.protections(before_source, before)?;
    let b = paint.protections(after_source, after)?;
    let details = if settings.exact { detail_diff(before_source, after_source) } else { [] };
    let same_frames = before.frames == after.frames;
    let added: List<String> = if !settings.exact || same_frames { [] }
        else { after.frames.filter(fn(id) => !frame.known_frame(before.frames, id)) };
    let grids = changed_grids(before, after, added, settings.exact);
    let guides = changed_guides(before_source, after_source);
    if before == after && a == b {
        return Ok(Report { pixelCount: 0, pixels: [], exact: Exact { cells: [], protectedCells: [], details: details,
            grids: grids }, guides: guides });
    }
    let same_stack = before.grid == after.grid && before.inputs == after.inputs && before.ids == after.ids && before.colors == after.colors;
    let frames = after.frames;
    let initial = Scan { count: 0, rows: Buffer.empty(), cells: Buffer.empty(), protected_cells: Buffer.empty(), issue: "" };
    let result = repeat_until(length(frames), initial, fn(next) => next.issue != "", fn(i) => fn(out) =>
        compare_frame(before, after, a, b, frames.at_or(i, ""), i,
            if same_frames { i } else { selection.named_slot(before.frames, frames.at_or(i, "")) }, same_stack, settings, out));
    if result.issue != "" { return Err(result.issue); }
    let cells = append_new_frames<CellChange>(result.cells.freeze(), added, fn(row) => row.site.frame);
    let protected_cells = append_new_frames<Site>(result.protected_cells.freeze(), added, fn(row) => row.frame);
    return Ok(Report { pixelCount: result.count, pixels: result.rows.freeze(),
        exact: Exact { cells: cells, protectedCells: protected_cells, details: details, grids: grids }, guides: guides });
}
