module StudioPixelTilemapRender;

import "std:json" as json;
import "pixel_frame.ink" as frame;
import "pixel_labels.ink" as labels;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_tilemap.ink" as tilemap;
import "pixel_timeline.ink" as timeline;
import "pixel_values.ink" as value;

record FrameIndex { id: String, index: u32, }
record Rule { connections: List<u32>, variants: List<u32>, frame_id: u32,
    animation: List<u32>, durations: List<f64>, plan: Option<timeline.Playback>, }
record Preview { size: mask.Grid, tiles: List<u32>, rules: List<Rule>, }
record Layout { size: mask.Grid, cells: List<Cell>, rules: List<Rule>, variants: List<json.Member>, counts: List<u32>, }
record Motion { frame_id: u32, step: Option<u32>, }
record Cell { tile: u32, variant: u32, frame_id: u32, mask_id: u32, step: Option<u32>, outside: Bool, }
record Clock { end: f64, exposure: u32, found: Bool, }
record Groups { heads: Buffer<u32>, next: Buffer<u32>, }
record Draw { pixels: Buffer<u32>, issue: String, }
record Image { width: u32, height: u32, pixels: List<u32>, }
record Window { report: json.Json, image: Image, }
record Counts { coverage: u32, color: u32, }

fn member(key: String, raw: json.Json) -> json.Member { return tilemap.member(key, raw); }
fn number(n: u32) -> json.Json { return tilemap.number(n); }
fn signed(n: i32) -> json.Json { return timeline.number(f64_from_i32(n)); }
fn point(x: i32, y: i32) -> json.Json { return json.array([signed(x), signed(y)]); }
fn dimensions(g: mask.Grid) -> json.Json { return tilemap.point(g.width, g.height); }
fn missing() -> u32 { return 4294967295; }

fn grids(source: json.Json, art: frame.Artwork) -> Result<tilemap.Grid, String> {
    let rows = value.fields(source);
    if !value.has(rows, "tilemap") { return Err("Create a tilemap in a version 2 pixel document"); }
    return tilemap.prepare(value.get(rows, "tilemap"), art.frames, art.grid);
}

fn indices(ids: List<String>) -> Map<u64, List<FrameIndex>> {
    var lookup: Map<u64, List<FrameIndex>> = Map.empty();
    var i: u32 = 1;
    for id in ids {
        let key = labels.id_hash(id);
        let bucket = lookup.get_or(key, []);
        lookup = lookup.set(key, bucket.concat([FrameIndex { id: id, index: i }]));
        i = i + 1;
    }
    return lookup;
}

fn frame_index(bucket: List<FrameIndex>, id: String) -> u32 {
    return foldl(bucket, 0, fn(row) => fn(found) => if row.id == id { row.index } else { found });
}

fn tile_ids(tiles: List<String>, ids: List<String>) -> List<u32> {
    let lookup = indices(ids);
    return tiles.map(fn(id) => if id == "" { 0 } else { frame_index(lookup.get_or(labels.id_hash(id), []), id) });
}

fn frame_id(ids: List<String>, index: u32) -> json.Json {
    return if index == 0 { json.null() } else { json.text(ids.at_or(index - 1, "")) };
}

fn masks() -> List<String> {
    return ["none", "N", "E", "NE", "S", "NS", "ES", "NES", "W", "NW", "EW", "NEW", "SW", "NSW", "ESW", "NESW"];
}

fn elapsed(time: f64) -> Result<f64, String> {
    let ms = time * 1000.0f64;
    if !is_finite(ms) || ms < 0.0f64 || ms > 9007199254740991.0f64 {
        return Err("Tile preview time needs finite nonnegative seconds");
    }
    return Ok(ms);
}

fn cycle(ms: f64, duration: f64) -> f64 {
    let whole = floor(ms);
    let ticks = u64_from_f64(whole).fold(fn(n) => n, fn(unit) => 0);
    let period = u64_from_f64(duration).fold(fn(n) => n, fn(unit) => 1);
    return f64_from_u64(rem_or(ticks, period, 0)) + (ms - whole);
}

fn exposure(plan: timeline.Playback, durations: List<f64>, ms: f64) -> u32 {
    let first: Buffer<u32> = Buffer.empty();
    let out = timeline.exposure_pass(plan, 0, first);
    let order = (if plan.bounce { timeline.exposure_pass(plan, 1, out) } else { out }).freeze();
    let time = if plan.loop { cycle(ms, timeline.playback_duration(plan, durations)) } else { ms };
    let start = Clock { end: 0.0f64, exposure: order.at_or(0, 0), found: false };
    return repeat_until(length(order), start, fn(clock) => clock.found, fn(i) => fn(clock) =>
        tick(clock, order.at_or(i, 0), durations, time)).exposure;
}

fn tick(clock: Clock, step: u32, durations: List<f64>, time: f64) -> Clock {
    let end = clock.end + durations.at_or(step, 0.0f64);
    return Clock { end: end, exposure: step, found: time < end };
}

fn lookup_id(ids: List<String>, name: String) -> u32 {
    let i = selection.named_slot(ids, name);
    return if i >= length(ids) { 0 } else { i + 1 };
}

fn rule(id: String, ordinal: u32, grid: tilemap.Grid, ids: List<String>, durations: List<f64>) -> Rule {
    let row = value.fields(value.get(grid.variants, id));
    let links = value.fields(value.get(row, "neighbors"));
    let options: List<u32> = if length(links) == 0 { [] } else { masks().map(fn(key) =>
        json.lookup(links, key).fold(fn(raw) => lookup_id(ids, value.text(raw)), fn(unit) => ordinal)) };
    let connections: List<u32> = if length(links) == 0 { [] } else {
        tilemap.connections(row, id).map(fn(name) => lookup_id(ids, name))
    };
    let animation = value.fields(value.get(row, "animation"));
    let frames = value.items(value.get(animation, "frames")).map(fn(raw) => lookup_id(ids, value.text(raw)));
    let steps = frames.map(fn(i) => durations.at_or(i - 1, 0.0f64));
    let plan: Option<timeline.Playback> = if length(steps) == 0 { None } else { Some(tilemap.playback(animation, length(steps))) };
    return Rule { connections: connections, variants: options, frame_id: ordinal, animation: frames, durations: steps, plan: plan };
}

fn no_rule() -> Rule {
    return Rule { connections: [], variants: [], frame_id: 0, animation: [], durations: [], plan: None };
}

fn outlook(source: json.Json, grid: tilemap.Grid, ids: List<String>) -> Preview {
    let rows = value.items(value.get(value.fields(source), "frames"));
    let durations = rows.map(fn(row) => value.number(value.get(value.fields(row), "durationMs")));
    let rules = [no_rule()].concat(ids.map_indexed(fn(i) => fn(id) => rule(id, i + 1, grid, ids, durations)));
    return Preview { size: grid.size, tiles: tile_ids(grid.tiles, ids), rules: rules };
}

fn has_link(ids: List<u32>, tile: u32) -> Bool {
    return tile != 0 && foldl(ids, false, fn(id) => fn(found) => found || id == tile);
}

fn neighbor_mask(preview: Preview, pos: u32, ids: List<u32>) -> u32 {
    let width = preview.size.width;
    let x = rem_or(pos, width, 0);
    let east: u32 = if x + 1 < width && has_link(ids, preview.tiles.at_or(pos + 1, 0)) { 2 } else { 0 };
    let west: u32 = if x > 0 && has_link(ids, preview.tiles.at_or(pos - 1, 0)) { 8 } else { 0 };
    let north: u32 = if pos >= width && has_link(ids, preview.tiles.at_or(pos - width, 0)) { 1 } else { 0 };
    let south: u32 = if has_link(ids, preview.tiles.at_or(pos + width, 0)) { 4 } else { 0 };
    return north + east + south + west;
}

fn empty_cell(outside: Bool) -> Cell {
    return Cell { tile: 0, variant: 0, frame_id: 0, mask_id: missing(), step: None, outside: outside };
}

fn resolve(preview: Preview, pos: u32) -> Cell {
    if pos >= length(preview.tiles) { return empty_cell(true); }
    let tile = preview.tiles.at_or(pos, 0);
    if tile == 0 { return empty_cell(false); }
    let base = preview.rules.at_or(tile, no_rule());
    let mask_id = if length(base.variants) == 0 { missing() } else { neighbor_mask(preview, pos, base.connections) };
    let variant = base.variants.at_or(mask_id, tile);
    return Cell { tile: tile, variant: variant, frame_id: variant, mask_id: mask_id, step: None, outside: false };
}

fn layout(source: json.Json, art: frame.Artwork) -> Result<Layout, String> {
    let grid = grids(source, art)?;
    let preview = outlook(source, grid, art.frames);
    let cells = preview.tiles.map_indexed(fn(i) => fn(n) => if n == 0 { empty_cell(false) } else { resolve(preview, i) });
    return Ok(Layout { size: preview.size, cells: cells, rules: preview.rules, variants: grid.variants,
        counts: count_tiles(preview.tiles, length(art.frames)) });
}

fn motions(layout: Layout, ms: f64) -> List<Motion> {
    return layout.rules.map(fn(rule) => rule.plan.fold(fn(plan) => animate(rule, plan, ms),
        fn(unit) => Motion { frame_id: rule.frame_id, step: None }));
}

fn animate(rule: Rule, plan: timeline.Playback, ms: f64) -> Motion {
    let i = exposure(plan, rule.durations, ms);
    return Motion { frame_id: rule.animation.at_or(i, rule.frame_id), step: Some(i) };
}

fn frame_now(motion: List<Motion>, variant: u32) -> Motion {
    return motion.at_or(variant, Motion { frame_id: 0, step: None });
}

fn groups(tiles: List<u32>, count: u32) -> Groups {
    let start = Groups { heads: buffer_fill(count + 1, missing()), next: buffer_fill(length(tiles), missing()) };
    return repeat_until(length(tiles), start, fn(out) => false,
        fn(i) => fn(out) => group(out, i, tiles.at_or(i, 0)));
}

fn group(out: Groups, i: u32, id: u32) -> Groups {
    if id == 0 { return out; }
    let first = out.heads.at_or(id, missing());
    return Groups { heads: out.heads.set(id, i), next: out.next.set(i, first) };
}

fn packed(pixel: frame.Pixel) -> u32 {
    return if pixel.slot < 0 { 0 } else { frame.rgba(pixel.color, pixel.alpha) };
}

fn bitmap(art: frame.Artwork, detail: List<paint.Detail>, i: u32) -> Result<List<u32>, String> {
    let id = art.frames.at_or(i, "");
    let picture = frame.paint_view(art, frame.Scope { frame: id, layer: "" })?;
    let problem = paint.gap_issue(art.grid, paint.active_details(detail, i), picture.pixels);
    if problem != "" { return Err(problem); }
    return Ok(picture.pixels.map(fn(pixel) => packed(pixel)));
}

fn blit(at: u32, size: mask.Grid, tile: mask.Grid, total: u32, out: Buffer<u32>) -> Buffer<u32> {
    let x = rem_or(at, size.width, 0) * tile.width;
    let y = quot_or(at, size.width, 0) * tile.height;
    let stride = size.width * tile.width;
    return repeat_until(tile.height, out, fn(next) => false, fn(row) => fn(next) =>
        next.copy_within(total + row * tile.width, (y + row) * stride + x, tile.width));
}

record Copy { at: u32, pixels: Buffer<u32>, }

fn draw_group(out: Draw, bitmap: Result<List<u32>, String>, size: mask.Grid, tile: mask.Grid,
    first: u32, next: List<u32>) -> Draw {
    return match bitmap {
        Ok(picture) => stage_group(out, picture, size, tile, first, next),
        Err(issue) => Draw { ..out, issue: issue },
    };
}

fn stage_group(out: Draw, bitmap: List<u32>, size: mask.Grid, tile: mask.Grid, first: u32, next: List<u32>) -> Draw {
    let total = out.pixels.len();
    let placed = Copy { at: first, pixels: out.pixels.append(buffer(bitmap)) };
    let copied = repeat_until(length(next), placed, fn(copy) => copy.at == missing(),
        fn(i) => fn(copy) => Copy { at: next.at_or(copy.at, missing()), pixels: blit(copy.at, size, tile, total, copy.pixels) });
    return Draw { pixels: copied.pixels.truncate(total), issue: "" };
}

fn compose(source: json.Json, art: frame.Artwork, size: mask.Grid, tiles: List<u32>) -> Result<Image, String> {
    let detail = paint.protections(source, art)?;
    let placements = groups(tiles, length(art.frames));
    let heads = placements.heads.freeze();
    let next = placements.next.freeze();
    let w = size.width * art.grid.width;
    let h = size.height * art.grid.height;
    var out: Draw = Draw { pixels: buffer_fill(w * h, 0), issue: "" };
    var id: u32 = 0;
    for head in heads {
        if head != missing() && out.issue == "" {
            out = draw_group(out, bitmap(art, detail, id - 1), size, art.grid, head, next);
        }
        id = id + 1;
    }
    if out.issue != "" { return Err(out.issue); }
    return Ok(Image { width: w, height: h, pixels: out.pixels.freeze() });
}

fn render(source: json.Json, art: frame.Artwork, prepared: Result<Layout, String>, time: f64) -> Result<Image, String> {
    let ms = elapsed(time)?;
    let layout = prepared?;
    let motion = motions(layout, ms);
    return compose(source, art, layout.size, layout.cells.map(fn(cell) => frame_now(motion, cell.variant).frame_id));
}

fn checked_point(grid: mask.Grid, at: json.Json) -> Result<u32, String> {
    let p = tilemap.index(grid, at);
    if p >= mask.size(grid) { return Err("Pick a cell inside the tilemap"); }
    return Ok(p);
}

fn count_tiles(tiles: List<u32>, count: u32) -> List<u32> {
    let start: Buffer<u32> = buffer_fill(count + 1, 0);
    return repeat_until(length(tiles), start, fn(out) => false, fn(i) => fn(out) =>
        increment(out, tiles.at_or(i, 0))).freeze();
}

fn increment(out: Buffer<u32>, id: u32) -> Buffer<u32> {
    if id == 0 { return out; }
    let prior = out.at_or(id, 0);
    return out.set(id, prior + 1);
}

fn tile_row(raw: json.Json, count: u32) -> json.Json {
    let row = value.fields(raw);
    let id = value.get(row, "id");
    let label = json.lookup(row, "label").fold(fn(text) => text, fn(unit) => id);
    return json.object([member("id", id), member("label", label), member("placements", number(count))]);
}

fn inspect(source: json.Json, art: frame.Artwork, prepared: Result<Layout, String>, revision: String, at: json.Json) ->
    Result<json.Json, String> {
    let layout = prepared?;
    let map = value.fields(value.get(value.fields(source), "tilemap"));
    let frames = value.items(value.get(value.fields(source), "frames"));
    let counts = layout.counts;
    let tiles = frames.map_indexed(fn(i) => fn(row) => tile_row(row, counts.at_or(i + 1, 0)));
    let info = [member("format", json.text("ink-studio/pixel-tilemap-report")), member("version", number(1)),
        member("revision", json.text(revision)), member("grid", dimensions(layout.size)), member("tileSize", dimensions(art.grid))];
    let size = tilemap.point(layout.size.width * art.grid.width, layout.size.height * art.grid.height);
    let rest = [member("rasterSize", size), member("cells", value.get(map, "cells")), member("tiles", json.array(tiles))];
    let picked: Result<List<json.Member>, String> = if at == json.null() { Ok([]) } else { inspect_point(source, art, layout, at) };
    let extras = picked?;
    return Ok(json.object(info.concat(rest).concat(extras)));
}

fn inspect_point(source: json.Json, art: frame.Artwork, layout: Layout, at: json.Json) -> Result<List<json.Member>, String> {
    let p = checked_point(layout.size, at)?;
    let tile = layout.cells.at_or(p, empty_cell(false)).tile;
    let id = frame_id(art.frames, tile);
    let found: Result<List<String>, String> = if tile == 0 { Ok([]) }
        else { tilemap.exact_matches(source, art, layout.variants, value.text(id)) };
    let ids = found?;
    let picked = json.object([member("at", at), member("tile", id)]);
    return Ok([member("picked", picked), member("exactMatches", json.array(ids.map(fn(id) => json.text(id))))]);
}

fn signed_index(n: u32) -> i32 {
    return i32_from_f64(f64_from_u32(n)).fold(fn(i) => i, fn(unit) => 0);
}

fn offset(i: u32) -> Vec2<i32> {
    return vec2(signed_index(rem_or(i, 3, 0)) - 1, signed_index(quot_or(i, 3, 0)) - 1);
}

fn locate(size: mask.Grid, x: i32, y: i32) -> u32 {
    if x < 0 || y < 0 || x >= signed_index(size.width) || y >= signed_index(size.height) { return missing(); }
    return value.as_word(f64_from_i32(y)) * size.width + value.as_word(f64_from_i32(x));
}

fn anchor(size: mask.Grid, p: u32) -> Vec2<i32> {
    return vec2(signed_index(rem_or(p, size.width, 0)), signed_index(quot_or(p, size.width, 0)));
}

fn window_cell(art: frame.Artwork, center: Vec2<i32>, i: u32, cell: Cell) -> json.Json {
    let delta = offset(i);
    let xy = [member("at", point(center.x + delta.x, center.y + delta.y)), member("offset", point(delta.x, delta.y))];
    let refs = [member("tile", frame_id(art.frames, cell.tile)), member("variant", frame_id(art.frames, cell.variant)),
        member("frame", frame_id(art.frames, cell.frame_id))];
    let edge: List<json.Member> = if cell.outside { [member("outside", json.boolean(true))] } else { [] };
    let mask_field: List<json.Member> = if cell.mask_id == missing() { [] } else {
        [member("mask", json.text(masks().at_or(cell.mask_id, "none")))]
    };
    let timed = cell.step.fold(fn(i) => [member("step", number(i))], fn(unit) => []);
    return json.object(xy.concat(refs).concat(edge).concat(mask_field).concat(timed));
}

fn add_seam(a: u32, b: u32, prior: Counts) -> Counts {
    let left = a & 255;
    let right = b & 255;
    return Counts { coverage: prior.coverage + (if left != right { 1 } else { 0 }),
        color: prior.color + (if left != 0 && right != 0 && wrapping_shr(a, 8) != wrapping_shr(b, 8) { 1 } else { 0 }) };
}

fn side_seam(image: Image, g: mask.Grid, center: Vec2<i32>, side: u32) -> json.Json {
    let edges: List<u32> = [1, 5, 7, 3];
    let delta = offset(edges.at_or(side, 0));
    let horizontal = delta.x != 0;
    let length = if horizontal { g.height } else { g.width };
    let x = if delta.x > 0 { 2 * g.width - 1 } else { g.width };
    let y = if delta.y > 0 { 2 * g.height - 1 } else { g.height };
    let start = if horizontal { g.height * image.width + x } else { y * image.width + g.width };
    let jump = if horizontal { image.width } else { 1 };
    let other = if delta.x > 0 || delta.y > 0 { start + (if horizontal { 1 } else { image.width }) }
        else { start - (if horizontal { 1 } else { image.width }) };
    let counts = repeat_until(length, Counts { coverage: 0, color: 0 }, fn(out) => false,
        fn(i) => fn(out) => add_seam(image.pixels.at_or(start + i * jump, 0), image.pixels.at_or(other + i * jump, 0), out));
    let names = ["N", "E", "S", "W"];
    return json.object([member("side", json.text(names.at_or(side, ""))),
        member("at", point(center.x + delta.x, center.y + delta.y)), member("length", number(length)),
        member("coverage", number(counts.coverage)), member("color", number(counts.color))]);
}

fn window(source: json.Json, art: frame.Artwork, prepared: Result<Layout, String>, revision: String, at: json.Json, time: f64) ->
    Result<Window, String> {
    let layout = prepared?;
    let p = checked_point(layout.size, at)?;
    let ms = elapsed(time)?;
    let center = anchor(layout.size, p);
    let motion = motions(layout, ms);
    let neighbors: List<u32> = [0, 1, 2, 3, 4, 5, 6, 7, 8];
    let cells = neighbors.map(fn(i) => resolve_offset(layout, center, offset(i), motion));
    return draw_window(source, art, cells, center, [member("revision", json.text(revision)), member("at", at),
        member("time", timeline.number(time))]);
}

fn draw_window(source: json.Json, art: frame.Artwork, cells: List<Cell>, center: Vec2<i32>, context: List<json.Member>) ->
    Result<Window, String> {
    let picture = compose(source, art, mask.Grid { width: 3, height: 3 }, cells.map(fn(row) => row.frame_id))?;
    let states = cells.map_indexed(fn(i) => fn(row) => window_cell(art, center, i, row));
    let sides: List<u32> = [0, 1, 2, 3];
    let seams = sides.map(fn(side) => side_seam(picture, art.grid, center, side));
    let format = [member("format", json.text("ink-studio/pixel-tilemap-neighborhood")), member("version", number(1))];
    let report = json.object(format.concat(context).concat([member("tileSize", dimensions(art.grid)),
        member("cells", json.array(states)), member("seams", json.array(seams))]));
    return Ok(Window { report: report, image: picture });
}

fn resolve_offset(layout: Layout, center: Vec2<i32>, delta: Vec2<i32>, motion: List<Motion>) -> Cell {
    let p = locate(layout.size, center.x + delta.x, center.y + delta.y);
    let row = layout.cells.at_or(p, empty_cell(true));
    let current = frame_now(motion, row.variant);
    return Cell { ..row, frame_id: current.frame_id, step: current.step };
}
