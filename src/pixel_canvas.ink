module StudioPixelCanvas;

import "std:json" as json;
import "pixel_drawing_grid.ink" as drawing;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_values.ink" as value;

record Canvas { before: mask.Grid, grid: mask.Grid, offset: Vec2<i32>, sx: f64, sy: f64, filter: String, index: List<i32>, }
record Bounds { left: u32, top: u32, right: u32, bottom: u32, visible: Bool, }
record Weights { index: u32, mass: f64, }
record Weight { opacity: f64, area: f64, }
record Mix { weights: Map<i32, Weight>, paint: f64, knockout: f64, opacity: f64, }
record Choice { slot: i32, weight: Weight, }
record Pixel { slot: i32, alpha: u32, }
record Sampling { canvas: Canvas, x: List<List<Weights>>, y: List<List<Weights>>, }
record Raster { slots: List<i32>, alpha: List<u32>, }

fn dim_error() -> String { return "Canvas dimensions must be whole pixels from 1 to 512"; }

fn empty_bounds(g: mask.Grid) -> Bounds {
    return Bounds { left: g.width, top: g.height, right: 0, bottom: 0, visible: false };
}

fn include(b: Bounds, x: u32, y: u32) -> Bounds {
    return Bounds { left: mask.min(b.left, x), top: mask.min(b.top, y), right: max_word(b.right, x),
        bottom: max_word(b.bottom, y), visible: true };
}

fn max_word(x: u32, y: u32) -> u32 { return if x > y { x } else { y }; }

fn members(raw: json.Json) -> Result<List<json.Member>, String> {
    return json.members(raw).map_err(fn(error) => "A canvas edit applies to the whole document");
}

fn keys(kind: String) -> List<String> {
    if kind == "crop" { return ["type", "rect"]; }
    if kind == "trim" { return ["type"]; }
    if kind == "pad" { return ["type", "margins"]; }
    if kind == "resize" { return ["type", "size", "anchor"]; }
    if kind == "resample" { return ["type", "size", "filter"]; }
    return [];
}

fn plan(before: mask.Grid, op: List<json.Member>, bounds: Bounds) -> Result<Canvas, String> {
    let kind = value.text(value.get(op, "type"));
    let fields = keys(kind);
    if length(fields) == 0 || !value.only(op, fields) {
        return Err("Choose a crop, trim, pad, resize, or resample canvas operation");
    }
    if kind == "trim" {
        return Ok(if bounds.visible { whole(before, bounds.right - bounds.left + 1, bounds.bottom - bounds.top + 1,
            drawing.signed(bounds.left), drawing.signed(bounds.top)) } else { whole(before, before.width, before.height, 0, 0) });
    }
    if kind == "crop" { return crop(before, value.items(value.get(op, "rect"))); }
    if kind == "pad" { return pad(before, value.items(value.get(op, "margins"))); }
    return sized(before, op, kind);
}

fn crop(before: mask.Grid, r: List<json.Json>) -> Result<Canvas, String> {
    let issue = "Crop needs an in-bounds [x,y,width,height] rectangle";
    if length(r) != 4 { return Err(issue); }
    let x = read_word(r, 0, before.width - 1);
    let y = read_word(r, 1, before.height - 1);
    if x >= before.width || y >= before.height { return Err(issue); }
    let w = read_word(r, 2, before.width - x);
    let h = read_word(r, 3, before.height - y);
    if w == 0 || h == 0 || w > before.width - x || h > before.height - y { return Err(issue); }
    return Ok(whole(before, w, h, drawing.signed(x), drawing.signed(y)));
}

fn read_word(values: List<json.Json>, i: u32, max: u32) -> u32 {
    return value.word(values.at_or(i, json.null()), max);
}

fn pad(before: mask.Grid, r: List<json.Json>) -> Result<Canvas, String> {
    let margins = r.map(fn(raw) => value.word(raw, 511));
    if length(margins) != 4 || length(margins.filter(fn(n) => n > 511)) != 0 {
        return Err("Padding needs nonnegative whole [left,top,right,bottom] margins");
    }
    let left = margins.at_or(0, 0);
    let top = margins.at_or(1, 0);
    let w = before.width + left + margins.at_or(2, 0);
    let h = before.height + top + margins.at_or(3, 0);
    if w > 512 || h > 512 { return Err(dim_error()); }
    return Ok(whole(before, w, h, 0 - drawing.signed(left), 0 - drawing.signed(top)));
}

fn anchor(name: String) -> Result<Vec2<u32>, String> {
    if name == "top-left" { return Ok(vec2(0, 0)); }
    if name == "top" { return Ok(vec2(1, 0)); }
    if name == "top-right" { return Ok(vec2(2, 0)); }
    if name == "left" { return Ok(vec2(0, 1)); }
    if name == "center" { return Ok(vec2(1, 1)); }
    if name == "right" { return Ok(vec2(2, 1)); }
    if name == "bottom-left" { return Ok(vec2(0, 2)); }
    if name == "bottom" { return Ok(vec2(1, 2)); }
    if name == "bottom-right" { return Ok(vec2(2, 2)); }
    return Err("Choose a canvas resize anchor");
}

fn anchor_offset(old: u32, next: u32, amount: u32) -> i32 {
    return i32_from_f64(ceil((f64_from_u32(old) - f64_from_u32(next)) * f64_from_u32(amount) * 0.5f64))
        .fold(fn(n) => n, fn(unit) => 0);
}

fn sized(before: mask.Grid, op: List<json.Member>, kind: String) -> Result<Canvas, String> {
    let size = value.items(value.get(op, "size"));
    let w = read_word(size, 0, 512);
    let h = read_word(size, 1, 512);
    if length(size) != 2 || w < 1 || w > 512 || h < 1 || h > 512 { return Err(dim_error()); }
    if kind == "resize" {
        let at = anchor(json.lookup(op, "anchor").fold(fn(n) => value.text(n), fn(unit) => "top-left"))?;
        return Ok(whole(before, w, h, anchor_offset(before.width, w, at.x), anchor_offset(before.height, h, at.y)));
    }
    let requested = value.get(op, "filter");
    let filter = if requested == json.null() { "nearest" } else { value.text(requested) };
    if filter != "nearest" && filter != "area" { return Err("Choose nearest or area resampling"); }
    let grid = mask.Grid { width: w, height: h };
    return Ok(indexed(Canvas { before: before, grid: grid, offset: vec2(0, 0), sx: ratio(before.width, w),
        sy: ratio(before.height, h), filter: filter, index: [] }));
}

fn ratio(old: u32, next: u32) -> f64 { return f64_from_u32(old) / f64_from_u32(next); }

fn whole(before: mask.Grid, w: u32, h: u32, x: i32, y: i32) -> Canvas {
    return indexed(Canvas { before: before, grid: mask.Grid { width: w, height: h }, offset: vec2(x, y),
        sx: 1.0f64, sy: 1.0f64, filter: "nearest", index: [] });
}

fn indexed(map: Canvas) -> Canvas {
    if !changed(map) { return map; }
    let start: Buffer<i32> = Buffer.empty();
    let sites = repeat_until(mask.size(map.grid), start, fn(out) => false,
        fn(p) => fn(out) => out.push(locate(map, p)));
    return Canvas { ..map, index: sites.freeze() };
}

fn locate(map: Canvas, p: u32) -> i32 {
    let x = f64_from_i32(map.offset.x) + (f64_from_u32(rem_or(p, map.grid.width, 0)) + 0.5f64) * map.sx;
    let y = f64_from_i32(map.offset.y) + (f64_from_u32(quot_or(p, map.grid.width, 0)) + 0.5f64) * map.sy;
    if x < 0.0f64 || y < 0.0f64 || x >= f64_from_u32(map.before.width) || y >= f64_from_u32(map.before.height) { return -1; }
    return drawing.signed(value.as_word(floor(y)) * map.before.width + value.as_word(floor(x)));
}

fn changed(map: Canvas) -> Bool { return map.before != map.grid || map.offset.x != 0 || map.offset.y != 0; }

fn band(old: u32, next: u32, target: u32) -> List<Weights> {
    let a = f64_from_u32(target * old) / f64_from_u32(next);
    let b = f64_from_u32((target + 1) * old) / f64_from_u32(next);
    let first = value.as_word(floor(a));
    let last = mask.min(old, value.as_word(ceil(b)));
    let start: Buffer<Weights> = Buffer.empty();
    return repeat_until(last - first, start, fn(out) => false, fn(i) => fn(out) =>
        add_weight(out, first + i, a, b)).freeze();
}

fn add_weight(out: Buffer<Weights>, i: u32, a: f64, b: f64) -> Buffer<Weights> {
    let p = f64_from_u32(i);
    return out.push(Weights { index: i, mass: value.min(b, p + 1.0f64) - value.max(a, p) });
}

fn axis_weights(old: u32, next: u32) -> List<List<Weights>> {
    let start: Buffer<List<Weights>> = Buffer.empty();
    return repeat_until(next, start, fn(out) => false, fn(i) => fn(out) => out.push(band(old, next, i))).freeze();
}

fn sampling(map: Canvas) -> Sampling {
    if map.filter != "area" || map.before == map.grid { return Sampling { canvas: map, x: [], y: [] }; }
    return Sampling { canvas: map, x: axis_weights(map.before.width, map.grid.width),
        y: axis_weights(map.before.height, map.grid.height) };
}

fn vacant() -> Pixel { return Pixel { slot: -1, alpha: 255 }; }

fn nearest(raw: frame.Captured, p: i32) -> Pixel {
    if p < 0 { return vacant(); }
    let i = drawing.unsigned(p);
    let slot = raw.slots.at_or(i, -1);
    return Pixel { slot: slot, alpha: if slot < 0 { 255 } else { raw.alpha.at_or(i, 255) } };
}

fn canvas_pixel(plan: Sampling, raw: frame.Captured, keep: List<i32>, p: u32) -> Pixel {
    let protected = keep.at_or(p, -1);
    if protected >= 0 { return nearest(raw, protected); }
    if length(plan.x) == 0 { return nearest(raw, plan.canvas.index.at_or(p, -1)); }
    let x = rem_or(p, plan.canvas.grid.width, 0);
    let y = quot_or(p, plan.canvas.grid.width, 0);
    let initial = Mix { weights: Map.empty(), paint: 0.0f64, knockout: 0.0f64, opacity: 0.0f64 };
    let horizontal = plan.x.at_or(x, []);
    let mixed = foldl(plan.y.at_or(y, []), initial, fn(row) => fn(out) =>
        foldl(horizontal, out, fn(column) => fn(current) => add_sample(raw, plan.canvas.before.width, column, row, current)));
    return mixed_pixel(mixed, plan.canvas.sx * plan.canvas.sy);
}

fn add_sample(raw: frame.Captured, width: u32, x: Weights, y: Weights, mix: Mix) -> Mix {
    let sample = y.index * width + x.index;
    let slot = raw.slots.at_or(sample, -1);
    let mass = x.mass * y.mass;
    if slot == -2 { return Mix { ..mix, knockout: mix.knockout + mass }; }
    if slot < 0 { return mix; }
    let amount = mass * f64_from_u32(raw.alpha.at_or(sample, 255));
    let old = mix.weights.get_or(slot, Weight { opacity: 0.0f64, area: 0.0f64 });
    let next = Weight { opacity: old.opacity + amount, area: old.area + mass };
    return Mix { ..mix, weights: mix.weights.set(slot, next), paint: mix.paint + mass, opacity: mix.opacity + amount };
}

fn preferred(current: Choice, slot: i32, weight: Weight) -> Choice {
    let old = current.weight;
    let wins_tie = (weight.opacity != 0.0f64 || weight.area == old.area) && slot < current.slot ||
        weight.opacity == 0.0f64 && weight.area > old.area;
    return if current.slot < 0 || weight.opacity > old.opacity || weight.opacity == old.opacity && wins_tie {
        Choice { slot: slot, weight: weight }
    } else { current };
}

fn mixed_pixel(mix: Mix, area: f64) -> Pixel {
    if mix.knockout > mix.paint { return Pixel { slot: -2, alpha: 255 }; }
    let initial = Choice { slot: -1, weight: Weight { opacity: 0.0f64, area: 0.0f64 } };
    let best = foldl(mix.weights.keys(), initial, fn(slot) => fn(current) =>
        preferred(current, slot, mix.weights.get_or(slot, Weight { opacity: 0.0f64, area: 0.0f64 })));
    if best.slot < 0 { return vacant(); }
    return Pixel { slot: best.slot, alpha: mask.min(255, value.round_byte(mix.opacity / area)) };
}

fn raster(plan: Sampling, raw: frame.Captured, keep: List<i32>) -> Raster {
    let initial: Buffer<Pixel> = Buffer.empty();
    let rows = repeat_until(mask.size(plan.canvas.grid), initial, fn(out) => false,
        fn(p) => fn(out) => out.push(canvas_pixel(plan, raw, keep, p))).freeze();
    return Raster { slots: rows.map(fn(row) => row.slot), alpha: rows.map(fn(row) => row.alpha) };
}
