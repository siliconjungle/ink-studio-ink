module StudioPixelBrush;

import "std:json" as json;
import "pixel_drawing_grid.ink" as grid;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;
import "pixel_labels.ink" as labels;
import "pixel_raster.ink" as raster;
import "rig.ink" as math;

record Swatch { id: String, color: u32, }
record Pair { x: f64, y: f64, }
record Dynamics { stabilize: f64, pressure: Pair, speed: f64, velocity: Pair, }
record Settings { angle: f64, size: Vec2<u32>, tint: Option<Swatch>, dynamics: Dynamics, }
record Brush { width: u32, height: u32, anchor: Vec2<u32>, palette: List<Swatch>, slots: List<i32>, settings: Settings, }
record Geometry { c: f64, s: f64, sx: f64, sy: f64, ox: f64, oy: f64, }
record Bounds { left: i32, top: i32, right: i32, bottom: i32, }
record Dab { x: i32, y: i32, slot: i32, }
record Stamp { pixel: u32, slot: i32, }
record Tip { size: Vec2<u32>, bounds: Bounds, geometry: Geometry, cells: List<Dab>, }
record Marks { slots: Buffer<i32>, sites: Buffer<u32>, cost: u32, issue: String, }
record Segment { pen: grid.Pen, marks: Marks, }

fn no_dynamics() -> Dynamics {
    let identity = Pair { x: 1.0f64, y: 1.0f64 };
    return Dynamics { stabilize: 0.0f64, pressure: identity, speed: 0.0f64, velocity: identity };
}

fn finite_between(n: f64, lo: f64, hi: f64) -> Bool { return n >= lo && n <= hi; }

fn fpair(raw: json.Json) -> Pair {
    let rows = value.items(raw);
    if length(rows) != 2 { return Pair { x: value.missing_number(), y: value.missing_number() }; }
    return Pair { x: value.number(rows.at_or(0, json.null())), y: value.number(rows.at_or(1, json.null())) };
}

fn upair(raw: json.Json, hi: Vec2<u32>) -> Vec2<u32> {
    let rows = value.items(raw);
    if length(rows) != 2 { return vec2(4294967295, 4294967295); }
    return vec2(value.word(rows.at_or(0, json.null()), hi.x), value.word(rows.at_or(1, json.null()), hi.y));
}

fn letter(c: u32) -> Bool { return c >= 97 && c <= 122; }

fn stable_id(id: String) -> Bool {
    let size = string_byte_len(id);
    if size == 0 || size > 64 || !letter(labels.byte(id, 0)) { return false; }
    return repeat_until(size - 1, true, fn(valid) => !valid, fn(i) => fn(valid) => id_char(labels.byte(id, i + 1)));
}

fn id_char(c: u32) -> Bool { return letter(c) || (c >= 48 && c <= 57) || c == 45; }

fn rgb(text: String) -> u32 {
    if string_byte_len(text) != 7 || labels.byte(text, 0) != 35 { return 4294967295; }
    return repeat_until(6, 0, fn(n) => n == 4294967295, fn(i) => fn(n) => rgb_digit(n, labels.byte(text, i + 1)));
}

fn rgb_digit(n: u32, c: u32) -> u32 {
    let d = raster.hex(c);
    return if d > 15 { 4294967295 } else { n * 16 + d };
}

fn swatch(spec: List<json.Member>, keys: List<String>) -> Swatch {
    let id = value.text(value.get(spec, "id"));
    let valid = value.only(spec, keys) && (!value.has(spec, "id") || stable_id(id));
    let color = if valid { rgb(value.text(value.get(spec, "color"))) } else { 4294967295 };
    return Swatch { id: id, color: color };
}

fn brush_slot(raw: json.Json, max: u32) -> i32 {
    if raw == json.null() { return -1; }
    let n = value.word(raw, max);
    return if n == 4294967295 { -2 } else { grid.signed(n) };
}

fn decode(raw: json.Json, packed: List<i32>) -> Result<Brush, String> {
    let spec = value.fields(raw);
    let issue = "A pixel brush needs a painted indexed shape and a native anchor";
    let w = value.word(value.get(spec, "width"), 512);
    let h = value.word(value.get(spec, "height"), 512);
    if !value.only(spec, ["format", "version", "width", "height", "anchor", "palette", "slots", "settings"]) ||
        value.text(value.get(spec, "format")) != "ink-studio/pixel-brush" || value.word(value.get(spec, "version"), 1) != 1 ||
        w == 0 || w > 512 || h == 0 || h > 512 {
        return Err(issue);
    }
    let anchor = upair(value.get(spec, "anchor"), vec2(w - 1, h - 1));
    let colors = value.items(value.get(spec, "palette"));
    let slots = value.items(value.get(spec, "slots"));
    let count = if length(packed) == 0 { length(slots) } else { length(packed) };
    if anchor.x >= w || anchor.y >= h || length(colors) == 0 || length(colors) > 255 || count != w * h {
        return Err(issue);
    }
    let palette = colors.map(fn(row) => swatch(value.fields(row), ["id", "color"]));
    let cells = if length(packed) == 0 { slots.map(fn(row) => brush_slot(row, length(colors) - 1)) } else { packed };
    let ceiling = grid.signed(length(colors));
    if length(palette.filter(fn(row) => row.color > 16777215)) != 0 ||
        length(cells.filter(fn(n) => n < -1 || n >= ceiling)) != 0 || length(cells.filter(fn(n) => n >= 0)) == 0 {
        return Err(issue);
    }
    let settings = decode_settings(value.get(spec, "settings"))?;
    return Ok(Brush { width: w, height: h, anchor: anchor, palette: palette, slots: cells, settings: settings });
}

fn decode_settings(raw: json.Json) -> Result<Settings, String> {
    let spec = value.fields(raw);
    let tone = value.fields(value.get(spec, "swatch"));
    let mode = value.text(value.get(tone, "mode"));
    let size = upair(value.get(spec, "size"), vec2(512, 512));
    let angle = value.number(value.get(spec, "angle"));
    let tint = swatch(tone, ["id", "color", "mode"]);
    if !value.only(spec, ["angle", "size", "swatch", "dynamics"]) || !finite_between(angle, -360000.0f64, 360000.0f64) ||
        size.x == 0 || size.x > 512 || size.y == 0 || size.y > 512 ||
        !(mode == "original" && length(tone) == 1 || mode == "tint" && tint.color <= 16777215) {
        return Err("A pixel brush needs a finite angle, a bounded size and original or tint swatch settings");
    }
    let dynamics = read_dynamics(spec)?;
    return Ok(Settings { angle: angle, size: size, tint: if mode == "tint" { Some(tint) } else { None }, dynamics: dynamics });
}

fn scaled(pair: Pair) -> Bool { return finite_between(pair.x, 0.0f64, 4.0f64) && finite_between(pair.y, 0.0f64, 4.0f64); }

fn read_dynamics(settings: List<json.Member>) -> Result<Dynamics, String> {
    if !value.has(settings, "dynamics") { return Ok(no_dynamics()); }
    let issue = "Brush dynamics need stabilization in 0–500 ms, size scales in 0–4 and velocity speed in 1–10000 px/s";
    let raw = value.get(settings, "dynamics");
    let spec: Result<List<json.Member>, String> = json.members(raw).fold(fn(rows) => Ok(rows), fn(e) => Err(issue));
    let rows = spec?;
    let initial = no_dynamics();
    let stabilize = if value.has(rows, "stabilization") { value.number(value.get(rows, "stabilization")) } else { 0.0f64 };
    let pressure = if value.has(rows, "pressure") { fpair(value.get(rows, "pressure")) } else { initial.pressure };
    if !value.only(rows, ["stabilization", "pressure", "velocity"]) ||
        !finite_between(stabilize, 0.0f64, 500.0f64) || !scaled(pressure) { return Err(issue); }
    let valid = Dynamics { ..initial, stabilize: stabilize, pressure: pressure };
    if !value.has(rows, "velocity") { return Ok(valid); }
    let velocity = value.fields(value.get(rows, "velocity"));
    let size = fpair(value.get(velocity, "size"));
    let speed = value.number(value.get(velocity, "speed"));
    if !value.only(velocity, ["speed", "size"]) || !finite_between(speed, 1.0f64, 10000.0f64) || !scaled(size) { return Err(issue); }
    return Ok(Dynamics { ..valid, speed: speed, velocity: size });
}

fn modulo(n: f64, period: f64) -> f64 { return n - trunc(n / period) * period; }

fn sine(x: f64) -> f64 {
    let z = x * x;
    let tail = -1.0f64 / 1307674368000.0f64 + z / 355687428096000.0f64;
    let coefficients = -1.0f64 / 39916800.0f64 + z * (1.0f64 / 6227020800.0f64 + z * tail);
    return x + x * z * (-1.0f64 / 6.0f64 + z * (1.0f64 / 120.0f64 + z *
        (-1.0f64 / 5040.0f64 + z * (1.0f64 / 362880.0f64 + z * coefficients))));
}

fn cosine(x: f64) -> f64 {
    let z = x * x;
    let tail = 1.0f64 / 20922789888000.0f64 - z / 6402373705728000.0f64;
    let coefficients = 1.0f64 / 479001600.0f64 + z * (-1.0f64 / 87178291200.0f64 + z * tail);
    return 1.0f64 + z * (-0.5f64 + z * (1.0f64 / 24.0f64 + z * (-1.0f64 / 720.0f64 + z *
        (1.0f64 / 40320.0f64 + z * (-1.0f64 / 3628800.0f64 + z * coefficients)))));
}

fn rotation(angle: f64) -> Pair {
    let turn = modulo(modulo(angle, 360.0f64) + 360.0f64, 360.0f64);
    let index = value.round_byte(turn / 90.0f64);
    let quadrant = word_and(index, 3);
    if turn == f64_from_u32(index) * 90.0f64 {
        let cos: List<f64> = [1.0f64, 0.0f64, -1.0f64, 0.0f64];
        let sin: List<f64> = [0.0f64, 1.0f64, 0.0f64, -1.0f64];
        return Pair { x: cos.at_or(quadrant, 0.0f64), y: sin.at_or(quadrant, 0.0f64) };
    }
    let q = f64_from_u32(index);
    let radians = turn * math.pi() / 180.0f64;
    // Keep the reduced argument within pi/4 and retain the low bits of pi/2.
    let x = (radians - q * 1.5707963267948966f64) - q * 6.123233995736766e-17f64;
    let c = cosine(x);
    let s = sine(x);
    if quadrant == 0 { return Pair { x: c, y: s }; }
    if quadrant == 1 { return Pair { x: -s, y: c }; }
    if quadrant == 2 { return Pair { x: -c, y: -s }; }
    return Pair { x: s, y: -c };
}

fn integer(n: f64) -> i32 { return i32_from_f64(n).fold(fn(i) => i, fn(unit) => 0); }

fn geometry(b: Brush, size: Vec2<u32>) -> Geometry {
    let turn = rotation(b.settings.angle);
    return Geometry { c: turn.x, s: turn.y, sx: f64_from_u32(size.x) / f64_from_u32(b.width),
        sy: f64_from_u32(size.y) / f64_from_u32(b.height), ox: f64_from_u32(b.anchor.x) + 0.5f64,
        oy: f64_from_u32(b.anchor.y) + 0.5f64 };
}

fn corner(g: Geometry, x: f64, y: f64) -> Pair {
    return Pair { x: g.c * x * g.sx - g.s * y * g.sy, y: g.s * x * g.sx + g.c * y * g.sy };
}

fn bounds(g: Geometry, b: Brush) -> Bounds {
    let x = f64_from_u32(b.width) - g.ox;
    let y = f64_from_u32(b.height) - g.oy;
    let a = corner(g, -g.ox, -g.oy);
    let c = corner(g, x, -g.oy);
    let d = corner(g, -g.ox, y);
    let e = corner(g, x, y);
    return Bounds { left: integer(floor(value.min(value.min(a.x, c.x), value.min(d.x, e.x)))),
        top: integer(floor(value.min(value.min(a.y, c.y), value.min(d.y, e.y)))),
        right: integer(ceil(value.max(value.max(a.x, c.x), value.max(d.x, e.x)))),
        bottom: integer(ceil(value.max(value.max(a.y, c.y), value.max(d.y, e.y)))) };
}

fn width(b: Bounds) -> u32 { return grid.unsigned(b.right - b.left + 1); }
fn area(b: Bounds) -> u32 { return width(b) * grid.unsigned(b.bottom - b.top + 1); }

fn tip(b: Brush, size: Vec2<u32>) -> Tip {
    let t = geometry(b, size);
    return Tip { size: size, bounds: bounds(t, b), geometry: t, cells: [] };
}

fn raster_tip(b: Brush, t: Tip) -> Tip {
    let seed: Buffer<Dab> = Buffer.empty();
    let w = width(t.bounds);
    let cells = repeat_until(area(t.bounds), seed, fn(out) => false, fn(i) => fn(out) =>
        tip_cell(b, t, t.bounds.left + grid.signed(rem_or(i, w, 0)),
            t.bounds.top + grid.signed(quot_or(i, w, 0)), out));
    return Tip { ..t, cells: cells.freeze() };
}

fn tip_cell(b: Brush, t: Tip, x: i32, y: i32, out: Buffer<Dab>) -> Buffer<Dab> {
    let u = f64_from_i32(x);
    let v = f64_from_i32(y);
    let g = t.geometry;
    let a = floor((g.c * u + g.s * v) / g.sx + g.ox);
    let c = floor((-g.s * u + g.c * v) / g.sy + g.oy);
    if a < 0.0f64 || a >= f64_from_u32(b.width) || c < 0.0f64 || c >= f64_from_u32(b.height) { return out; }
    let slot = b.slots.at_or(value.as_word(c) * b.width + value.as_word(a), -1);
    return if slot < 0 { out } else { out.push(Dab { x: x, y: y, slot: slot }) };
}

fn start(d: grid.Drawing) -> Marks {
    return Marks { slots: buffer_fill(mask.size(d.grid), -1), sites: Buffer.empty(), cost: 0, issue: "" };
}

fn charge(n: u32, old: Marks) -> Marks {
    if old.cost + n > 8000000 { return Marks { ..old, issue: "Brush stroke exceeds its native pixel budget" }; }
    return Marks { ..old, cost: old.cost + n };
}

fn place(d: grid.Drawing, cells: List<Dab>, at: grid.Point, old: Marks) -> Marks {
    return foldl(cells, old, fn(dab) => fn(out) => place_cell(d, at, dab, out));
}

fn place_cell(d: grid.Drawing, at: grid.Point, dab: Dab, old: Marks) -> Marks {
    let p = grid.Point { x: at.x + dab.x, y: at.y + dab.y };
    if d.x.mirror == -2 && d.y.mirror == -2 {
        let i = grid.position(d.grid, grid.normalize(p.x, d.x), grid.normalize(p.y, d.y));
        return if i == 4294967295 { old } else { stamp(i, dab.slot, old) };
    }
    return foldl(grid.copies(d, p), old, fn(i) => fn(out) => stamp(i, dab.slot, out));
}

fn stamp(p: u32, slot: i32, old: Marks) -> Marks {
    let first = old.slots.at_or(p, -1) < 0;
    let sites = if first { old.sites.push(p) } else { old.sites };
    return Marks { ..old, sites: sites, slots: old.slots.set(p, slot) };
}

fn freeze_marks(old: Marks) -> Result<List<Stamp>, String> {
    if old.issue != "" { return Err(old.issue); }
    let slots = old.slots.freeze();
    return Ok(old.sites.freeze().map(fn(p) => Stamp { pixel: p, slot: slots.at_or(p, -1) }));
}

fn static_path(d: grid.Drawing, b: Brush, path: List<grid.Point>) -> Result<List<Stamp>, String> {
    let t = raster_tip(b, tip(b, b.settings.size));
    let cells = length(t.cells);
    if cells == 0 { return Ok([]); }
    let first = path.at_or(0, grid.absent());
    if grid.path_steps(path, first) > quot_or(8000000, cells, 0) {
        return Err("Brush stroke exceeds its native pixel budget");
    }
    let init = place(d, t.cells, first, start(d));
    let marks = repeat_until(length(path) - 1, init, fn(out) => false, fn(i) => fn(out) =>
        static_segment(d, t.cells, path.at_or(i, first), path.at_or(i + 1, first), out));
    return freeze_marks(marks);
}

fn static_segment(d: grid.Drawing, cells: List<Dab>, from: grid.Point, to: grid.Point, old: Marks) -> Marks {
    let init = Segment { pen: grid.segment(from, to), marks: old };
    return repeat_until(grid.steps(from, to), init, fn(out) => false, fn(i) => fn(out) =>
        static_step(d, cells, out)).marks;
}

fn static_step(d: grid.Drawing, cells: List<Dab>, out: Segment) -> Segment {
    let pen = grid.advance(out.pen);
    return Segment { pen: pen, marks: place(d, cells, pen.position, out.marks) };
}
