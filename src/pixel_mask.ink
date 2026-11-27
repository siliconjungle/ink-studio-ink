module StudioPixelMask;

record Grid { width: u32, height: u32, }
record Rect { x: u32, y: u32, w: u32, h: u32, }
record Position { x: f64, y: f64, }
record Edge { a: Position, b: Position, }
record Pen { x: f64, y: f64, error: f64, mask: Buffer<u32>, }
record Stroke { end: Position, dx: f64, dy: f64, sx: f64, sy: f64, }
record Flood { mask: Buffer<u32>, queue: Buffer<u32>, cursor: u32, }
record Region { grid: Grid, source: List<u32>, keyed: Bool, target: u32, tolerance: u32, }

fn size(g: Grid) -> u32 { return g.width * g.height; }
fn blank(g: Grid) -> Buffer<u32> { return buffer_fill(size(g), 0); }
fn index(g: Grid, p: Vec2<u32>) -> u32 { return p.y * g.width + p.x; }
fn exact(x: f64) -> u32 { return u32_from_f64(x).fold(fn(n) => n, fn(unit) => 0); }
fn min(a: u32, b: u32) -> u32 { return if a < b { a } else { b }; }
fn abs(a: f64) -> f64 { return if a < 0.0f64 { -a } else { a }; }
fn sign(a: f64) -> f64 { return if a < 0.0f64 { -1.0f64 } else { if a > 0.0f64 { 1.0f64 } else { 0.0f64 } }; }

fn marquee(g: Grid, box: Rect, oval: Bool) -> List<u32> {
    return repeat_until(box.h, blank(g), fn(mask) => false, fn(y) => fn(mask) =>
        marquee_row(g, box, y, oval, mask)).freeze();
}

fn marquee_row(g: Grid, box: Rect, y: u32, oval: Bool, mask: Buffer<u32>) -> Buffer<u32> {
    let start = (box.y + y) * g.width + box.x;
    if !oval {
        return repeat_until(box.w, mask, fn(old) => false, fn(x) => fn(old) => old.set(start + x, 1));
    }
    let h = f64_from_u32(box.h);
    let w = f64_from_u32(box.w);
    let row = (2.0f64 * (f64_from_u32(y) + 0.5f64) - h) / h;
    let row_squared = row * row;
    return repeat_until(box.w, mask, fn(old) => false, fn(x) => fn(old) =>
        ellipse_cell(start, x, w, row_squared, old));
}

fn ellipse_cell(start: u32, x: u32, w: f64, row_squared: f64, mask: Buffer<u32>) -> Buffer<u32> {
    let col = (2.0f64 * (f64_from_u32(x) + 0.5f64) - w) / w;
    return if col * col + row_squared <= 1.0f64 { mask.set(start + x, 1) } else { mask };
}

fn edge(points: List<Vec2<u32>>, a: Vec2<u32>, at: u32) -> Edge {
    let b = points.at_or(rem_or(at + 1, length(points), 0), a);
    return Edge { a: Position { x: f64_from_u32(a.x), y: f64_from_u32(a.y) },
        b: Position { x: f64_from_u32(b.x), y: f64_from_u32(b.y) } };
}

fn step_pen(g: Grid, stroke: Stroke, pen: Pen) -> Pen {
    let twice = pen.error * 2.0f64;
    let dx = twice >= stroke.dy;
    let dy = twice <= stroke.dx;
    let x = pen.x + (if dx { stroke.sx } else { 0.0f64 });
    let y = pen.y + (if dy { stroke.sy } else { 0.0f64 });
    let error = pen.error + (if dx { stroke.dy } else { 0.0f64 }) + (if dy { stroke.dx } else { 0.0f64 });
    return Pen { x: x, y: y, error: error, mask: pen.mask.set(exact(y) * g.width + exact(x), 1) };
}

fn trace(g: Grid, mask: Buffer<u32>, e: Edge) -> Buffer<u32> {
    let x = e.b.x - e.a.x;
    let y = e.b.y - e.a.y;
    let stroke = Stroke { end: e.b, dx: abs(x), dy: -abs(y), sx: sign(x), sy: sign(y) };
    let start = Pen { x: e.a.x, y: e.a.y, error: stroke.dx + stroke.dy,
        mask: mask.set(exact(e.a.y) * g.width + exact(e.a.x), 1) };
    let span = if stroke.dx >= -stroke.dy { stroke.dx } else { -stroke.dy };
    return repeat_until(exact(span), start, fn(pen) => pen.x == stroke.end.x && pen.y == stroke.end.y,
        fn(i) => fn(pen) => step_pen(g, stroke, pen)).mask;
}

fn crossing(row: f64, e: Edge, list: Buffer<u32>) -> Buffer<u32> {
    let low = if e.a.y < e.b.y { e.a } else { e.b };
    let high = if e.a.y < e.b.y { e.b } else { e.a };
    if row < low.y || row >= high.y { return list; }
    let x = low.x + (row - low.y) * (high.x - low.x) / (high.y - low.y);
    // Values in the same half-open pixel interval have the same span endpoints.
    // The low bit keeps exact integers before fractional crossings in that cell.
    let whole = floor(x);
    return list.push(exact(whole) * 2 + (if x > whole { 1 } else { 0 }));
}

fn span(row: u32, width: u32, crossings: List<u32>, i: u32, mask: Buffer<u32>) -> Buffer<u32> {
    let left = crossings.at_or(i * 2, 0);
    let start = wrapping_shr(left + 1, 1);
    let stop = wrapping_shr(crossings.at_or(i * 2 + 1, 0), 1);
    if stop < start { return mask; }
    return repeat_until(stop - start + 1, mask, fn(old) => false,
        fn(x) => fn(old) => old.set(row * width + start + x, 1));
}

fn fill_row(g: Grid, row: u32, edges: List<Edge>, mask: Buffer<u32>) -> Buffer<u32> {
    let blank: Buffer<u32> = Buffer.empty();
    let y = f64_from_u32(row);
    let xs = foldl(edges, blank, fn(e) => fn(list) => crossing(y, e, list)).freeze().sort();
    return repeat_until(quot_or(length(xs), 2, 0), mask, fn(old) => false,
        fn(i) => fn(old) => span(row, g.width, xs, i, old));
}

fn lasso(g: Grid, points: List<Vec2<u32>>) -> List<u32> {
    let edges = points.map_indexed(fn(i) => fn(a) => edge(points, a, i));
    let outline = foldl(edges, blank(g), fn(e) => fn(mask) => trace(g, mask, e));
    let low = foldl(points, g.height, fn(p) => fn(y) => min(y, p.y));
    let zero: u32 = 0;
    let high = foldl(points, zero, fn(p) => fn(y) => if y < p.y { p.y } else { y });
    return repeat_until(high - low, outline, fn(mask) => false,
        fn(row) => fn(mask) => fill_row(g, low + row, edges, mask)).freeze();
}

fn difference(a: u32, b: u32) -> u32 { return if a > b { a - b } else { b - a }; }

fn color_matches(value: u32, seed: u32, tolerance: u32) -> Bool {
    let alpha = word_and(value, 255);
    let base = word_and(seed, 255);
    if alpha == 0 || base == 0 { return alpha == base; }
    if tolerance == 0 { return value == seed; }
    return difference(alpha, base) <= tolerance &&
        difference(wrapping_shr(value, 24), wrapping_shr(seed, 24)) <= tolerance &&
        difference(word_and(wrapping_shr(value, 16), 255), word_and(wrapping_shr(seed, 16), 255)) <= tolerance &&
        difference(word_and(wrapping_shr(value, 8), 255), word_and(wrapping_shr(seed, 8), 255)) <= tolerance;
}

fn matches(region: Region, slot: u32) -> Bool {
    let value = region.source.at_or(slot, 0);
    return if region.keyed { color_matches(value, region.target, region.tolerance) } else { value != 0 };
}

fn enqueue(region: Region, old: Flood, slot: u32, valid: Bool) -> Flood {
    if !valid || old.mask.at_or(slot, 0) != 0 || !matches(region, slot) { return old; }
    return Flood { ..old, mask: old.mask.set(slot, 1), queue: old.queue.push(slot) };
}

fn flood_step(region: Region, diagonal: Bool, old: Flood) -> Flood {
    let p = old.queue.at_or(old.cursor, 0);
    let g = region.grid;
    let x = rem_or(p, g.width, 0);
    let y = quot_or(p, g.width, 0);
    let left = x > 0;
    let right = x + 1 < g.width;
    let top = y > 0;
    let bottom = y + 1 < g.height;
    let a = enqueue(region, old, p + 1, right);
    let b = enqueue(region, a, p - 1, left);
    let c = enqueue(region, b, p + g.width, bottom);
    let d = enqueue(region, c, p - g.width, top);
    let advanced = Flood { ..d, cursor: d.cursor + 1 };
    if !diagonal { return advanced; }
    let e = enqueue(region, advanced, p + g.width + 1, bottom && right);
    let f = enqueue(region, e, p + g.width - 1, bottom && left);
    let h = enqueue(region, f, p - g.width + 1, top && right);
    return enqueue(region, h, p - g.width - 1, top && left);
}

fn flood(region: Region, seed: u32, diagonal: Bool) -> List<u32> {
    let mask = blank(region.grid);
    if !matches(region, seed) { return mask.freeze(); }
    let start = Flood { mask: mask.set(seed, 1), queue: buffer([seed]), cursor: 0 };
    return repeat_until(size(region.grid), start, fn(old) => old.cursor >= old.queue.len(),
        fn(i) => fn(old) => flood_step(region, diagonal, old)).mask.freeze();
}

fn wand(g: Grid, source: List<u32>, p: Vec2<u32>, tolerance: u32, connected: Bool) -> List<u32> {
    let seed = index(g, p);
    let target = source.at_or(seed, 0);
    if !connected { return source.map(fn(value) => if color_matches(value, target, tolerance) { 1 } else { 0 }); }
    return flood(Region { grid: g, source: source, keyed: true, target: target, tolerance: tolerance }, seed, false);
}

fn cluster(g: Grid, source: List<u32>, p: Vec2<u32>, diagonal: Bool) -> List<u32> {
    return flood(Region { grid: g, source: source, keyed: false, target: 0, tolerance: 0 }, index(g, p), diagonal);
}

fn distances(g: Grid, mask: List<u32>, inward: Bool) -> List<u32> {
    let d = repeat_until(size(g), blank(g), fn(old) => false,
        fn(p) => fn(old) => distance_forward(g, mask, inward, p, old));
    return repeat_until(size(g), d, fn(old) => false, fn(i) => fn(old) =>
        distance_reverse(g, size(g) - 1 - i, old)).freeze();
}

fn distance_forward(g: Grid, mask: List<u32>, inward: Bool, p: u32, d: Buffer<u32>) -> Buffer<u32> {
    let x = rem_or(p, g.width, 0);
    let y = quot_or(p, g.width, 0);
    let on = mask.at_or(p, 0) != 0;
    let limit = if inward { min(min(x + 1, y + 1), min(g.width - x, g.height - y)) } else { 65535 };
    let base = if on == inward { limit } else { 0 };
    let left = if x > 0 { min(base, d.at_or(p - 1, 0) + 1) } else { base };
    let previous = if y > 0 { min(left, d.at_or(p - g.width, 0) + 1) } else { left };
    return d.set(p, previous);
}

fn distance_reverse(g: Grid, p: u32, d: Buffer<u32>) -> Buffer<u32> {
    let x = rem_or(p, g.width, 0);
    let y = quot_or(p, g.width, 0);
    let base = d.at_or(p, 0);
    let right = if x + 1 < g.width { min(base, d.at_or(p + 1, 0) + 1) } else { base };
    let value = if y + 1 < g.height { min(right, d.at_or(p + g.width, 0) + 1) } else { right };
    return d.set(p, value);
}

fn modifier(g: Grid, mask: List<u32>, op: String, amount: u32, side: String) -> List<u32> {
    if op == "invert" { return mask.map(fn(on) => 1 - on); }
    if op == "grow" { return distances(g, mask, false).map(fn(d) => if d <= amount { 1 } else { 0 }); }
    let inward: List<u32> = if op == "shrink" || side != "outside" { distances(g, mask, true) } else { [] };
    if op == "shrink" { return inward.map(fn(d) => if d > amount { 1 } else { 0 }); }
    let outward: List<u32> = if side != "inside" { distances(g, mask, false) } else { [] };
    return mask.map_indexed(fn(i) => fn(on) => if
        (if on != 0 { inward.at_or(i, 65535) } else { outward.at_or(i, 65535) }) <= amount { 1 } else { 0 });
}

fn merge(base: List<u32>, other: List<u32>, op: String) -> List<u32> {
    return base.map_indexed(fn(i) => fn(on) => merge_pixel(on, other.at_or(i, 0), op));
}

fn merge_pixel(on: u32, other: u32, op: String) -> u32 {
    if op == "combine" { return word_or(on, other); }
    return word_and(on, if op == "subtract" { 1 - other } else { other });
}

fn literal(g: Grid, points: List<Vec2<u32>>) -> List<u32> {
    return foldl(points, blank(g), fn(p) => fn(mask) => mask.set(index(g, p), 1)).freeze();
}
