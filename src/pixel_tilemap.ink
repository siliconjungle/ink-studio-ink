module StudioPixelTilemap;

import "std:json" as json;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_raster.ink" as raster;
import "pixel_selection.ink" as selection;
import "pixel_timeline.ink" as timeline;
import "pixel_values.ink" as value;

record Grid { size: mask.Grid, tiles: List<String>, variants: List<json.Member>, }
record Stroke { tilemap: json.Json, changes: List<json.Json>, }
record Placement { tiles: Buffer<String>, changes: Buffer<json.Json>, }
record Loaded { tiles: Buffer<String>, issue: String, }
record Artwork { slots: List<i32>, alpha: List<u32>, issue: String, placement: frame.Placement, }

fn member(key: String, raw: json.Json) -> json.Member { return paint.member(key, raw); }
fn number(n: u32) -> json.Json { return json.number(frame.decimal(n)); }
fn point(x: u32, y: u32) -> json.Json { return json.array([number(x), number(y)]); }
fn cell_point(g: mask.Grid, p: u32) -> json.Json { return point(rem_or(p, g.width, 0), quot_or(p, g.width, 0)); }
fn tile_value(tile: String) -> json.Json { return if tile == "" { json.null() } else { json.text(tile) }; }

fn index(g: mask.Grid, at: json.Json) -> u32 {
    let p = selection.point(value.items(at), g);
    return if selection.inside(p, g) { mask.index(g, p) } else { 4294967295 };
}

fn belongs(raw: json.Json, frames: List<String>) -> Bool { return commands.includes(frames, value.text(raw)); }

fn unique(names: List<String>) -> Bool {
    let initial: List<String> = [];
    let distinct = foldl(names, initial, fn(name) => fn(out) =>
        if commands.includes(out, name) { out } else { out.concat([name]) });
    return length(names) == length(distinct);
}

fn connect(row: List<json.Member>, frames: List<String>) -> Bool {
    if !value.has(row, "connects") { return true; }
    let raw = value.items(value.get(row, "connects"));
    return value.get(row, "neighbors") != json.null() && length(raw) != 0 &&
        foldl(raw, true, fn(name) => fn(ok) => ok && belongs(name, frames)) && unique(raw.map(fn(name) => value.text(name)));
}

fn masks() -> List<String> {
    return ["none", "N", "E", "S", "W", "NE", "NS", "NW", "ES", "EW", "SW", "NES", "NEW", "NSW", "ESW", "NESW"];
}

fn validate_neighbors(raw: json.Json, frames: List<String>) -> Bool {
    let rows = value.fields(raw);
    let keys = masks();
    return length(rows) != 0 && foldl(rows, true, fn(row) => fn(ok) =>
        ok && commands.includes(keys, row.key) && belongs(row.value, frames));
}

fn validate_animation(raw: json.Json, frames: List<String>) -> Bool {
    let row = value.fields(raw);
    let used = value.items(value.get(row, "frames"));
    let direction_ok = json.lookup(row, "direction").fold(fn(raw) =>
        commands.includes(["forward", "reverse", "ping-pong"], value.text(raw)), fn(unit) => true);
    let loop_ok = json.lookup(row, "loop").fold(fn(raw) =>
        json.as_boolean(raw).fold(fn(b) => true, fn(issue) => false), fn(unit) => true);
    return value.only(row, ["frames", "direction", "loop"]) && direction_ok && loop_ok &&
        length(used) != 0 && length(used) <= 256 && foldl(used, true, fn(id) => fn(ok) => ok && belongs(id, frames));
}

fn validate_variant(raw: json.Member, frames: List<String>, prior: Result<Unit, String>) -> Result<Unit, String> {
    let checked = prior?;
    let message = "Tile variants need known tile IDs and an animation or neighbor rule";
    let row = json.members(raw.value).map_err(fn(issue) => message)?;
    let neighbors = value.get(row, "neighbors");
    let animation = value.get(row, "animation");
    if !commands.includes(frames, raw.key) || !value.only(row, ["connects", "neighbors", "animation"]) ||
        (neighbors == json.null() && animation == json.null()) || !connect(row, frames) { return Err(message); }
    if value.has(row, "neighbors") && !validate_neighbors(neighbors, frames) {
        return Err("Neighbor rules need canonical NESW masks or none and known tile frame IDs");
    }
    if value.has(row, "animation") && !validate_animation(animation, frames) {
        return Err("Tile animation needs 1–256 known frames and valid playback settings");
    }
    return Ok(());
}

fn read_variants(doc: List<json.Member>, frames: List<String>) -> Result<List<json.Member>, String> {
    if !value.has(doc, "variants") { return Ok([]); }
    let rows = json.members(value.get(doc, "variants")).map_err(fn(issue) => "Tile variants need an object keyed by tile frame ID")?;
    let initial: Result<Unit, String> = Ok(());
    let checked = foldl(rows, initial, fn(raw) => fn(out) => validate_variant(raw, frames, out))?;
    return Ok(rows);
}

fn add_tile(raw: json.Json, g: mask.Grid, frames: List<String>, out: Loaded) -> Loaded {
    if out.issue != "" { return out; }
    let message = "Map cells need native cell coordinates and a known tile frame ID";
    let row = value.fields(raw);
    let coord = value.get(row, "at");
    let position = index(g, coord);
    let tile = value.get(row, "tile");
    if position >= mask.size(g) || !value.only(row, ["at", "tile"]) || !belongs(tile, frames) {
        return Loaded { ..out, issue: message };
    }
    if out.tiles.at_or(position, "") != "" {
        return Loaded { ..out, issue: string_concat("Tilemap repeats cell ", paint.issue_at(g, position)) };
    }
    return Loaded { tiles: out.tiles.set(position, value.text(tile)), issue: "" };
}

fn prepare(raw: json.Json, frames: List<String>, native: mask.Grid) -> Result<Grid, String> {
    let message = "Use a version 1 tilemap with 1–256 columns and rows and a list of cells";
    let doc = json.members(raw).map_err(fn(issue) => message)?;
    let x = value.word(value.get(doc, "width"), 256);
    let y = value.word(value.get(doc, "height"), 256);
    let cells = json.elements(value.get(doc, "cells")).map_err(fn(issue) => message)?;
    if value.number(value.get(doc, "version")) != 1.0f64 || x == 0 || x > 256 || y == 0 || y > 256 ||
        !value.only(doc, ["version", "width", "height", "cells", "variants"]) { return Err(message); }
    return grid_rows(doc, frames, native, mask.Grid { width: x, height: y }, cells);
}

fn grid_rows(doc: List<json.Member>, frames: List<String>, native: mask.Grid, size: mask.Grid, cells: List<json.Json>) ->
    Result<Grid, String> {
    let w = size.width * native.width;
    let h = size.height * native.height;
    if w > 4096 || h > 4096 || w * h > 4000000 || length(cells) > mask.size(size) {
        return Err("Tilemap exceeds the native raster budget");
    }
    var parsed: Loaded = Loaded { tiles: buffer_fill(mask.size(size), ""), issue: "" };
    for row in cells {
        parsed = add_tile(row, size, frames, parsed);
    }
    if parsed.issue != "" { return Err(parsed.issue); }
    let tiles = parsed.tiles.freeze();
    let variants = read_variants(doc, frames)?;
    return Ok(Grid { size: size, tiles: tiles, variants: variants });
}

fn checked_schedule(raw: json.Json, frames: List<String>, durations: List<f64>) -> Bool {
    if raw == json.null() { return true; }
    let animation = value.fields(raw);
    let steps = value.items(value.get(animation, "frames")).map(fn(id) =>
        durations.at_or(selection.named_slot(frames, value.text(id)), 0.0f64));
    return timeline.playback_duration(playback(animation, length(steps)), steps) <= 9007199254740991.0f64;
}

fn playback(animation: List<json.Member>, count: u32) -> timeline.Playback {
    let direction = value.text(value.get(animation, "direction"));
    let bounce = direction == "ping-pong" && count > 1;
    return timeline.Playback { first: 0, last: count - 1, reverse: direction == "reverse", bounce: bounce,
        loop: value.flag(animation, "loop", true), passes: if bounce { 2 } else { 1 } };
}

fn check_schedules(variants: List<json.Member>, frames: List<String>, durations: List<f64>) -> Result<Unit, String> {
    if !foldl(variants, true, fn(row) => fn(ok) =>
        ok && checked_schedule(value.get(value.fields(row.value), "animation"), frames, durations)) {
        return Err("Playback steps need positive durations within the safe time range");
    }
    return Ok(());
}

fn validate(raw: json.Json, ids: List<String>, native: mask.Grid, durations: List<f64>) -> Result<Unit, String> {
    let grid = prepare(raw, ids, native)?;
    return check_schedules(grid.variants, ids, durations);
}

fn place(raw: json.Json, grid: Grid, ids: List<String>, points: json.Json, tile: json.Json) -> Result<Stroke, String> {
    if tile != json.null() && !belongs(tile, ids) { return Err("Place a known tile frame ID or use null to erase"); }
    let sites = value.items(points).map(fn(at) => index(grid.size, at));
    let size = mask.size(grid.size);
    if length(sites) == 0 || length(sites) > size || length(sites.filter(fn(p) => p >= size)) != 0 {
        return Err("A tile stroke needs cell coordinates inside the map");
    }
    let name = value.text(tile);
    var changed: Placement = Placement { tiles: buffer(grid.tiles), changes: Buffer.empty() };
    for p in sites {
        changed = write_tile(grid.size, name, p, changed);
    }
    let updates = changed.changes.freeze();
    if length(updates) == 0 { return Ok(Stroke { tilemap: raw, changes: updates }); }
    let rows = placed_rows(grid.size, changed.tiles.freeze());
    return Ok(Stroke { tilemap: json.object(paint.replace(value.fields(raw), "cells", json.array(rows))), changes: updates });
}

fn write_tile(g: mask.Grid, tile: String, p: u32, change: Placement) -> Placement {
    let before = change.tiles.at_or(p, "");
    if before == tile { return change; }
    let row = json.object([member("at", cell_point(g, p)), member("before", tile_value(before)), member("after", tile_value(tile))]);
    return Placement { tiles: change.tiles.set(p, tile), changes: change.changes.push(row) };
}

fn placed_rows(g: mask.Grid, tiles: List<String>) -> List<json.Json> {
    let initial: Buffer<json.Json> = Buffer.empty();
    return repeat_until(length(tiles), initial, fn(out) => false, fn(i) => fn(out) =>
        placed_row(g, i, tiles.at_or(i, ""), out)).freeze();
}

fn placed_row(g: mask.Grid, p: u32, id: String, out: Buffer<json.Json>) -> Buffer<json.Json> {
    if id == "" { return out; }
    return out.push(json.object([member("at", cell_point(g, p)), member("tile", json.text(id))]));
}

fn pick(grid: Grid, at: json.Json) -> Result<String, String> {
    let i = index(grid.size, at);
    if i >= mask.size(grid.size) { return Err("Pick a cell inside the tilemap"); }
    let tile = grid.tiles.at_or(i, "");
    if tile == "" { return Err("Pick an occupied tilemap cell"); }
    return Ok(tile);
}

fn connections(row: List<json.Member>, id: String) -> List<String> {
    return json.lookup(row, "connects").fold(fn(raw) => value.items(raw).map(fn(id) => value.text(id)), fn(unit) => [id]);
}

fn same_connections(a: List<String>, b: List<String>) -> Bool {
    return length(a) == length(b) && foldl(a, true, fn(id) => fn(ok) => ok && commands.includes(b, id));
}

fn same_neighbors(a: List<json.Member>, b: List<json.Member>) -> Bool {
    return length(a) == length(b) && foldl(a, true, fn(row) => fn(ok) => ok && value.get(b, row.key) == row.value);
}

fn same_animation(a: json.Json, b: json.Json) -> Bool {
    if a == json.null() || b == json.null() { return a == b; }
    let left = value.fields(a);
    let right = value.fields(b);
    let x = json.lookup(left, "direction").fold(fn(raw) => value.text(raw), fn(unit) => "forward");
    let y = json.lookup(right, "direction").fold(fn(raw) => value.text(raw), fn(unit) => "forward");
    return x == y && value.flag(left, "loop", true) == value.flag(right, "loop", true) &&
        value.get(left, "frames") == value.get(right, "frames");
}

fn connected(raw: json.Member, a: String, b: String) -> Bool {
    let row = value.fields(raw.value);
    if !value.has(row, "neighbors") { return true; }
    let ids = connections(row, raw.key);
    return commands.includes(ids, a) == commands.includes(ids, b);
}

fn same_behavior(variants: List<json.Member>, a: String, b: String) -> Bool {
    let left = value.fields(value.get(variants, a));
    let right = value.fields(value.get(variants, b));
    let x = value.fields(value.get(left, "neighbors"));
    let y = value.fields(value.get(right, "neighbors"));
    if !same_neighbors(x, y) || (length(x) != 0 && !same_connections(connections(left, a), connections(right, b))) {
        return false;
    }
    return same_animation(value.get(left, "animation"), value.get(right, "animation")) &&
        foldl(variants, true, fn(row) => fn(ok) => ok && connected(row, a, b));
}

fn read_art(art: frame.Artwork, layer: u32, cel: frame.Cel) -> Artwork {
    let place = frame.placement(art.inputs.at_or(layer, json.null()), cel);
    if cel.id == "" { return Artwork { slots: [], alpha: [], issue: "", placement: place }; }
    let root = frame.resolved_cel(art.cels, cel);
    let pixels = frame.cel_raster(art, root, raster.untouched());
    return Artwork { slots: pixels.slots, alpha: pixels.alpha, issue: pixels.issue, placement: place };
}

fn same_site(a: Artwork, b: Artwork, p: u32) -> Bool {
    let before = a.slots.at_or(p, -1);
    let after = b.slots.at_or(p, -1);
    if before != after { return false; }
    if before == -1 { return true; }
    return a.placement == b.placement &&
        (before < 0 || a.alpha.at_or(p, 255) == b.alpha.at_or(p, 255));
}

fn same_layer(art: frame.Artwork, layer: u32, before: String, after: String) -> Bool {
    let id = art.layers.at_or(layer, frame.empty_layer()).id;
    let a = frame.active_cel(art.cels, before, id);
    let b = frame.active_cel(art.cels, after, id);
    if a.id == "" && b.id == "" { return true; }
    let left = read_art(art, layer, a);
    let right = read_art(art, layer, b);
    return same_drawing(left, right, mask.size(art.grid));
}

fn same_drawing(left: Artwork, right: Artwork, pixels: u32) -> Bool {
    return left.issue == "" && right.issue == "" &&
        (length(left.slots) + length(right.slots) == 0 ||
            repeat_until(pixels, true, fn(ok) => !ok, fn(p) => fn(ok) => same_site(left, right, p)));
}

fn same_detail(a: paint.Detail, b: paint.Detail) -> Bool {
    return a.kind == b.kind && length(a.sites) == length(b.sites) &&
        foldl(a.sites, true, fn(p) => fn(ok) =>
            ok && foldl(b.sites, false, fn(q) => fn(found) => found || p == q));
}

fn same_protection(a: List<paint.Detail>, b: List<paint.Detail>) -> Bool {
    return length(a) == length(b) && foldl(a, true, fn(row) => fn(ok) =>
        ok && length(a.filter(fn(old) => same_detail(row, old))) == length(b.filter(fn(next) => same_detail(row, next))));
}

fn same_art(source: json.Json, art: frame.Artwork, a: String, b: String) -> Result<Bool, String> {
    let details = paint.protections(source, art)?;
    let left = paint.active_details(details, selection.named_slot(art.frames, a));
    let right = paint.active_details(details, selection.named_slot(art.frames, b));
    return Ok(same_protection(left, right) && repeat_until(length(art.layers), true, fn(ok) => !ok,
        fn(i) => fn(ok) => same_layer(art, i, a, b)));
}

fn exact_matches(source: json.Json, art: frame.Artwork, variants: List<json.Member>, id: String) -> Result<List<String>, String> {
    let candidates = art.frames.filter(fn(name) => name != id && same_behavior(variants, id, name));
    if length(candidates) == 0 { return Ok([]); }
    let details = paint.protections(source, art)?;
    let locked = paint.active_details(details, selection.named_slot(art.frames, id));
    let cache = art.layers.map_indexed(fn(i) => fn(layer) => read_art(art, i, frame.active_cel(art.cels, id, layer.id)));
    return Ok(candidates.filter(fn(name) => can_match(art, details, locked, cache, name)));
}

fn can_match(art: frame.Artwork, details: List<paint.Detail>, locked: List<paint.Detail>, base: List<Artwork>, name: String) -> Bool {
    if !same_protection(locked, paint.active_details(details, selection.named_slot(art.frames, name))) {
        return false;
    }
    return repeat_until(length(art.layers), true, fn(ok) => !ok, fn(i) => fn(ok) => match_layer(art, base, name, i));
}

fn match_layer(art: frame.Artwork, base: List<Artwork>, name: String, layer: u32) -> Bool {
    let id = art.layers.at_or(layer, frame.empty_layer()).id;
    let other = read_art(art, layer, frame.active_cel(art.cels, name, id));
    let original = base.at_or(layer, Artwork { ..other, issue: "Missing cached tile artwork" });
    return same_drawing(original, other, mask.size(art.grid));
}
