module StudioPixelDrawingGrid;

import "std:json" as json;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;

record Point { x: i32, y: i32, }
record Axis { size: i32, mirror: i32, wrap: Bool, }
record Drawing { grid: mask.Grid, x: Axis, y: Axis, supplied: Bool, }
record Pen { position: Point, dx: i32, dy: i32, sx: i32, sy: i32, error: i32, }

fn signed(n: u32) -> i32 { return i32_from_f64(f64_from_u32(n)).fold(fn(x) => x, fn(unit) => 0); }
fn unsigned(n: i32) -> u32 { return value.as_word(f64_from_i32(n)); }
fn absent() -> Point { return Point { x: -30000, y: -30000 }; }
fn abs(n: i32) -> i32 { return if n < 0 { -n } else { n }; }
fn sign(n: i32) -> i32 { return if n < 0 { -1 } else { if n > 0 { 1 } else { 0 } }; }

fn axis(size: u32, raw: json.Json, wrap: Bool, has_mirror: Bool) -> Axis {
    if !has_mirror { return Axis { size: signed(size), mirror: -2, wrap: wrap }; }
    let n = value.number(raw) * 2.0f64;
    let valid = n == trunc(n) && n >= -1.0f64 && n <= f64_from_u32(size * 2 - 1);
    let mirror = if valid { i32_from_f64(n).fold(fn(p) => p, fn(unit) => -3) } else { -3 };
    return Axis { size: signed(size), mirror: mirror, wrap: wrap };
}

fn bool_field(items: List<json.Member>, key: String) -> Bool {
    return json.lookup(items, key).fold(fn(v) => json.as_boolean(v).fold(fn(b) => true, fn(issue) => false), fn(unit) => true);
}

fn drawing(g: mask.Grid, items: List<json.Member>) -> Result<Drawing, String> {
    let options: Result<List<json.Member>, String> = json.lookup(items, "drawing").fold(fn(v) =>
        json.members(v).fold(fn(rows) => Ok(rows), fn(issue) => Err("Drawing grid accepts mirrorX, mirrorY, wrapX and wrapY")),
        fn(unit) => Ok([]));
    let raw = options?;
    if !value.only(raw, ["mirrorX", "mirrorY", "wrapX", "wrapY"]) {
        return Err("Drawing grid accepts mirrorX, mirrorY, wrapX and wrapY");
    }
    let x = axis(g.width, value.get(raw, "mirrorX"), value.flag(raw, "wrapX", false), value.has(raw, "mirrorX"));
    let y = axis(g.height, value.get(raw, "mirrorY"), value.flag(raw, "wrapY", false), value.has(raw, "mirrorY"));
    if x.mirror == -3 || y.mirror == -3 || !bool_field(raw, "wrapX") || !bool_field(raw, "wrapY") {
        return Err("Mirror axes need pixel or half-pixel positions on the canvas. Wrap flags must be boolean.");
    }
    return Ok(Drawing { grid: g, x: x, y: y, supplied: value.has(items, "drawing") });
}

fn drawing_coordinate(raw: json.Json, d: Axis) -> i32 {
    let lo: i32 = if d.wrap { -d.size } else { 0 };
    let hi: i32 = if d.wrap { 2 * d.size - 1 } else { d.size - 1 };
    return value.integer(raw, lo, hi).fold(fn(x) => x, fn(u) => -30000);
}

fn point(raw: json.Json, grid: Drawing) -> Point {
    let xy = value.items(raw);
    if length(xy) != 2 { return absent(); }
    let x = drawing_coordinate(xy.at_or(0, json.null()), grid.x);
    let y = drawing_coordinate(xy.at_or(1, json.null()), grid.y);
    return Point { x: x, y: y };
}

fn normalize(n: i32, axis: Axis) -> i32 {
    if !axis.wrap { return if n < 0 || n >= axis.size { -1 } else { n }; }
    let rest = signed(rem_or(unsigned(abs(n)), unsigned(axis.size), 0));
    return if n < 0 && rest != 0 { axis.size - rest } else { rest };
}

fn position(g: mask.Grid, x: i32, y: i32) -> u32 {
    return if x < 0 || y < 0 { 4294967295 } else { unsigned(y) * g.width + unsigned(x) };
}

// Keep the original visitation order so the first rejected mirror is stable.
fn copies(grid: Drawing, p: Point) -> List<u32> {
    let a = normalize(p.x, grid.x);
    let b = normalize(p.y, grid.y);
    let c = if grid.x.mirror == -2 { -1 } else { normalize(grid.x.mirror - p.x, grid.x) };
    let d = if grid.y.mirror == -2 { -1 } else { normalize(grid.y.mirror - p.y, grid.y) };
    return [position(grid.grid, a, b), if c != a { position(grid.grid, c, b) } else { 4294967295 },
        if d != b { position(grid.grid, a, d) } else { 4294967295 },
        if c != a && d != b { position(grid.grid, c, d) } else { 4294967295 }].filter(fn(i) => i != 4294967295);
}

fn min(a: i32, b: i32) -> i32 { return if a < b { a } else { b }; }
fn max(a: i32, b: i32) -> i32 { return if a > b { a } else { b }; }

fn contains(n: i32, axis: Axis) -> Bool {
    return if axis.wrap { n >= -axis.size && n < 2 * axis.size } else { n >= 0 && n < axis.size };
}

fn inside(p: Point, grid: Drawing) -> Bool { return contains(p.x, grid.x) && contains(p.y, grid.y); }

fn steps(from: Point, to: Point) -> u32 { return unsigned(max(abs(to.x - from.x), abs(to.y - from.y))); }

fn path_steps(points: List<Point>, first: Point) -> u32 {
    return repeat_until(length(points) - 1, 1, fn(out) => false, fn(i) => fn(out) =>
        out + steps(points.at_or(i, first), points.at_or(i + 1, first)));
}

fn segment(from: Point, to: Point) -> Pen {
    let dx = abs(to.x - from.x);
    let dy = -abs(to.y - from.y);
    return Pen { position: from, dx: dx, dy: dy,
        sx: sign(to.x - from.x), sy: sign(to.y - from.y), error: dx + dy };
}

fn advance(pen: Pen) -> Pen {
    let twice = pen.error * 2;
    let x = twice >= pen.dy;
    let y = twice <= pen.dx;
    let next = Point { x: pen.position.x + (if x { pen.sx } else { 0 }),
        y: pen.position.y + (if y { pen.sy } else { 0 }) };
    return Pen { ..pen, position: next, error: pen.error + (if x { pen.dy } else { 0 }) + (if y { pen.dx } else { 0 }) };
}
