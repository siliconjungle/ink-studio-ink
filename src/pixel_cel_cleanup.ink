module StudioPixelCelCleanup;

import "std:json" as json;
import "pixel_drawing_grid.ink" as grid;
import "pixel_fault.ink" as fault;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_rgba_edit.ink" as rgba;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Input { grid: mask.Grid, art: frame.PaintView, colors: List<u32>, selected: List<u32>, locked: List<u32>, budget: u32, }
record Plan { rows: List<rgba.Write>, issue: json.Json, }
record Ring { slots: List<u32>, reached: List<u32>, cursor: u32, }
record Repair { pen: grid.Pen, plan: Plan, }
record Line { queue: List<u32>, cursor: u32, }

fn num(n: u32) -> json.Json { return json.number(frame.decimal(n)); }
fn problem(code: String, message: String, fields: List<json.Member>) -> json.Json { return history.problem(code, message, fields); }
fn invalid(message: String) -> json.Json { return problem("invalid-edit", message, []); }
fn point(g: mask.Grid, p: u32) -> grid.Point {
    let xy = fault.position(g, p);
    return grid.Point { x: grid.signed(xy.x), y: grid.signed(xy.y) };
}
fn at(g: mask.Grid, p: u32) -> json.Member {
    let xy = fault.position(g, p);
    return history.member("at", json.array([num(xy.x), num(xy.y)]));
}
fn text_in(items: List<json.Member>, key: String) -> String { return value.text(value.get(items, key)); }
fn empty() -> Plan { return Plan { rows: [], issue: json.null() }; }
fn failed(code: String, message: String, fields: List<json.Member>) -> Plan {
    return Plan { rows: [], issue: problem(code, message, fields) };
}

fn site(g: mask.Grid, x: i32, y: i32) -> u32 {
    if x < 0 || y < 0 || x >= grid.signed(g.width) || y >= grid.signed(g.height) { return mask.size(g); }
    return grid.position(g, x, y);
}
fn shifted(g: mask.Grid, p: grid.Point, dx: i32, dy: i32) -> u32 { return site(g, p.x + dx, p.y + dy); }

fn neighbors(g: mask.Grid, p: u32, diagonal: Bool) -> List<u32> {
    let xy = point(g, p);
    let cardinal: List<Vec2<i32>> = [vec2(1, 0), vec2(-1, 0), vec2(0, 1), vec2(0, -1)];
    let corners: List<Vec2<i32>> = [vec2(1, 1), vec2(-1, 1), vec2(1, -1), vec2(-1, -1)];
    let offsets = if diagonal { cardinal.concat(corners) } else { cardinal };
    return offsets.map(fn(step) => shifted(g, xy, step.x, step.y)).filter(fn(q) => q < mask.size(g));
}

fn contains(sites: List<u32>, p: u32) -> Bool {
    return fold_until(sites, false, fn(q) => fn(found) => found, fn(q) => fn(found) => found || q == p);
}
fn slot(input: Input, p: u32) -> i32 { return input.art.captured.slots.at_or(p, -1); }
fn alpha(input: Input, p: u32) -> u32 { return if slot(input, p) < 0 { 255 } else { input.art.captured.alpha.at_or(p, 255) }; }
fn painted(input: Input, p: u32) -> Bool { return slot(input, p) >= 0 && alpha(input, p) > 0; }
fn tint(input: Input, p: u32) -> u32 {
    return if painted(input, p) { input.colors.at_or(grid.unsigned(slot(input, p)), 0) + 1 } else { 0 };
}

fn edited_slot(input: Input, writes: List<rgba.Write>, p: u32) -> i32 {
    let base: i32 = if painted(input, p) { slot(input, p) } else { -1 };
    let found: i32 = fold_until(writes, -3, fn(row) => fn(found) => found != -3,
        fn(row) => fn(found) => if row.pixel == p { row.slot } else { found });
    return if found == -3 { base } else { found };
}

fn put(input: Input, p: u32, color: i32, coverage: u32, plan: Plan) -> Plan {
    if plan.issue != json.null() || (color == slot(input, p) && coverage == alpha(input, p)) { return plan; }
    if !mask.selected(input.selected, p) {
        return failed("cleanup-selection", "Extend the selection to cover the proposed repair", [at(input.grid, p)]);
    }
    if !frame.can_paint(input.art, input.locked, p) {
        let issue = fault.blocked(input.grid, input.art, input.locked, "", p, "Cleanup cannot change this pixel");
        return failed(issue.code, issue.message, [at(input.grid, p)]);
    }
    let write = rgba.Write { pixel: p, slot: color, alpha: coverage };
    let rows = plan.rows.filter(fn(row) => row.pixel != p).concat([write]);
    if length(rows) > input.budget {
        let message = string_concat("Cleanup exceeds the ", string_concat(frame.decimal(input.budget), " pixel budget"));
        return failed("cleanup-budget", message, [history.member("maxChanges", num(input.budget)), at(input.grid, p)]);
    }
    return Plan { ..plan, rows: rows };
}

fn add_ring(q: u32, cells: List<u32>, reached: List<u32>) -> List<u32> {
    return if contains(cells, q) && !contains(reached, q) { reached.concat([q]) } else { reached };
}
fn extend_ring(g: mask.Grid, diagonal: Bool, ring: Ring) -> Ring {
    let p = ring.reached.at_or(ring.cursor, 0);
    let all = foldl(neighbors(g, p, diagonal), ring.reached, fn(q) => fn(out) => add_ring(q, ring.slots, out));
    return Ring { ..ring, reached: all, cursor: ring.cursor + 1 };
}
fn can_remove(input: Input, p: u32, pigment: i32, diagonal: Bool, rows: List<rgba.Write>) -> Bool {
    let g = input.grid;
    let cells = neighbors(g, p, true).filter(fn(q) => edited_slot(input, rows, q) == pigment);
    let required = neighbors(g, p, diagonal).filter(fn(q) => contains(cells, q));
    if length(required) < (if diagonal { 2 } else { 1 }) { return false; }
    let initial = Ring { slots: cells, reached: [required.at_or(0, 0)], cursor: 0 };
    let reached = repeat_until(8, initial, fn(row) => row.cursor >= length(row.reached),
        fn(i) => fn(row) => extend_ring(g, diagonal, row)).reached;
    return length(required.filter(fn(q) => !contains(reached, q))) == 0;
}

fn growth(input: Input, group: List<u32>, p: u32, color: i32, plan: Plan) -> Plan {
    if slot(input, p) != -1 { return plan; }
    let neighbors = neighbors(input.grid, p, false);
    let donors = neighbors.filter(fn(q) => mask.selected(group, q)).sort();
    if length(donors) == 0 || length(neighbors.filter(fn(q) =>
        painted(input, q) && slot(input, q) == color && !mask.selected(group, q))) != 0 { return plan; }
    return put(input, p, color, alpha(input, donors.at_or(0, 0)), plan);
}
fn thinning(input: Input, group: List<u32>, p: u32, color: i32, plan: Plan) -> Plan {
    if !mask.selected(group, p) { return plan; }
    let adjacent = neighbors(input.grid, p, false);
    if length(adjacent) == 4 && length(adjacent.filter(fn(q) => mask.selected(group, q))) == 4 { return plan; }
    return if can_remove(input, p, color, false, plan.rows) { put(input, p, -1, 255, plan) } else { plan };
}
fn cluster(input: Input, selected: List<u32>, seed: u32, grow: Bool) -> Plan {
    let g = input.grid;
    let marked = selected.filter(fn(p) => painted(input, p));
    let root = if seed < mask.size(g) { seed } else { marked.at_or(0, mask.size(g)) };
    if !painted(input, root) { return failed("cleanup-shape", "Include a painted seed from the cluster", []); }
    let color = slot(input, root);
    let layer = mask.PaletteRaster { slots: input.art.captured.slots, alpha: input.art.captured.alpha, clipping: [], ids: [] };
    let search = mask.Region { grid: g, source: [], keyed: false, target: 0, tolerance: 0, swatch: color };
    let group = mask.flood(search, layer, root, false);
    if seed == mask.size(g) && length(marked.filter(fn(p) => !mask.selected(group, p))) != 0 {
        return failed("cleanup-shape", "Select one swatch cluster or specify its seed pixel", []);
    }
    return fold_until(selected, empty(), fn(p) => fn(out) => out.issue != json.null(),
        fn(p) => fn(out) => if grow { growth(input, group, p, color, out) } else { thinning(input, group, p, color, out) });
}

fn related(input: Input, p: u32, color: i32) -> Bool { return painted(input, p) && slot(input, p) == color; }
fn isolated(input: Input, p: u32) -> Bool {
    return painted(input, p) && length(neighbors(input.grid, p, true).filter(fn(q) => related(input, q, slot(input, p)))) == 0;
}
fn vote(input: Input, q: u32, cardinal: List<u32>, counts: Buffer<u32>) -> Buffer<u32> {
    if !painted(input, q) { return counts; }
    let color = slot(input, q);
    let cluster = neighbors(input.grid, q, false).filter(fn(p) => related(input, p, color));
    if length(cluster) == 0 { return counts; }
    let i = grid.unsigned(color);
    let before = counts.at_or(i, 0);
    return counts.set(i, before + (if contains(cardinal, q) { 2 } else { 1 }));
}
fn fragment(input: Input, selected: List<u32>, seed: u32, override: u32) -> Plan {
    let sites = if seed < mask.size(input.grid) { [seed] } else { selected };
    let candidates = sites.filter(fn(p) => isolated(input, p));
    if length(candidates) != 1 { return failed("cleanup-shape", "Choose one isolated painted pixel to merge", []); }
    let p = candidates.at_or(0, 0);
    let cardinal = neighbors(input.grid, p, false);
    let initial: Buffer<u32> = buffer_fill(length(input.colors), 0);
    let counts = foldl(neighbors(input.grid, p, true), initial, fn(q) => fn(out) => vote(input, q, cardinal, out)).freeze();
    let max: u32 = foldl(counts, 0, fn(n) => fn(out) => if n > out { n } else { out });
    let tied = counts.map_indexed(fn(i) => fn(n) => if n == max { i } else { 4294967295 })
        .filter(fn(i) => i != 4294967295);
    let target = if override != 4294967295 { override } else { tied.at_or(0, 4294967295) };
    if counts.at_or(target, 0) == 0 || (override == 4294967295 && length(tied) != 1) {
        return failed("cleanup-shape", "Choose a swatch from a neighboring cluster with a clear connection", [at(input.grid, p)]);
    }
    return put(input, p, grid.signed(target), alpha(input, p), empty());
}

fn axis(p: grid.Point, vertical: Bool) -> i32 { return if vertical { p.y } else { p.x }; }
fn extent(g: mask.Grid, pts: List<u32>, vertical: Bool) -> i32 {
    let high: i32 = foldl(pts, 0, fn(p) => fn(out) => grid.max(out, axis(point(g, p), vertical)));
    let low: i32 = foldl(pts, 512, fn(p) => fn(out) => -grid.max(-out, -axis(point(g, p), vertical)));
    return high - low;
}
fn is_step(a: grid.Point, b: grid.Point, vertical: Bool, sign: i32) -> Bool {
    let along = axis(b, vertical) - axis(a, vertical);
    let across = (axis(b, !vertical) - axis(a, !vertical)) * sign;
    return along == 1 && across >= 0 && across <= 1;
}
fn repair_step(input: Input, src: u32, pigment: i32, before: Repair) -> Repair {
    if before.plan.issue != json.null() { return before; }
    let next = grid.advance(before.pen);
    let dst = grid.position(input.grid, next.position.x, next.position.y);
    if src == dst { return Repair { ..before, pen: next }; }
    if slot(input, dst) != -1 {
        return Repair { pen: next, plan: failed("cleanup-occupied", "The repaired staircase would overwrite an authored cell", [at(input.grid, dst)]) };
    }
    let removed = put(input, src, -1, 255, before.plan);
    return Repair { pen: next, plan: put(input, dst, pigment, alpha(input, src), removed) };
}
fn order_stair(g: mask.Grid, pixels: List<u32>, vertical: Bool) -> List<u32> {
    if vertical { return pixels; }
    let keys = pixels.map(fn(p) => fault.position(g, p)).map(fn(p) => p.x * g.height + p.y).sort();
    return keys.map(fn(p) => rem_or(p, g.height, 0) * g.width + quot_or(p, g.height, 0));
}
fn stair(input: Input, selected: List<u32>) -> Plan {
    let g = input.grid;
    let pixels = selected.filter(fn(p) => painted(input, p));
    let pigment = slot(input, pixels.at_or(0, 0));
    if length(pixels) < 3 || length(pixels.filter(fn(p) => slot(input, p) != pigment)) != 0 {
        return failed("cleanup-shape", "Select one thin staircase in a single swatch", []);
    }
    let vertical = extent(g, pixels, true) > extent(g, pixels, false);
    let ordered = order_stair(g, pixels, vertical);
    let points = ordered.map(fn(p) => point(g, p));
    let first = points.at_or(0, grid.Point { x: 0, y: 0 });
    let last = points.at_or(length(points) - 1, first);
    let sign = grid.sign(axis(last, !vertical) - axis(first, !vertical));
    let monotone = points.map_indexed(fn(i) => fn(p) => i == 0 || is_step(points.at_or(i - 1, first), p, vertical, sign));
    if sign == 0 || length(monotone.filter(fn(ok) => !ok)) != 0 {
        return failed("cleanup-shape", "The selected staircase needs one monotone pixel per row or column", []);
    }
    let start = Repair { pen: grid.segment(first, last), plan: empty() };
    return fold_until(ordered.drop(1), start, fn(p) => fn(out) => out.plan.issue != json.null(),
        fn(p) => fn(out) => repair_step(input, p, pigment, out)).plan;
}

fn corners() -> List<Vec2<i32>> { return [vec2(1, 1), vec2(1, -1), vec2(-1, 1), vec2(-1, -1)]; }
fn rgb_equal(input: Input, p: u32, color: u32) -> Bool { return p < mask.size(input.grid) && tint(input, p) == color; }
fn block(input: Input, p: grid.Point, color: u32, step: Vec2<i32>) -> Bool {
    let g = input.grid;
    return rgb_equal(input, shifted(g, p, step.x, 0), color) && rgb_equal(input, shifted(g, p, 0, step.y), color) &&
        rgb_equal(input, shifted(g, p, step.x, step.y), color);
}
fn luminance(rgb: u32) -> f64 {
    let r = f64_from_u32(wrapping_shr(rgb, 16));
    let g = f64_from_u32(word_and(wrapping_shr(rgb, 8), 255));
    let b = f64_from_u32(word_and(rgb, 255));
    return f64_from_f32(f32_from_f64((r * 0.299f64 + g * 0.587f64 + b * 0.114f64) / 255.0f64));
}
fn dark(input: Input, p: u32, color: u32) -> Bool {
    if !rgb_equal(input, p, color) || color == 0 { return false; }
    let xy = point(input.grid, p);
    if length(corners().filter(fn(step) => block(input, xy, color, step))) != 0 { return false; }
    let brightness = luminance(color - 1);
    return length(neighbors(input.grid, p, true).filter(fn(q) => too_dark(input, q, color, brightness))) == 0;
}
fn too_dark(input: Input, p: u32, color: u32, brightness: f64) -> Bool {
    let near = tint(input, p);
    return near != 0 && near != color && luminance(near - 1) - brightness < 0.06f64;
}
fn extend_line(input: Input, color: u32, line: Line) -> Line {
    let p = line.queue.at_or(line.cursor, 0);
    let fresh = neighbors(input.grid, p, true).filter(fn(q) => !contains(line.queue, q) && dark(input, q, color));
    return Line { queue: line.queue.concat(fresh), cursor: line.cursor + 1 };
}
fn on_line(input: Input, p: u32) -> Bool {
    let color = tint(input, p);
    if !dark(input, p, color) { return false; }
    let check = Line { queue: [p], cursor: 0 };
    let found = repeat_until(5, check, fn(row) => row.cursor >= length(row.queue) || length(row.queue) >= 6,
        fn(i) => fn(row) => extend_line(input, color, row));
    return length(found.queue) >= 6;
}
fn arm(input: Input, color: u32, p: u32) -> Bool { return rgb_equal(input, p, color) && on_line(input, p); }
fn doubled_corner(input: Input, p: grid.Point, color: u32, a: Vec2<i32>) -> Bool {
    let g = input.grid;
    if !arm(input, color, shifted(g, p, a.x, 0)) || !arm(input, color, shifted(g, p, 0, a.y)) { return false; }
    let h = on_line(input, shifted(g, p, 2 * a.x, -a.y));
    let v = on_line(input, shifted(g, p, -a.x, 2 * a.y));
    return (h || v) && (h || on_line(input, shifted(g, p, 2 * a.x, 0))) &&
        (v || on_line(input, shifted(g, p, 0, 2 * a.y))) &&
        !on_line(input, shifted(g, p, -a.x, 0)) && !on_line(input, shifted(g, p, 0, -a.y));
}
fn doubled(input: Input, p: u32) -> Bool {
    if !on_line(input, p) { return false; }
    let xy = point(input.grid, p);
    let color = tint(input, p);
    return length(corners().filter(fn(offset) => doubled_corner(input, xy, color, offset))) != 0;
}
fn outline(input: Input, selected: List<u32>) -> Plan {
    let sites = selected.filter(fn(p) => doubled(input, p));
    if length(sites) == 0 { return failed("cleanup-shape", "Select a doubled inside corner on a thin outline", []); }
    return fold_until(sites, empty(), fn(p) => fn(out) => out.issue != json.null(), fn(p) => fn(out) =>
        if can_remove(input, p, slot(input, p), true, out.rows) { put(input, p, -1, 255, out) } else { out });
}

fn options(input: Input, ids: List<String>, spec: List<json.Member>) -> Result<Plan, json.Json> {
    let kind = text_in(spec, "kind");
    let mode = text_in(spec, "mode");
    let raw_at = value.get(spec, "at");
    let swatch = selection.named_slot(ids, text_in(spec, "swatch"));
    let explicit = value.has(spec, "at");
    let known = kind == "cluster" || kind == "stair" || kind == "fragment" || kind == "outline";
    let valid_mode = if kind == "cluster" { mode == "grow" || mode == "shrink" } else { !value.has(spec, "mode") };
    if !known || input.budget == 0 || input.budget > 256 || !valid_mode ||
        (explicit && kind != "cluster" && kind != "fragment") || (value.has(spec, "swatch") && (kind != "fragment" || swatch == 4294967295)) {
        return Err(invalid("Choose a cleanup kind and an integer budget from 1 to 256 pixels"));
    }
    let selected = mask.indices(input.selected);
    if length(selected) > 2048 { return Err(problem("cleanup-selection", "Select at most 2048 pixels for one cleanup", [])); }
    if length(selected) == 0 { return Err(problem("cleanup-selection", "Select the pixels where cleanup may write", [])); }
    let seed = seed_site(input.grid, raw_at);
    if explicit && (seed >= mask.size(input.grid) || !mask.selected(input.selected, seed)) {
        return Err(problem("cleanup-selection", "Choose a seed pixel inside the selection", [history.member("at", raw_at)]));
    }
    if kind == "cluster" { return Ok(cluster(input, selected, seed, mode == "grow")); }
    if kind == "fragment" { return Ok(fragment(input, selected, seed, swatch)); }
    if kind == "stair" { return Ok(stair(input, selected)); }
    return Ok(outline(input, selected));
}

fn seed_site(g: mask.Grid, raw: json.Json) -> u32 {
    let points = value.items(raw);
    let x = value.word(points.at_or(0, json.null()), g.width - 1);
    let y = value.word(points.at_or(1, json.null()), g.height - 1);
    if length(points) != 2 || x >= g.width || y >= g.height { return mask.size(g); }
    return y * g.width + x;
}

fn plan(art: frame.Artwork, captured: frame.PaintView, selected: List<u32>, locked: List<u32>,
    spec: List<json.Member>) -> Result<List<rgba.Write>, json.Json> {
    let budget = json.lookup(spec, "maxChanges").fold(fn(raw) => value.word(raw, 256), fn(unit) => 64);
    let input = Input { grid: art.grid, art: captured, colors: art.colors, selected: selected, locked: locked, budget: budget };
    let planned = options(input, art.ids, spec)?;
    if planned.issue != json.null() { return Err(planned.issue); }
    let positions = planned.rows.map(fn(row) => row.pixel).sort();
    return Ok(positions.map(fn(p) => ordered(planned.rows, p)));
}

fn ordered(rows: List<rgba.Write>, p: u32) -> rgba.Write {
    let empty = rgba.Write { pixel: p, slot: -3, alpha: 255 };
    return fold_until(rows, empty, fn(row) => fn(out) => out.slot != -3,
        fn(row) => fn(out) => if row.pixel == p { row } else { out });
}
