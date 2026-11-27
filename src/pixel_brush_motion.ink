module StudioPixelBrushMotion;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_drawing_grid.ink" as grid;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;

record Sample { at: brush.Pair, pressure: f64, time: f64, }
record Stroke { ready: Bool, previous: Sample, position: brush.Pair, anchor: grid.Point, scale: f64,
    last: grid.Point, tip: brush.Tip, cached: List<brush.Tip>, marks: brush.Marks, }
record Segment { pen: grid.Pen, stroke: Stroke, }

fn bounds(axis: grid.Axis) -> brush.Pair {
    let lo: i32 = if axis.wrap { -axis.size } else { 0 };
    let hi: i32 = if axis.wrap { 2 * axis.size - 1 } else { axis.size - 1 };
    return brush.Pair { x: f64_from_i32(lo), y: f64_from_i32(hi) };
}

fn inside(n: f64, axis: grid.Axis) -> Bool {
    let range = bounds(axis);
    return brush.finite_between(n, range.x - 0.5f64, range.y + 0.5f64);
}

fn quantize(n: f64, axis: grid.Axis) -> i32 {
    let range = bounds(axis);
    let floor = floor(n);
    let i = if n - floor >= 0.5f64 { floor + 1.0f64 } else { floor };
    return brush.integer(value.max(range.x, value.min(range.y, i)));
}

fn sample(d: grid.Drawing, raw: json.Json, previous: f64) -> Result<Sample, String> {
    let items = value.fields(raw);
    let at = brush.fpair(value.get(items, "at"));
    let pressure = value.number(value.get(items, "pressure"));
    let time = value.number(value.get(items, "time"));
    if !value.only(items, ["at", "pressure", "time"]) || !inside(at.x, d.x) || !inside(at.y, d.y) ||
        !brush.finite_between(pressure, 0.0f64, 1.0f64) || !brush.finite_between(time, previous, 9007199254740991.0f64) {
        return Err("Brush samples need in-grid positions, pressure in 0–1 and ordered elapsed milliseconds (up to 4096 samples)");
    }
    return Ok(Sample { at: at, pressure: pressure, time: time });
}

fn mix(lo: f64, hi: f64, t: f64) -> f64 { return lo + (hi - lo) * t; }

fn distance(a: brush.Pair, b: brush.Pair) -> f64 {
    let dx = a.x - b.x;
    let dy = a.y - b.y;
    let scale = value.max(mask.abs(dx), mask.abs(dy));
    if scale == 0.0f64 { return 0.0f64; }
    let x = dx / scale;
    let y = dy / scale;
    return sqrt(x * x + y * y) * scale;
}

fn follow(elapsed: f64, stabilize: f64) -> f64 {
    let n = elapsed / stabilize;
    if n > 37.0f64 { return 1.0f64; }
    let x = -n / 64.0f64;
    let series = repeat(16, 1.0f64, fn(i) => fn(tail) => 1.0f64 + x * tail / f64_from_u32(17 - i));
    // expm1(2x) = expm1(x) * (2 + expm1(x)), stable for short time steps.
    return -repeat(6, x * series, fn(i) => fn(m) => m * (2.0f64 + m));
}

fn new_scale(b: brush.Brush, next: Sample, previous: Sample, ready: Bool) -> f64 {
    let settings = b.settings.dynamics;
    let travel = if ready { distance(next.at, previous.at) } else { 0.0f64 };
    let elapsed = next.time - previous.time;
    let t = if travel == 0.0f64 || settings.speed == 0.0f64 { 0.0f64 }
        else { if elapsed == 0.0f64 { 1.0f64 } else { value.min(1.0f64, (travel * 1000.0f64 / elapsed) / settings.speed) } };
    let velocity = mix(settings.velocity.x, settings.velocity.y, t);
    return mix(settings.pressure.x, settings.pressure.y, next.pressure) * velocity;
}

fn start(d: grid.Drawing, b: brush.Brush) -> Stroke {
    let zero = brush.Pair { x: 0.0f64, y: 0.0f64 };
    let dummy = brush.tip(b, b.settings.size);
    return Stroke { ready: false, previous: Sample { at: zero, pressure: 0.0f64, time: 0.0f64 }, position: zero,
        anchor: grid.absent(), scale: 1.0f64, last: grid.absent(), tip: brush.Tip { ..dummy, size: vec2(0, 0) },
        cached: [], marks: brush.start(d) };
}

fn add(d: grid.Drawing, b: brush.Brush, next: Sample, old: Stroke) -> Stroke {
    let rate = b.settings.dynamics.stabilize;
    let f = if rate != 0.0f64 && old.ready { follow(next.time - old.previous.time, rate) } else { 1.0f64 };
    let p = if !old.ready { next.at } else {
        brush.Pair { x: mix(old.position.x, next.at.x, f), y: mix(old.position.y, next.at.y, f) }
    };
    let scale = new_scale(b, next, old.previous, old.ready);
    let advanced = extend(d, b, p, scale, old);
    return Stroke { ..advanced, previous: next, position: p, ready: true };
}

fn extend(d: grid.Drawing, b: brush.Brush, next: brush.Pair, scale: f64, old: Stroke) -> Stroke {
    let p = grid.Point { x: quantize(next.x, d.x), y: quantize(next.y, d.y) };
    let steps: u32 = if old.ready { grid.steps(old.anchor, p) } else { 0 };
    let painted = if steps == 0 { dab(d, b, p, scale, old) }
        else { segment(d, b, p, scale, steps, old) };
    return Stroke { ..painted, anchor: p, scale: scale };
}

fn segment(d: grid.Drawing, b: brush.Brush, p: grid.Point, scale: f64, steps: u32, old: Stroke) -> Stroke {
    let start_scale = old.scale;
    let init = Segment { pen: grid.segment(old.anchor, p), stroke: old };
    return repeat_until(steps, init, fn(out) => out.stroke.marks.issue != "", fn(i) => fn(out) =>
        step(d, b, mix(start_scale, scale, f64_from_u32(i + 1) / f64_from_u32(steps)), out)).stroke;
}

fn step(d: grid.Drawing, b: brush.Brush, scale: f64, old: Segment) -> Segment {
    let pen = grid.advance(old.pen);
    return Segment { pen: pen, stroke: dab(d, b, pen.position, scale, old.stroke) };
}

fn fit(n: u32, scale: f64) -> u32 {
    return value.round_byte(value.max(1.0f64, value.min(512.0f64, f64_from_u32(n) * scale)));
}

fn equal(a: Vec2<u32>, b: Vec2<u32>) -> Bool { return a.x == b.x && a.y == b.y; }

fn find(cached: List<brush.Tip>, size: Vec2<u32>, fallback: brush.Tip) -> brush.Tip {
    return repeat_until(length(cached), fallback, fn(out) => equal(out.size, size),
        fn(i) => fn(out) => cache_match(cached.at_or(i, fallback), size, out));
}

fn cache_match(row: brush.Tip, size: Vec2<u32>, old: brush.Tip) -> brush.Tip {
    return if equal(row.size, size) { row } else { old };
}

fn reshape(b: brush.Brush, size: Vec2<u32>, old: Stroke) -> Stroke {
    let reused = find(old.cached, size, old.tip);
    if equal(reused.size, size) { return Stroke { ..old, tip: reused }; }
    let geometry = brush.tip(b, size);
    let paid = brush.charge(brush.area(geometry.bounds), old.marks);
    if paid.issue != "" { return Stroke { ..old, marks: paid }; }
    let raster = brush.raster_tip(b, geometry);
    let cached = if length(raster.cells) <= 4096 && length(old.cached) < 16 { old.cached.concat([raster]) } else { old.cached };
    return Stroke { ..old, cached: cached, tip: raster, marks: paid };
}

fn dab(d: grid.Drawing, b: brush.Brush, p: grid.Point, scale: f64, old: Stroke) -> Stroke {
    let size: Vec2<u32> = vec2(fit(b.settings.size.x, scale), fit(b.settings.size.y, scale));
    let matching = equal(size, old.tip.size);
    if matching && p.x == old.last.x && p.y == old.last.y { return old; }
    let ready = if matching { old } else { reshape(b, size, old) };
    if ready.marks.issue != "" { return ready; }
    let paid = brush.charge(length(ready.tip.cells) + 1, ready.marks);
    let painted = if paid.issue == "" { brush.place(d, ready.tip.cells, p, paid) } else { paid };
    return Stroke { ..ready, last: p, marks: painted };
}

fn next(d: grid.Drawing, b: brush.Brush, raw: json.Json, old: Stroke) -> Stroke {
    return sample(d, raw, old.previous.time).fold(fn(row) => add(d, b, row, old),
        fn(issue) => Stroke { ..old, marks: brush.Marks { ..old.marks, issue: issue } });
}

fn trace(d: grid.Drawing, b: brush.Brush, raw: json.Json) -> Result<List<brush.Stamp>, String> {
    let samples = value.items(raw);
    if length(samples) == 0 || length(samples) > 4096 { return Err("A dynamic brush stroke needs 1–4096 samples"); }
    let traced = repeat_until(length(samples), start(d, b), fn(out) => out.marks.issue != "", fn(i) => fn(out) =>
        next(d, b, samples.at_or(i, json.null()), out));
    if traced.marks.issue != "" { return Err(traced.marks.issue); }
    let finished = extend(d, b, traced.previous.at, traced.scale, traced);
    return brush.freeze_marks(finished.marks);
}

