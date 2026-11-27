module StudioPixelShapes;

import "std:json" as json;
import "pixel_bitmap_font.ink" as font;
import "pixel_bitmap_text.ink" as bitmap;
import "pixel_drawing_grid.ink" as grid;
import "pixel_mask.ink" as mask;
import "pixel_raster.ink" as raster;
import "pixel_values.ink" as value;

record Box { x: i32, y: i32, w: i32, h: i32, }
record Style { width: i32, fill: Bool, }
record Trace { pen: grid.Pen, words: Buffer<u32>, }
record Curve { a: raster.Position, b: raster.Position, c: raster.Position, d: raster.Position, }
record Steps { start: grid.Point, direction: grid.Point, vertical: Bool, }
record Staircase { steps: Steps, words: Buffer<u32>, issue: String, }

fn kind(raw: json.Json) -> String { return value.text(value.get(value.fields(raw), "type")); }

fn fields(name: String) -> List<String> {
    if name == "line" { return ["type", "from", "to", "width"]; }
    if name == "curve" { return ["type", "points", "width"]; }
    if name == "rect" { return ["type", "rect", "fill", "width"]; }
    if name == "ellipse" { return ["type", "rect", "fill", "width"]; }
    if name == "polygon" { return ["type", "points", "fill", "width"]; }
    if name == "text" { return ["type", "at", "text", "scale", "tracking", "leading", "align", "columns"]; }
    if name == "staircase" { return ["type", "from", "axis", "direction", "lengths"]; }
    return [];
}

fn coverage(d: grid.Drawing, raw: json.Json) -> Result<List<u32>, String> {
    let spec = value.fields(raw);
    let name = kind(raw);
    let keys = fields(name);
    if length(keys) == 0 || !value.only(spec, keys) {
        return Err("Choose a native line, curve, rectangle, ellipse, polygon, text or staircase");
    }
    let width: i32 = json.lookup(spec, "width").fold(fn(n) => value.integer(n, 1, 32).fold(fn(w) => w, fn(unit) => 0), fn(unit) => 1);
    if width == 0 || !grid.bool_field(spec, "fill") {
        return Err("Pixel shape width must be a whole pixel count and fill must be boolean");
    }
    let style = Style { width: width, fill: value.flag(spec, "fill", true) };
    if name == "rect" || name == "ellipse" { return rectangle(d, spec, style, name == "ellipse"); }
    if name == "staircase" { return staircase(d, spec); }
    if name == "text" { return bitmap_text(d, spec); }
    return draw_path(d, spec, style, name);
}

fn paint_span(words: Buffer<u32>, first: i32, last: i32, row: u32) -> Buffer<u32> {
    if first > last { return words; }
    return mask.fill(words, row + grid.unsigned(first), row + grid.unsigned(last));
}

fn axis_span(axis: grid.Axis, row: u32, x: i32, w: i32, words: Buffer<u32>) -> Buffer<u32> {
    if !axis.wrap {
        return paint_span(words, grid.max(0, x), grid.min(axis.size - 1, x + w - 1), row);
    }
    if w >= axis.size { return paint_span(words, 0, axis.size - 1, row); }
    let first = grid.normalize(x, axis);
    let last = first + w - 1;
    let covered = paint_span(words, first, grid.min(axis.size - 1, last), row);
    return paint_span(covered, 0, last - axis.size, row);
}

fn horizontal(d: grid.Drawing, y: i32, x: i32, w: i32, words: Buffer<u32>) -> Buffer<u32> {
    if y < 0 { return words; }
    let row = grid.unsigned(y) * d.grid.width;
    let covered = axis_span(d.x, row, x, w, words);
    if d.x.mirror == -2 { return covered; }
    return axis_span(d.x, row, d.x.mirror - x - w + 1, w, covered);
}

fn span(d: grid.Drawing, x: i32, y: i32, w: i32, words: Buffer<u32>) -> Buffer<u32> {
    let normal = grid.normalize(y, d.y);
    let covered = horizontal(d, normal, x, w, words);
    if d.y.mirror == -2 { return covered; }
    let reflected = grid.normalize(d.y.mirror - y, d.y);
    if reflected == normal { return covered; }
    return horizontal(d, reflected, x, w, covered);
}

fn block(d: grid.Drawing, b: Box, words: Buffer<u32>) -> Buffer<u32> {
    let x = b.x;
    let w = b.w;
    let mirrored = d.y.mirror != -2;
    let top = if mirrored { grid.min(0, d.y.mirror - d.y.size + 1) } else { 0 };
    let bottom = if mirrored { grid.max(d.y.size, d.y.mirror + 1) } else { d.y.size };
    let y = if d.y.wrap { b.y } else { grid.max(top, b.y) };
    let end = if d.y.wrap { y + grid.min(b.h, d.y.size) } else { grid.min(bottom, b.y + b.h) };
    return repeat_until(grid.unsigned(grid.max(0, end - y)), words, fn(out) => false, fn(i) => fn(out) =>
        span(d, x, y + grid.signed(i), w, out));
}

fn stamp(d: grid.Drawing, p: grid.Point, width: i32, words: Buffer<u32>) -> Buffer<u32> {
    let inset = grid.signed(quot_or(grid.unsigned(width - 1), 2, 0));
    return block(d, Box { x: p.x - inset, y: p.y - inset, w: width, h: width }, words);
}

fn trace(d: grid.Drawing, from: grid.Point, to: grid.Point, width: i32, words: Buffer<u32>) -> Buffer<u32> {
    let start = Trace { pen: grid.segment(from, to), words: words };
    return repeat_until(grid.steps(from, to), start, fn(out) => false, fn(i) => fn(out) =>
        trace_step(d, width, out)).words;
}

fn trace_step(d: grid.Drawing, width: i32, old: Trace) -> Trace {
    let next = grid.advance(old.pen);
    return Trace { pen: next, words: stamp(d, next.position, width, old.words) };
}

fn points(d: grid.Drawing, raw: List<json.Json>, lo: u32, hi: u32) -> Result<List<grid.Point>, String> {
    let issue = "Pixel shape needs a valid number of in-bounds integer points";
    if length(raw) < lo || length(raw) > hi { return Err(issue); }
    let decoded = raw.map(fn(p) => grid.point(p, d));
    if length(decoded.filter(fn(p) => !grid.inside(p, d))) != 0 { return Err(issue); }
    return Ok(decoded);
}

fn path_length(points: List<grid.Point>, first: grid.Point) -> u32 {
    return repeat_until(length(points) - 1, 1, fn(out) => false, fn(i) => fn(out) =>
        out + grid.steps(points.at_or(i, first), points.at_or(i + 1, first)));
}

fn path(d: grid.Drawing, points: List<grid.Point>, width: i32, seed: Buffer<u32>) -> Result<List<u32>, String> {
    let first = points.at_or(0, grid.absent());
    let weight = grid.unsigned(width);
    if d.supplied && path_length(points, first) * weight * weight > 8000000 {
        return Err("Pixel shape exceeds its native drawing budget");
    }
    let init = stamp(d, first, width, seed);
    let drawn = repeat_until(length(points) - 1, init, fn(out) => false, fn(i) => fn(out) =>
        trace(d, points.at_or(i, first), points.at_or(i + 1, first), width, out));
    return Ok(drawn.freeze());
}

fn draw_path(d: grid.Drawing, spec: List<json.Member>, style: Style, name: String) -> Result<List<u32>, String> {
    if name == "line" {
        let line = points(d, [value.get(spec, "from"), value.get(spec, "to")], 2, 2)?;
        return path(d, line, style.width, mask.blank(d.grid));
    }
    let raw = value.items(value.get(spec, "points"));
    if name == "curve" {
        let controls = points(d, raw, 3, 4)?;
        return path(d, curve_points(controls), style.width, mask.blank(d.grid));
    }
    let polygon = points(d, raw, 3, 128)?;
    let fill = if style.fill { polygon_fill(d, polygon) } else { mask.blank(d.grid) };
    let outline = polygon.concat([polygon.at_or(0, grid.absent())]);
    return path(d, outline, if style.fill { 1 } else { style.width }, fill);
}

fn xy(p: grid.Point) -> raster.Position {
    return raster.Position { x: f64_from_i32(p.x), y: f64_from_i32(p.y) };
}

fn curve_distance(a: raster.Position, b: raster.Position) -> f64 {
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    let high = value.max(mask.abs(dx), mask.abs(dy));
    if high == 0.0f64 { return 0.0f64; }
    // Match the scaled two-argument hypot used by the original path sampler.
    let x = dx / high;
    let y = dy / high;
    return sqrt(x * x + y * y) * high;
}

fn control(from: raster.Position, to: raster.Position) -> raster.Position {
    let factor = 2.0f64 / 3.0f64;
    return raster.Position { x: from.x + factor * (to.x - from.x), y: from.y + factor * (to.y - from.y) };
}

fn curve_points(points: List<grid.Point>) -> List<grid.Point> {
    let empty = grid.absent();
    let a = xy(points.at_or(0, empty));
    let b = xy(points.at_or(1, empty));
    let c = xy(points.at_or(2, empty));
    let cubic = length(points) == 4;
    let d = if cubic { xy(points.at_or(3, empty)) } else { c };
    let length = (curve_distance(a, b) + curve_distance(b, c)) + curve_distance(c, d);
    let steps = value.as_word(value.max(8.0f64, value.min(64.0f64, ceil(length))));
    let curve = if cubic { Curve { a: a, b: b, c: c, d: d } } else {
        Curve { a: a, b: control(a, b), c: control(c, b), d: c }
    };
    let initial: Buffer<grid.Point> = Buffer.empty();
    let first = initial.push(points.at_or(0, empty));
    return repeat_until(steps, first, fn(out) => false, fn(i) => fn(out) =>
        out.push(curve_point(curve, f64_from_u32(i + 1) / f64_from_u32(steps)))).freeze();
}

fn round_cell(n: f64) -> i32 {
    let base = floor(n);
    let rounded = if n - base >= 0.5f64 { base + 1.0f64 } else { base };
    return i32_from_f64(rounded).fold(fn(i) => i, fn(unit) => 0);
}

fn curve_axis(a: f64, b: f64, c: f64, d: f64, t: f64) -> i32 {
    let u = 1.0f64 - t;
    return round_cell(u * u * u * a + 3.0f64 * u * u * t * b + 3.0f64 * u * t * t * c + t * t * t * d);
}

fn curve_point(c: Curve, t: f64) -> grid.Point {
    return grid.Point { x: curve_axis(c.a.x, c.b.x, c.c.x, c.d.x, t),
        y: curve_axis(c.a.y, c.b.y, c.c.y, c.d.y, t) };
}

fn side(raw: json.Json, axis: grid.Axis) -> i32 {
    let limit: i32 = if axis.wrap { grid.max(512, axis.size * 3) } else { 512 };
    return value.integer(raw, 1, limit).fold(fn(n) => n, fn(unit) => 0);
}

fn rectangle(d: grid.Drawing, spec: List<json.Member>, style: Style, oval: Bool) -> Result<List<u32>, String> {
    let raw = value.items(value.get(spec, "rect"));
    let x = grid.drawing_coordinate(raw.at_or(0, json.null()), d.x);
    let y = grid.drawing_coordinate(raw.at_or(1, json.null()), d.y);
    let w = side(raw.at_or(2, json.null()), d.x);
    let h = side(raw.at_or(3, json.null()), d.y);
    if length(raw) != 4 || x == -30000 || y == -30000 || w == 0 || h == 0 {
        return Err("Pixel rectangle or ellipse needs an integer origin and positive size");
    }
    let b = Box { x: x, y: y, w: w, h: h };
    let init = mask.blank(d.grid);
    if style.fill && !oval { return Ok(block(d, b, init).freeze()); }
    let rows = if d.supplied { h } else { grid.min(h, d.y.size - y) };
    return Ok(repeat_until(grid.unsigned(rows), init, fn(out) => false, fn(i) => fn(out) =>
        rectangle_row(d, b, style, oval, grid.signed(i), out)).freeze());
}

fn inside_ellipse(x: i32, y: i32, w: i32, h: i32) -> Bool {
    if w <= 0 || h <= 0 { return false; }
    let xf = f64_from_i32(2 * x + 1 - w) / f64_from_i32(w);
    let yf = f64_from_i32(2 * y + 1 - h) / f64_from_i32(h);
    return xf * xf + yf * yf <= 1.0f64;
}

fn oval_boundary(row: i32, w: i32, h: i32) -> i32 {
    if w <= 0 || h <= 0 || row < 0 || row >= h { return 0 - w; }
    let high = grid.signed(quot_or(grid.unsigned(w + 1), 2, 0));
    let bounds: Vec2<i32> = vec2(0, high);
    let found = repeat_until(12, bounds, fn(b) => b.x >= b.y, fn(i) => fn(b) =>
        oval_probe(b, row, w, h));
    return found.x;
}

fn oval_probe(b: Vec2<i32>, row: i32, w: i32, h: i32) -> Vec2<i32> {
    let mid = grid.signed(quot_or(grid.unsigned(b.x + b.y), 2, 0));
    return if inside_ellipse(mid, row, w, h) { vec2(b.x, mid) } else { vec2(mid + 1, b.y) };
}

fn rectangle_row(d: grid.Drawing, b: Box, style: Style, oval: Bool, row: i32, words: Buffer<u32>) -> Buffer<u32> {
    let start: i32 = if oval { oval_boundary(row, b.w, b.h) } else { 0 };
    let end = b.w - start;
    if end <= start { return words; }
    let t = style.width;
    let y = b.y + row;
    if style.fill || row < t || row >= b.h - t || b.w <= 2 * t {
        return span(d, b.x + start, y, end - start, words);
    }
    let inner: i32 = if oval { t + oval_boundary(row - t, b.w - 2 * t, b.h - 2 * t) } else { t };
    if b.w - 2 * inner <= 0 { return span(d, b.x + start, y, end - start, words); }
    let edge = grid.min(end, inner);
    if edge <= start { return words; }
    let left = span(d, b.x + start, y, edge - start, words);
    return span(d, b.x + b.w - edge, y, edge - start, left);
}

fn grow(bounds: Box, p: grid.Point) -> Box {
    let x = grid.min(bounds.x, p.x);
    let y = grid.min(bounds.y, p.y);
    return Box { x: x, y: y, w: grid.max(bounds.x + bounds.w, p.x + 1) - x,
        h: grid.max(bounds.y + bounds.h, p.y + 1) - y };
}

fn polygon_fill(d: grid.Drawing, points: List<grid.Point>) -> Buffer<u32> {
    let first = points.at_or(0, grid.absent());
    let start = Box { x: first.x, y: first.y, w: 1, h: 1 };
    let b = if d.supplied { foldl(points, start, fn(p) => fn(out) => grow(out, p)) }
        else { Box { x: 0, y: 0, w: d.x.size, h: d.y.size } };
    let local = points.map(fn(p) => raster.Position { x: f64_from_i32(p.x - b.x) + 0.5f64,
        y: f64_from_i32(p.y - b.y) + 0.5f64 });
    let polygon = raster.Polygon { edges: raster.edges([local]),
        area: raster.Box { x: 0, y: 0, w: grid.unsigned(b.w), h: grid.unsigned(b.h) } };
    return repeat_until(polygon.area.h, mask.blank(d.grid), fn(out) => false, fn(y) => fn(out) =>
        polygon_row(d, b, polygon, y, out));
}

fn polygon_row(d: grid.Drawing, b: Box, poly: raster.Polygon, y: u32, words: Buffer<u32>) -> Buffer<u32> {
    let init: Buffer<f32> = buffer_fill(poly.area.w, 0.0);
    let sampled = repeat_until(4, init, fn(out) => false, fn(i) => fn(out) => raster.polygon_sample(poly, y, i, out)).freeze();
    let row = b.y + grid.signed(y);
    return repeat_until(poly.area.w, words, fn(out) => false, fn(i) => fn(out) =>
        if sampled.at_or(i, 0.0) >= 0.5 { span(d, b.x + grid.signed(i), row, 1, out) } else { out });
}

fn step_lengths(raw: json.Json) -> List<i32> {
    return value.items(raw).map(fn(n) => value.integer(n, 1, 512).fold(fn(i) => i, fn(unit) => 0));
}

fn staircase(d: grid.Drawing, spec: List<json.Member>) -> Result<List<u32>, String> {
    let p = grid.point(value.get(spec, "from"), d);
    let axis = value.text(value.get(spec, "axis"));
    let direction = value.items(value.get(spec, "direction"));
    let dx = value.integer(direction.at_or(0, json.null()), -1, 1).fold(fn(i) => i, fn(unit) => 0);
    let dy = value.integer(direction.at_or(1, json.null()), -1, 1).fold(fn(i) => i, fn(unit) => 0);
    let sizes = step_lengths(value.get(spec, "lengths"));
    if !grid.inside(p, d) || (axis != "x" && axis != "y") || length(direction) != 2 || dx == 0 || dy == 0 ||
        length(sizes) == 0 || length(sizes) > 512 || length(sizes.filter(fn(i) => i == 0)) != 0 {
        return Err("Invalid pixel step stroke");
    }
    let steps = Steps { start: p, direction: grid.Point { x: dx, y: dy }, vertical: axis == "y" };
    let init = Staircase { steps: steps, words: mask.blank(d.grid), issue: "" };
    let traced = repeat_until(length(sizes), init, fn(out) => out.issue != "", fn(i) => fn(out) =>
        step(d, sizes.at_or(i, 0), out));
    if traced.issue != "" { return Err(traced.issue); }
    return Ok(traced.words.freeze());
}

fn step(d: grid.Drawing, n: i32, old: Staircase) -> Staircase {
    let s = old.steps;
    let p = s.start;
    let dx = s.direction.x;
    let dy = s.direction.y;
    let w: i32 = if s.vertical { 1 } else { n };
    let h: i32 = if s.vertical { n } else { 1 };
    let last = grid.Point { x: p.x + (w - 1) * dx, y: p.y + (h - 1) * dy };
    if !grid.inside(p, d) || !grid.inside(last, d) {
        return Staircase { ..old, issue: "A pixel step stroke leaves the native grid" };
    }
    let start = grid.Point { x: last.x + dx, y: last.y + dy };
    let b = Box { x: grid.min(p.x, last.x), y: grid.min(p.y, last.y), w: w, h: h };
    return Staircase { steps: Steps { ..s, start: start }, words: block(d, b, old.words), issue: "" };
}

record TextRows { cursor: u32, words: Buffer<u32>, }
record GlyphRow { bits: u32, words: Buffer<u32>, }

fn bitmap_text(d: grid.Drawing, spec: List<json.Member>) -> Result<List<u32>, String> {
    let text = bitmap.layout(d, spec)?;
    let atlas = font.atlas();
    let init = TextRows { cursor: 0, words: mask.blank(d.grid) };
    let stamped = repeat_until(length(text.rows), init, fn(out) => false, fn(i) => fn(out) =>
        text_row(d, text, atlas, i, out));
    return Ok(stamped.words.freeze());
}

fn text_row(d: grid.Drawing, t: bitmap.Text, atlas: font.Font, i: u32, old: TextRows) -> TextRows {
    let n = t.rows.at_or(i, 0);
    let start = t.origin.x + grid.signed(bitmap.alignment(t, n));
    let y = t.origin.y + grid.signed(i * bitmap.line_step(t.options));
    let words = repeat_until(n, old.words, fn(out) => false, fn(j) => fn(out) =>
        draw_glyph(d, atlas, t.codes.at_or(old.cursor + j, 32),
            grid.Point { x: start + grid.signed(j * bitmap.advance(t.options)), y: y }, t.options.scale, out));
    return TextRows { cursor: old.cursor + n, words: words };
}

fn draw_glyph(d: grid.Drawing, atlas: font.Font, code: u32, p: grid.Point, scale: u32, words: Buffer<u32>) -> Buffer<u32> {
    let bits = bitmap.glyph(atlas, code);
    return repeat_until(8, words, fn(out) => false, fn(i) => fn(out) =>
        glyph_row(d, bits, p, scale, i, out));
}

fn glyph_row(d: grid.Drawing, bits: Vec2<u32>, p: grid.Point, scale: u32, i: u32, words: Buffer<u32>) -> Buffer<u32> {
    let packed = if i < 4 { bits.x } else { bits.y };
    let row = word_and(wrapping_shr(packed, word_and(i, 3) * 6), 63);
    let start = GlyphRow { bits: row, words: words };
    let y = p.y + grid.signed(i * scale);
    return repeat_until(6, start, fn(out) => out.bits == 0, fn(j) => fn(out) =>
        glyph_run(d, p.x, y, scale, out)).words;
}

fn glyph_run(d: grid.Drawing, x: i32, y: i32, scale: u32, old: GlyphRow) -> GlyphRow {
    let first = trailing_zeros(old.bits);
    let tail = wrapping_shr(old.bits, first);
    // Bit six terminates a run at the right glyph boundary.
    let n = trailing_zeros(word_xor(tail, 127));
    let remaining = word_xor(old.bits, wrapping_shl(mask.low_bits(n), first));
    let b = Box { x: x + grid.signed(first * scale), y: y, w: grid.signed(n * scale), h: grid.signed(scale) };
    return GlyphRow { bits: remaining, words: block(d, b, old.words) };
}
