module StudioPixelRaster;

import "std:json" as json;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as values;

record Work { marks: u32, runs: u32, }
record Raw { slots: List<i32>, alpha: List<u32>, work: Work, issue: String, }
record Paint { slots: Buffer<i32>, alpha: Buffer<u32>, work: Work, drawing: u32, issue: String, }
record Rect { x: f64, y: f64, right: f64, bottom: f64, }
record Box { x: u32, y: u32, w: u32, h: u32, }
record Span { start: u32, length: u32, }
record Runs { paint: Paint, end: u32, }
record RunMark { slot: i32, alpha: Option<u32>, spans: List<Vec3<u32>>, }
// Editor-created marks are already validated spans. Keep their authored prefix in order.
record RunCache { prefix: List<json.Json>, tail: List<RunMark>, }
record Step { x: i32, y: i32, dx: i32, dy: i32, down: Bool, }
record Stroke { paint: Paint, tip: Step, }
record Position { x: f64, y: f64, }
record Edge { start: Position, end: Position, }
record Polygon { edges: List<Edge>, area: Box, }
record Fade { mode: String, origin: Position, direction: Position, scale: f64,
    begin: f64, end: f64, ink: f64, smooth: Bool, issue: String, }
record Ink { id: i32, alpha: f64, issue: String, }
record Line { edge: Edge, first: f64, last: f64, }
record Lines { coverage: Buffer<f32>, area: Box, work: u32, issue: String, }

fn untouched() -> Work { return Work { marks: 0, runs: 0 }; }

fn slot(ids: List<String>, swatch: json.Json) -> i32 {
    if swatch == json.null() { return -2; }
    let name = values.text(swatch);
    let missing: i32 = -3;
    return repeat_until(length(ids), missing, fn(index) => index >= 0, fn(i) => fn(index) =>
        if ids.at_or(i, "") == name {
            i32_from_f64(f64_from_u32(i)).fold(fn(value) => value, fn(unit) => missing)
        } else { index });
}

fn initial(g: mask.Grid, ids: List<String>, content: List<json.Member>, work: Work) -> Paint {
    let count = mask.size(g);
    let empty: Buffer<u32> = Buffer.empty();
    let slots: Buffer<i32> = buffer_fill(count, -1);
    let base = Paint { slots: slots, alpha: empty, work: work, drawing: 0, issue: "" };
    if !values.has(content, "slots") { return base; }
    let authored = values.items(values.get(content, "slots"));
    if length(authored) != count {
        return Paint { ..base, issue: "Pixel layer slots need a named swatch or null per art pixel" };
    }
    var i: u32 = 0;
    var out: Paint = base;
    for swatch in authored {
        let id = slot(ids, swatch);
        if out.issue == "" {
            out = if id == -3 { Paint { ..out, issue: unknown_swatch(swatch) } }
                else { Paint { ..out, slots: out.slots.set(i, if id == -2 { -1 } else { id }) } };
        }
        i = i + 1;
    }
    return out;
}

fn unknown_swatch(raw: json.Json) -> String {
    let name = json.as_text(raw).fold(fn(value) => value, fn(error) =>
        json.as_number(raw).fold(fn(value) => value, fn(error) =>
            json.as_boolean(raw).fold(fn(value) => if value { "true" } else { "false" }, fn(error) => "undefined")));
    return string_concat("Unknown pixel swatch ", name);
}

fn spend_marks(paint: Paint, count: u32) -> Paint {
    if paint.work.marks + count > 4096 {
        return Paint { ..paint, issue: "Pixel designs support up to 4096 drawing operations" };
    }
    let work = Work { ..paint.work, marks: paint.work.marks + count };
    return Paint { ..paint, work: work };
}

fn spend_runs(paint: Paint, count: u32) -> Paint {
    if paint.work.runs + count > 32000000 {
        return Paint { ..paint, issue: "Pixel runs exceed the drawing budget" };
    }
    let work = Work { ..paint.work, runs: paint.work.runs + count };
    return Paint { ..paint, work: work };
}

fn write_span(paint: Paint, run: Span, id: i32) -> Paint {
    let alpha = if id < 0 && paint.alpha.len() != 0 { paint.alpha.fill_range(run.start, run.length, 255) } else { paint.alpha };
    return Paint { ..paint, slots: paint.slots.fill_range(run.start, run.length, id), alpha: alpha };
}

fn draw_slot(paint: Paint, p: u32, id: i32) -> Paint {
    return Paint { ..paint, slots: paint.slots.set(p, id) };
}

fn reset_erased_alpha(paint: Paint, p: u32) -> Paint {
    if paint.slots.at_or(p, -1) != -2 { return paint; }
    return Paint { ..paint, alpha: paint.alpha.set(p, 255) };
}

fn write_alpha(paint: Paint, p: u32, opacity: u32) -> Paint {
    if paint.slots.at_or(p, -1) < 0 { return paint; }
    return Paint { ..paint, alpha: paint.alpha.set(p, opacity) };
}

fn span(g: mask.Grid, value: json.Json) -> Span {
    let row = values.items(value);
    let y = values.word(row.at_or(0, json.null()), g.height - 1);
    let x = values.word(row.at_or(1, json.null()), g.width - 1);
    if length(row) != 3 || y >= g.height || x >= g.width { return Span { start: 0, length: 0 }; }
    let n = values.word(row.at_or(2, json.null()), g.width - x);
    return Span { start: y * g.width + x, length: if n == 4294967295 { 0 } else { n } };
}

fn run_mark(g: mask.Grid, spec: List<json.Member>, slot: i32, paint: Paint) -> Paint {
    let is_alpha = values.has(spec, "alpha");
    let clears = values.has(spec, "clear");
    let alpha = values.word(values.get(spec, "alpha"), 255);
    let valid = if is_alpha { alpha <= 255 && values.only(spec, ["alpha", "runs"]) } else {
        values.only(spec, ["swatch", "clear", "runs"]) &&
        (if clears { values.flag(spec, "clear", false) && !values.has(spec, "swatch") } else { slot != -3 })
    };
    if !valid { return Paint { ..paint, issue: "A pixel run mark needs a swatch, clear flag or alpha byte" }; }
    let rows = values.items(values.get(spec, "runs"));
    if length(rows) == 0 || length(rows) > mask.size(g) {
        return Paint { ..paint, issue: "A pixel run mark needs native runs" };
    }
    var out: Paint = spend_marks(Paint { ..paint, drawing: 0 }, 1);
    if is_alpha && out.alpha.len() == 0 {
        out = Paint { ..out, alpha: buffer_fill(mask.size(g), 255) };
    }
    let id: i32 = if clears { -1 } else { slot };
    let start = Runs { paint: out, end: 0 };
    return foldl(rows, start, fn(row) => fn(next) => apply_run(g, row, is_alpha, alpha, id, next)).paint;
}

fn apply_run(g: mask.Grid, row: json.Json, is_alpha: Bool, alpha: u32, id: i32, old: Runs) -> Runs {
    if old.paint.issue != "" { return old; }
    let run = span(g, row);
    if run.length == 0 {
        return Runs { ..old, paint: Paint { ..old.paint, issue: "Pixel runs need in-bounds [row, column, length] values" } };
    }
    if run.start < old.end {
        return Runs { ..old, paint: Paint { ..old.paint, issue: "Pixel runs need sorted, non-overlapping spans" } };
    }
    let charged = spend_runs(old.paint, run.length);
    if charged.issue != "" { return Runs { ..old, paint: charged }; }
    let next = if is_alpha {
        repeat_until(run.length, charged, fn(out) => false, fn(i) => fn(out) => write_alpha(out, run.start + i, alpha))
    } else { write_span(charged, run, id) };
    return Runs { paint: next, end: run.start + run.length };
}

fn point(g: mask.Grid, raw: json.Json) -> Vec2<u32> {
    let xy = values.items(raw);
    if length(xy) != 2 { return vec2(g.width, g.height); }
    return vec2(values.word(xy.at_or(0, json.null()), g.width - 1), values.word(xy.at_or(1, json.null()), g.height - 1));
}

fn inside(g: mask.Grid, p: Vec2<u32>) -> Bool { return p.x < g.width && p.y < g.height; }

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect { return Rect { x: x, y: y, right: x + w, bottom: y + h }; }

fn clipped(g: mask.Grid, r: Rect) -> Box {
    let w = f64_from_u32(g.width);
    let h = f64_from_u32(g.height);
    let x = values.as_word(values.min(w, values.max(0.0f64, floor(r.x))));
    let y = values.as_word(values.min(h, values.max(0.0f64, floor(r.y))));
    let right = values.as_word(values.min(w, values.max(0.0f64, ceil(r.right))));
    let bottom = values.as_word(values.min(h, values.max(0.0f64, ceil(r.bottom))));
    return Box { x: x, y: y, w: if right > x { right - x } else { 0 },
        h: if bottom > y { bottom - y } else { 0 } };
}

fn position(raw: json.Json) -> Position {
    let xy = values.items(raw);
    let x = values.number(xy.at_or(0, json.null()));
    let y = values.number(xy.at_or(1, json.null()));
    if length(xy) != 2 || !is_finite(x) || !is_finite(y) ||
        x < -1000000000000.0f64 || x > 1000000000000.0f64 || y < -1000000000000.0f64 || y > 1000000000000.0f64 {
        return Position { x: values.missing_number(), y: values.missing_number() };
    }
    return Position { x: x, y: y };
}

fn scalar(x: f64) -> f64 { return values.min(1.0f64, values.max(0.0f64, x)); }

fn no_fade() -> Fade {
    let p = Position { x: 0.0f64, y: 0.0f64 };
    return Fade { mode: "", origin: p, direction: p, scale: 1.0f64,
        begin: 1.0f64, end: 0.0f64, ink: 1.0f64, smooth: false, issue: "" };
}

fn fade(raw: json.Json) -> Fade {
    let empty = no_fade();
    if raw == json.boolean(false) { return empty; }
    let spec = values.fields(raw);
    if !json.members(raw).fold(fn(m) => true, fn(error) => false) ||
        !values.only(spec, ["type", "from", "to", "center", "radii", "opacity", "curve"]) {
        return Fade { ..empty, issue: "Invalid drawing falloff" };
    }
    let kind = json.lookup(spec, "type").fold(fn(v) => values.text(v), fn(unit) => "linear");
    let curve = json.lookup(spec, "curve").fold(fn(v) => values.text(v), fn(unit) => "smooth");
    let levels = json.lookup(spec, "opacity").fold(fn(v) => position(v), fn(unit) => Position { x: 1.0f64, y: 0.0f64 });
    if !is_finite(levels.x) || levels.x < 0.0f64 || levels.x > 1.0f64 || levels.y < 0.0f64 || levels.y > 1.0f64 ||
        !(curve == "linear" || curve == "smooth") {
        return Fade { ..empty, issue: "Drawing falloff needs two opacities in [0, 1] and a linear or smooth curve" };
    }
    let style = Fade { ..empty, mode: kind, begin: levels.x, end: levels.y, smooth: curve == "smooth" };
    if kind == "linear" {
        if values.has(spec, "center") || values.has(spec, "radii") { return Fade { ..style, issue: "Linear falloff uses from and to" }; }
        let start = position(values.get(spec, "from"));
        let end = position(values.get(spec, "to"));
        if !is_finite(start.x) { return Fade { ..style, issue: "Falloff start needs a finite XY vector" }; }
        if !is_finite(end.x) { return Fade { ..style, issue: "Falloff end needs a finite XY vector" }; }
        let dx = end.x - start.x;
        let dy = end.y - start.y;
        let distance = dx * dx + dy * dy;
        if distance < 0.0000000000000001f64 { return Fade { ..style, issue: "Linear falloff needs distinct endpoints" }; }
        return Fade { ..style, origin: start, direction: Position { x: dx, y: dy }, scale: distance };
    }
    if kind != "radial" || values.has(spec, "from") || values.has(spec, "to") {
        return Fade { ..style, issue: "Drawing falloff must be linear or radial" };
    }
    let center = position(values.get(spec, "center"));
    let radii = position(values.get(spec, "radii"));
    if !is_finite(center.x) { return Fade { ..style, issue: "Falloff center needs a finite XY vector" }; }
    if !is_finite(radii.x) { return Fade { ..style, issue: "Falloff radii needs a finite XY vector" }; }
    if radii.x < 0.0f64 || radii.y <= radii.x { return Fade { ..style, issue: "Radial falloff needs increasing nonnegative radii" }; }
    return Fade { ..style, origin: center, direction: radii, scale: radii.y - radii.x };
}

fn falloff(spec: List<json.Member>, key: String, otherwise: Fade) -> Fade {
    return json.lookup(spec, key).fold(fn(v) => fade(v), fn(unit) => otherwise);
}

fn tone(style: Fade, x: u32, y: u32) -> f64 {
    if style.mode == "" { return style.ink; }
    let u = f64_from_u32(x) + 0.5f64 - style.origin.x;
    let v = f64_from_u32(y) + 0.5f64 - style.origin.y;
    let distance = if style.mode == "linear" { u * style.direction.x + v * style.direction.y }
        else { sqrt(u * u + v * v) - style.direction.x };
    let t = scalar(distance / style.scale);
    let ramp = style.begin + (style.end - style.begin) * (if style.smooth { t * t * (3.0f64 - 2.0f64 * t) } else { t });
    return style.ink * ramp;
}

fn rect_pixel(r: Rect, style: Fade, x: u32, y: u32) -> Bool {
    let px = f64_from_u32(x);
    let py = f64_from_u32(y);
    let coverage = (values.min(px + 1.0f64, r.right) - values.max(px, r.x)) *
        (values.min(py + 1.0f64, r.bottom) - values.max(py, r.y));
    return f64_from_f32(f32_from_f64(coverage)) * tone(style, x, y) >= 0.5f64;
}

fn draw_rect(g: mask.Grid, r: Rect, id: i32, style: Fade, paint: Paint) -> Paint {
    let area = clipped(g, r);
    let work = paint.drawing + 2 * area.w * area.h;
    if work > 32000000 { return Paint { ..paint, issue: "Drawing exceeds its raster work budget" }; }
    let charged = Paint { ..paint, drawing: work };
    if aligned(r) && style.mode == "" && style.ink == 1.0f64 {
        let filled = solid_rect(g, area, id, charged.slots);
        return Paint { ..charged, slots: filled };
    }
    return repeat_until(area.h, charged, fn(out) => false, fn(v) => fn(out) =>
        repeat_until(area.w, out, fn(next) => false, fn(u) => fn(next) =>
            if rect_pixel(r, style, area.x + u, area.y + v) {
                draw_slot(next, (area.y + v) * g.width + area.x + u, id)
            } else { next }));
}

fn aligned(r: Rect) -> Bool {
    return r.x == trunc(r.x) && r.y == trunc(r.y) && r.right == trunc(r.right) && r.bottom == trunc(r.bottom);
}

fn solid_rect(g: mask.Grid, area: Box, id: i32, slots: Buffer<i32>) -> Buffer<i32> {
    if area.w == 0 || area.h == 0 { return slots; }
    if area.w == g.width { return slots.fill_range(area.y * g.width, area.w * area.h, id); }
    return repeat_until(area.h, slots, fn(out) => false, fn(y) => fn(out) =>
        out.fill_range((area.y + y) * g.width + area.x, area.w, id));
}

fn point_bounds(bounds: Rect, p: Position) -> Rect {
    return Rect { x: values.min(bounds.x, p.x), y: values.min(bounds.y, p.y),
        right: values.max(bounds.right, p.x), bottom: values.max(bounds.bottom, p.y) };
}

fn edge_at(points: List<Position>, at: u32, p: Position) -> Edge {
    let following = rem_or(at + 1, length(points), 0);
    return Edge { start: p, end: points.at_or(following, p) };
}

fn edges(rings: List<List<Position>>) -> List<Edge> {
    let empty: List<Edge> = [];
    return foldl(rings, empty, fn(points) => fn(out) =>
        out.concat(points.map_indexed(fn(i) => fn(p) => edge_at(points, i, p))));
}

fn crossing_bits(value: f64) -> u64 {
    let sign: u64 = 9223372036854775808;
    let bits = f64_bits(value);
    return word_xor(bits, if bits >= sign { 18446744073709551615 } else { sign });
}

fn crossing_value(key: u64) -> f64 {
    let sign: u64 = 9223372036854775808;
    return f64_from_bits(word_xor(key, if key >= sign { sign } else { 18446744073709551615 }));
}

fn crossing(e: Edge, y: f64, out: Buffer<u64>) -> Buffer<u64> {
    let a = e.start;
    let b = e.end;
    if (a.y > y) == (b.y > y) { return out; }
    return out.push(crossing_bits(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)));
}

fn cover_span(area: Box, left: f64, right: f64, copy: Buffer<f32>) -> Buffer<f32> {
    let last = f64_from_u32(area.x + area.w);
    let first = f64_from_u32(area.x);
    let from = values.as_word(values.min(last, values.max(first, floor(left))));
    let to = values.as_word(values.max(first, values.min(last, ceil(right))));
    if to <= from { return copy; }
    return repeat_until(to - from, copy, fn(cov) => false, fn(i) => fn(cov) =>
        add_coverage(from + i, area.x, left, right, cov));
}

fn add_coverage(column: u32, start: u32, left: f64, right: f64, cov: Buffer<f32>) -> Buffer<f32> {
    let x = f64_from_u32(column);
    let delta = values.max(0.0f64, values.min(x + 1.0f64, right) - values.max(x, left)) * 0.25f64;
    let limit = column - start;
    let accumulated = f64_from_f32(cov.at_or(limit, 0.0)) + delta;
    return cov.set(limit, f32_from_f64(accumulated));
}

fn polygon_sample(poly: Polygon, y: u32, sample: u32, coverage: Buffer<f32>) -> Buffer<f32> {
    let at = f64_from_u32(y) + (f64_from_u32(sample) + 0.5f64) * 0.25f64;
    let empty: Buffer<u64> = Buffer.empty();
    let sorted = foldl(poly.edges, empty, fn(edge) => fn(out) => crossing(edge, at, out)).freeze().sort();
    return repeat_until(quot_or(length(sorted), 2, 0), coverage, fn(out) => false, fn(i) => fn(out) =>
        cover_span(poly.area, crossing_value(sorted.at_or(i * 2, 0)), crossing_value(sorted.at_or(i * 2 + 1, 0)), out));
}

fn polygon_row(g: mask.Grid, polygon: Polygon, row: u32, id: i32, style: Fade, paint: Paint) -> Paint {
    let init: Buffer<f32> = buffer_fill(polygon.area.w, 0.0);
    let coverage = repeat_until(4, init, fn(out) => false, fn(i) => fn(out) => polygon_sample(polygon, row, i, out)).freeze();
    return repeat_until(polygon.area.w, paint, fn(out) => false, fn(i) => fn(out) =>
        if scalar(f64_from_f32(coverage.at_or(i, 0.0))) * tone(style, polygon.area.x + i, row) >= 0.5f64 {
            draw_slot(out, row * g.width + polygon.area.x + i, id)
        } else { out });
}

fn polygon_rings(spec: List<json.Member>) -> Result<List<List<Position>>, String> {
    let has_rings = values.has(spec, "rings");
    if has_rings == values.has(spec, "points") { return Err("Polygon needs points or rings"); }
    let raw = if has_rings { values.items(values.get(spec, "rings")) } else { [values.get(spec, "points")] };
    if length(raw) == 0 || length(raw) > 64 { return Err("Polygon needs 1 to 64 rings"); }
    let rings = raw.map(fn(ring) => values.items(ring).map(fn(point) => position(point)));
    if length(rings.filter(fn(ring) => length(ring) < 3 || length(ring) > 4096)) != 0 {
        return Err("Polygon ring needs 3 to 4096 points");
    }
    if length(rings.filter(fn(ring) => length(ring.filter(fn(point) => !is_finite(point.x))) != 0)) != 0 {
        return Err("Polygon ring needs a finite XY vector");
    }
    let size: u32 = foldl(rings, 0, fn(ring) => fn(total) => total + length(ring));
    if size > 4096 { return Err("Polygon exceeds its vertex budget"); }
    return Ok(rings);
}

fn width(spec: List<json.Member>) -> f64 {
    return json.lookup(spec, "width").fold(fn(v) => values.number(v), fn(unit) => 1.0f64);
}

fn width_issue(spec: List<json.Member>, thickness: f64) -> String {
    let units = values.get(spec, "widthUnits");
    if units != json.null() && units != json.text("px") { return "widthUnits must be px or world units on a world primitive"; }
    if !is_finite(thickness) || thickness < 0.00000001f64 || thickness > 1000000000.0f64 {
        return "Stroke width must be positive and finite";
    }
    return "";
}

fn hex(byte: u32) -> u32 {
    if byte >= 48 && byte <= 57 { return byte - 48; }
    if byte >= 65 && byte <= 70 { return byte - 55; }
    if byte >= 97 && byte <= 102 { return byte - 87; }
    return 4294967295;
}

fn parse_color(text: String, length: u32) -> u32 {
    return repeat_until(length, 0, fn(bits) => bits == 4294967295, fn(i) => fn(bits) =>
        color_digit(bits, hex(string_byte_at(text, i + 1).fold(fn(byte) => byte, fn(unit) => 0))));
}

fn color_digit(bits: u32, digit: u32) -> u32 {
    return if digit == 4294967295 { digit } else { bits * 16 + digit };
}

fn ink_color(raw: json.Json, default: i32, palette: u32) -> Ink {
    let original = Ink { id: default, alpha: 1.0f64, issue: "" };
    let text = values.text(raw);
    let n = string_byte_len(text);
    let invalid = Ink { ..original, issue: "Drawing color must be #rrggbb or #rrggbbaa" };
    if (n != 7 && n != 9) || string_byte_at(text, 0).fold(fn(byte) => byte, fn(unit) => 0) != 35 { return invalid; }
    let payload = parse_color(text, 6);
    let alpha = if n == 7 { 255 } else { color_alpha(text) };
    if payload == 4294967295 || alpha == 4294967295 { return invalid; }
    let ink = if payload == 0 { -1 } else { if payload - 1 == palette { -2 } else { signed_slot(payload - 1) } };
    return Ink { id: ink, alpha: f64_from_u32(alpha) / 255.0f64, issue: "" };
}

fn color_alpha(text: String) -> u32 {
    let high = hex(string_byte_at(text, 7).fold(fn(byte) => byte, fn(unit) => 0));
    let low = hex(string_byte_at(text, 8).fold(fn(byte) => byte, fn(unit) => 0));
    return if high > 15 || low > 15 { 4294967295 } else { high * 16 + low };
}

fn signed_slot(n: u32) -> i32 {
    let low = word_and(n, 65535);
    let x = if low >= 32768 { f64_from_u32(low) - 65536.0f64 } else { f64_from_u32(low) };
    return i32_from_f64(x).fold(fn(slot) => slot, fn(unit) => -1);
}

fn line_box(g: mask.Grid, line: Line) -> Box {
    let a = line.edge.start;
    let b = line.edge.end;
    let reach = values.max(line.first, line.last) + 0.5f64;
    return clipped(g, Rect { x: values.min(a.x, b.x) - reach, y: values.min(a.y, b.y) - reach,
        right: values.max(a.x, b.x) + reach, bottom: values.max(a.y, b.y) + reach });
}

fn line_coverage(line: Line, x: u32, y: u32) -> f32 {
    let ax = line.edge.start.x;
    let ay = line.edge.start.y;
    let dx = line.edge.end.x - ax;
    let dy = line.edge.end.y - ay;
    let u = f64_from_u32(x) + 0.5f64 - ax;
    let v = f64_from_u32(y) + 0.5f64 - ay;
    let distance = dx * dx + dy * dy;
    let t = if distance == 0.0f64 { 0.0f64 } else { scalar((u * dx + v * dy) / distance) };
    let r = line.first + (line.last - line.first) * t;
    let rx = u - dx * t;
    let ry = v - dy * t;
    return f32_from_f64(scalar(0.5f64 + (r - sqrt(rx * rx + ry * ry))));
}

fn line_cover(coverage: Buffer<f32>, p: u32, amount: f32) -> Buffer<f32> {
    let before = coverage.at_or(p, 0.0);
    return if amount > before { coverage.set(p, amount) } else { coverage };
}

fn union_area(a: Box, b: Box) -> Box {
    if a.w == 0 || a.h == 0 { return b; }
    let x = if a.x < b.x { a.x } else { b.x };
    let y = if a.y < b.y { a.y } else { b.y };
    let right = if a.x + a.w > b.x + b.w { a.x + a.w } else { b.x + b.w };
    let bottom = if a.y + a.h > b.y + b.h { a.y + a.h } else { b.y + b.h };
    return Box { x: x, y: y, w: right - x, h: bottom - y };
}

fn draw_line(g: mask.Grid, line: Line, old: Lines) -> Lines {
    if old.issue != "" || (line.first == 0.0f64 && line.last == 0.0f64) { return old; }
    let area = line_box(g, line);
    if area.w == 0 || area.h == 0 { return old; }
    let budget = old.work + area.w * area.h;
    if budget > 32000000 { return Lines { ..old, issue: "Drawing exceeds its raster work budget" }; }
    let combined = repeat_until(area.h, old.coverage, fn(out) => false, fn(v) => fn(out) =>
        repeat_until(area.w, out, fn(row) => false, fn(u) => fn(row) =>
            line_cover(row, (area.y + v) * g.width + area.x + u, line_coverage(line, area.x + u, area.y + v))));
    return Lines { coverage: combined, work: budget, issue: "", area: union_area(old.area, area) };
}

fn line_at(points: List<Position>, weights: List<f64>, radius: f64, i: u32) -> Line {
    let j = rem_or(i + 1, length(points), 0);
    let a = points.at_or(i, Position { x: 0.0f64, y: 0.0f64 });
    let edge = Edge { start: a, end: points.at_or(j, a) };
    return Line { edge: edge, first: radius * weights.at_or(i, 1.0f64), last: radius * weights.at_or(j, 1.0f64) };
}

fn polyline(g: mask.Grid, points: List<Position>, weights: List<f64>, radius: f64, closed: Bool, old: Lines) -> Lines {
    let count = length(points) - (if closed { 0 } else { 1 });
    return repeat_until(count, old, fn(out) => out.issue != "", fn(i) => fn(out) =>
        draw_line(g, line_at(points, weights, radius, i), out));
}

fn line_buffer(g: mask.Grid, work: u32) -> Lines {
    return Lines { coverage: buffer_fill(mask.size(g), 0.0), area: Box { x: 0, y: 0, w: 0, h: 0 },
        work: work, issue: "" };
}

fn finish_lines(g: mask.Grid, lines: Lines, id: i32, style: Fade, old: Paint) -> Paint {
    if lines.issue != "" { return Paint { ..old, issue: lines.issue }; }
    let area = lines.area;
    let work = lines.work + area.w * area.h;
    if work > 32000000 { return Paint { ..old, issue: "Drawing exceeds its raster work budget" }; }
    let coverage = lines.coverage.freeze();
    return repeat_until(area.h, Paint { ..old, drawing: work }, fn(out) => false, fn(v) => fn(out) =>
        repeat_until(area.w, out, fn(row) => false, fn(u) => fn(row) =>
            stroke_pixel(g, coverage, area.x + u, area.y + v, id, style, row)));
}

fn stroke_pixel(g: mask.Grid, coverage: List<f32>, x: u32, y: u32, id: i32, style: Fade, old: Paint) -> Paint {
    let p = y * g.width + x;
    if f64_from_f32(coverage.at_or(p, 0.0)) * tone(style, x, y) < 0.5f64 { return old; }
    return draw_slot(old, p, id);
}

fn path(g: mask.Grid, spec: List<json.Member>, id: i32, paint: Paint) -> Paint {
    if !values.only(spec, ["type", "space", "widthUnits", "width", "color", "falloff", "points", "closed", "weights"]) {
        return Paint { ..paint, issue: "Invalid path command" };
    }
    let thickness = width(spec);
    let width_error = width_issue(spec, thickness);
    if width_error != "" { return Paint { ..paint, issue: width_error }; }
    let closed = values.get(spec, "closed");
    if closed != json.null() && !json.as_boolean(closed).fold(fn(b) => true, fn(error) => false) {
        return Paint { ..paint, issue: "Path closed flag must be boolean" };
    }
    let points = values.items(values.get(spec, "points")).map(fn(p) => position(p));
    if length(points) < 2 || length(points) > 4096 { return Paint { ..paint, issue: "Path needs 2 to 4096 points" }; }
    if length(points.filter(fn(p) => !is_finite(p.x))) != 0 { return Paint { ..paint, issue: "Path needs a finite XY vector" }; }
    return draw_path(g, spec, points, thickness * 0.5f64, id, paint);
}

fn draw_path(g: mask.Grid, spec: List<json.Member>, points: List<Position>, radius: f64, id: i32, paint: Paint) -> Paint {
    let weights = values.items(values.get(spec, "weights")).map(fn(w) => values.number(w));
    if values.has(spec, "weights") && (length(weights) != length(points) ||
        length(weights.filter(fn(w) => !is_finite(w) || w < 0.0f64 || w > 16.0f64)) != 0) {
        return Paint { ..paint, issue: "Path weights need one multiplier in [0, 16] per point" };
    }
    let style = falloff(spec, "falloff", no_fade());
    if style.issue != "" { return Paint { ..paint, issue: style.issue }; }
    let lines = polyline(g, points, weights, radius, values.flag(spec, "closed", false), line_buffer(g, paint.drawing));
    return finish_lines(g, lines, id, style, paint);
}

fn draw_polygon(g: mask.Grid, rings: List<List<Position>>, id: i32, style: Fade, paint: Paint) -> Paint {
    let all = edges(rings);
    let first = all.at_or(0, Edge { start: style.origin, end: style.origin }).start;
    let bounds = foldl(all, Rect { x: first.x, y: first.y, right: first.x, bottom: first.y },
        fn(e) => fn(box) => point_bounds(box, e.start));
    let area = clipped(g, bounds);
    if area.w == 0 || area.h == 0 { return paint; }
    let work = paint.drawing + 2 * area.w * area.h + area.h * 4 * (length(all) + area.w);
    if work > 32000000 { return Paint { ..paint, issue: "Drawing exceeds its raster work budget" }; }
    let poly = Polygon { edges: all, area: area };
    return repeat_until(area.h, Paint { ..paint, drawing: work }, fn(out) => false, fn(y) => fn(out) =>
        polygon_row(g, poly, area.y + y, id, style, out));
}

fn style_polygon(g: mask.Grid, spec: List<json.Member>, rings: List<List<Position>>, id: i32,
    palette: u32, paint: Paint) -> Paint {
    let base = falloff(spec, "falloff", no_fade());
    let fill = falloff(spec, "fillFalloff", base);
    let stroke = falloff(spec, "strokeFalloff", base);
    let issue = if base.issue != "" { base.issue } else { if fill.issue != "" { fill.issue } else { stroke.issue } };
    if issue != "" { return Paint { ..paint, issue: issue }; }
    let background = values.get(spec, "fill");
    let outline = values.get(spec, "stroke");
    let has_fill = background != json.boolean(false);
    let has_outline = values.has(spec, "stroke") && outline != json.boolean(false);
    if !has_fill && !has_outline { return Paint { ..paint, issue: "Polygon needs a fill or stroke" }; }
    let tint = if background == json.null() || !has_fill { Ink { id: id, alpha: 1.0f64, issue: "" } }
        else { ink_color(background, id, palette) };
    if tint.issue != "" { return Paint { ..paint, issue: tint.issue }; }
    let inside = if has_fill { draw_polygon(g, rings, tint.id, Fade { ..fill, ink: tint.alpha }, paint) } else { paint };
    if !has_outline || inside.issue != "" { return inside; }
    return outline_polygon(g, rings, width(spec) * 0.5f64, ink_color(outline, id, palette), stroke, inside);
}

fn outline_polygon(g: mask.Grid, rings: List<List<Position>>, radius: f64, tint: Ink, stroke: Fade, inside: Paint) -> Paint {
    if tint.issue != "" { return Paint { ..inside, issue: tint.issue }; }
    let lines = foldl(rings, line_buffer(g, inside.drawing), fn(points) => fn(out) => polyline(g, points, [], radius, true, out));
    return finish_lines(g, lines, tint.id, Fade { ..stroke, ink: tint.alpha }, inside);
}

fn polygon(g: mask.Grid, spec: List<json.Member>, id: i32, palette: u32, paint: Paint) -> Paint {
    if !values.only(spec, ["type", "space", "widthUnits", "width", "color", "falloff", "points", "rings",
        "fill", "stroke", "fillFalloff", "strokeFalloff"]) {
        return Paint { ..paint, issue: "Invalid polygon command" };
    }
    let issue = width_issue(spec, width(spec));
    if issue != "" { return Paint { ..paint, issue: issue }; }
    return polygon_rings(spec).fold(fn(rings) => style_polygon(g, spec, rings, id, palette, paint),
        fn(error) => Paint { ..paint, issue: error });
}

fn shape(g: mask.Grid, raw: json.Json, id: i32, palette: u32, paint: Paint) -> Paint {
    let spec = values.fields(raw);
    let kind = values.text(values.get(spec, "type"));
    let space = json.lookup(spec, "space").fold(fn(v) => values.text(v), fn(unit) => "screen");
    if space != "screen" || !(kind == "rect" || kind == "polygon" || kind == "path") {
        return Paint { ..paint, issue: "Paint maps use pixel paths, polygons and rectangles" };
    }
    if kind == "polygon" { return polygon(g, spec, id, palette, paint); }
    if kind == "path" { return path(g, spec, id, paint); }
    if !values.only(spec, ["type", "rect", "color", "falloff"]) {
        return Paint { ..paint, issue: "Invalid rectangle command" };
    }
    let xywh = values.items(values.get(spec, "rect"));
    let x = values.number(xywh.at_or(0, json.null()));
    let y = values.number(xywh.at_or(1, json.null()));
    let w = values.number(xywh.at_or(2, json.null()));
    let h = values.number(xywh.at_or(3, json.null()));
    if length(xywh) != 4 || !is_finite(x) || !is_finite(y) || !is_finite(w) || !is_finite(h) || w <= 0.0f64 || h <= 0.0f64 ||
        x < -1000000000000.0f64 || y < -1000000000000.0f64 || x > 1000000000000.0f64 || y > 1000000000000.0f64 ||
        w > 1000000000000.0f64 || h > 1000000000000.0f64 {
        return Paint { ..paint, issue: "A rectangle needs finite XY and positive size" };
    }
    let style = falloff(spec, "falloff", no_fade());
    if style.issue != "" { return Paint { ..paint, issue: style.issue }; }
    return draw_rect(g, rect(x, y, w, h), id, style, paint);
}

fn in_signed(g: mask.Grid, x: i32, y: i32) -> Bool {
    return x >= 0 && y >= 0 && f64_from_i32(x) < f64_from_u32(g.width) && f64_from_i32(y) < f64_from_u32(g.height);
}

fn step_span(g: mask.Grid, path: Stroke, count: u32, id: i32) -> Stroke {
    let tip = path.tip;
    let n = i32_from_f64(f64_from_u32(count)).fold(fn(value) => value, fn(unit) => 0);
    let end_x = if tip.down { tip.x } else { tip.x + tip.dx * (n - 1) };
    let end_y = if tip.down { tip.y + tip.dy * (n - 1) } else { tip.y };
    if !in_signed(g, tip.x, tip.y) || !in_signed(g, end_x, end_y) {
        return Stroke { ..path, paint: Paint { ..path.paint, issue: "A pixel step stroke leaves the native grid" } };
    }
    let r = rect(values.min(f64_from_i32(tip.x), f64_from_i32(end_x)),
        values.min(f64_from_i32(tip.y), f64_from_i32(end_y)),
        if tip.down { 1.0f64 } else { f64_from_u32(count) },
        if tip.down { f64_from_u32(count) } else { 1.0f64 });
    return Stroke { paint: draw_rect(g, r, id, no_fade(), path.paint),
        tip: Step { ..tip, x: end_x + tip.dx, y: end_y + tip.dy } };
}

fn staircase(g: mask.Grid, raw: json.Json, id: i32, paint: Paint) -> Paint {
    if !json.members(raw).fold(fn(spec) => true, fn(error) => false) {
        return Paint { ..paint, issue: "A step stroke needs a start, axis, direction and run lengths" };
    }
    let spec = values.fields(raw);
    let from = point(g, values.get(spec, "from"));
    let axis = values.text(values.get(spec, "axis"));
    let direction = values.items(values.get(spec, "direction"));
    let dx = values.integer(direction.at_or(0, json.null()), -1, 1).fold(fn(n) => n, fn(unit) => 0);
    let dy = values.integer(direction.at_or(1, json.null()), -1, 1).fold(fn(n) => n, fn(unit) => 0);
    let lengths = values.items(values.get(spec, "lengths")).map(fn(n) => values.word(n, 512));
    if !inside(g, from) || !(axis == "x" || axis == "y") || length(direction) != 2 || dx == 0 || dy == 0 ||
        length(lengths) == 0 || length(lengths) > 512 || length(lengths.filter(fn(n) => n == 0 || n > 512)) != 0 {
        return Paint { ..paint, issue: "Invalid pixel step stroke" };
    }
    let start = Step { x: i32_from_f64(f64_from_u32(from.x)).fold(fn(n) => n, fn(unit) => 0),
        y: i32_from_f64(f64_from_u32(from.y)).fold(fn(n) => n, fn(unit) => 0), dx: dx, dy: dy, down: axis == "y" };
    let path = Stroke { paint: spend_marks(paint, length(lengths)), tip: start };
    return foldl(lengths, path, fn(count) => fn(out) =>
        if out.paint.issue == "" { step_span(g, out, count, id) } else { out }).paint;
}

fn mark(g: mask.Grid, ids: List<String>, raw: json.Json, paint: Paint) -> Paint {
    let spec = values.fields(raw);
    let swatch = values.get(spec, "swatch");
    let id: i32 = if values.has(spec, "swatch") { slot(ids, swatch) } else { -3 };
    if values.has(spec, "runs") { return run_mark(g, spec, id, paint); }
    let fields = spec.filter(fn(v) => v.key == "at" || v.key == "shape" || v.key == "steps");
    if length(fields) != 1 || !values.only(spec, ["at", "shape", "steps", "swatch"]) {
        return Paint { ..paint, issue: "A pixel mark needs exactly one of at, shape, or steps" };
    }
    let op = fields.at_or(0, json.Member { key: "", value: json.null() });
    let p = point(g, op.value);
    if op.key == "at" && !inside(g, p) { return Paint { ..paint, issue: "A pixel mark is outside the native grid" }; }
    if id == -3 { return Paint { ..paint, issue: unknown_swatch(swatch) }; }
    let work = if op.key == "steps" { paint } else { spend_marks(paint, 1) };
    if work.issue != "" { return work; }
    let out = if op.key == "steps" { staircase(g, op.value, id, work) } else {
        if op.key == "shape" { shape(g, op.value, id, length(ids), work) }
        else { draw_rect(g, rect(f64_from_u32(p.x), f64_from_u32(p.y), 1.0f64, 1.0f64), id, no_fade(), work) }
    };
    if out.issue == "" && id == -2 && out.alpha.len() != 0 {
        let charged = spend_runs(Paint { ..out, drawing: 0 }, mask.size(g));
        return repeat_until(mask.size(g), charged, fn(next) => next.issue != "", fn(i) => fn(next) =>
            reset_erased_alpha(next, i));
    }
    return out;
}

fn no_run_cache() -> RunCache { return RunCache { prefix: [], tail: [] }; }

fn append_runs(content: List<json.Member>, cache: RunCache, added: List<RunMark>) -> RunCache {
    let prefix = if length(cache.tail) == 0 { values.items(values.get(content, "marks")) } else { cache.prefix };
    return RunCache { prefix: prefix, tail: cache.tail.concat(added) };
}

fn retained_runs(g: mask.Grid, row: RunMark, old: Paint) -> Paint {
    if old.issue != "" { return old; }
    let alpha = row.alpha.fold(fn(n) => n, fn(unit) => 4294967295);
    let prepared = spend_marks(Paint { ..old, drawing: 0 }, 1);
    let initial = if alpha <= 255 && prepared.alpha.len() == 0 {
        Paint { ..prepared, alpha: buffer_fill(mask.size(g), 255) }
    } else { prepared };
    return foldl(row.spans, initial, fn(span) => fn(out) =>
        retained_span(g, span, row.slot, alpha, out));
}

fn retained_span(g: mask.Grid, span: Vec3<u32>, slot: i32, alpha: u32, old: Paint) -> Paint {
    if old.issue != "" { return old; }
    let charged = spend_runs(old, span.z);
    if charged.issue != "" { return charged; }
    let first = span.x * g.width + span.y;
    if alpha <= 255 {
        return repeat_until(span.z, charged, fn(out) => false, fn(i) => fn(out) => write_alpha(out, first + i, alpha));
    }
    return write_span(charged, Span { start: first, length: span.z }, slot);
}

fn raster(g: mask.Grid, ids: List<String>, content: List<json.Member>, cache: RunCache, work: Work) -> Raw {
    let base = initial(g, ids, content, work);
    let marks = if length(cache.tail) == 0 { values.items(values.get(content, "marks")) } else { cache.prefix };
    let authored = foldl(marks, base, fn(row) => fn(out) =>
        if out.issue == "" { mark(g, ids, row, out) } else { out });
    let drawn = foldl(cache.tail, authored, fn(row) => fn(out) => retained_runs(g, row, out));
    return Raw { slots: drawn.slots.freeze(), alpha: drawn.alpha.freeze(), work: drawn.work, issue: drawn.issue };
}
