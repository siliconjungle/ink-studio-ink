module StudioPixelSelection;

import "std:json" as json;
import "pixel_mask.ink" as mask;

record Inputs { grid: mask.Grid, nodes: List<json.Json>, rgba: List<u32>, saved: List<json.Member>, }
record Job { operation: String, query: json.Json, }
record Run { pending: Buffer<Job>, values: Buffer<List<u32>>, count: u32, issue: String, }
record Choice { mask: List<u32>, issue: String, }

fn members(raw: json.Json) -> List<json.Member> {
    return json.members(raw).fold(fn(items) => items, fn(reason) => []);
}

fn items(value: json.Json) -> List<json.Json> {
    return json.elements(value).fold(fn(rows) => rows, fn(reason) => []);
}

fn field(object: List<json.Member>, name: String) -> json.Json {
    return json.lookup(object, name).fold(fn(value) => value, fn(unit) => json.null());
}

fn text(raw: json.Json) -> String { return json.as_text(raw).fold(fn(s) => s, fn(reason) => ""); }
fn is_text(raw: json.Json) -> Bool { return json.as_text(raw).fold(fn(s) => true, fn(reason) => false); }

fn allowed(object: List<json.Member>, keys: List<String>) -> Bool {
    return foldl(object, true, fn(item) => fn(valid) =>
        valid && (item.key == "type" || foldl(keys, false, fn(key) => fn(found) => found || item.key == key)));
}

fn word(value: json.Json) -> u32 {
    let token = json.as_number(value).fold(fn(value) => value, fn(reason) => "");
    let size = string_byte_len(token);
    if token == "-0" { return 0; }
    if size == 0 || size > 3 { return 4294967295; }
    return repeat_until(size, 0, fn(value) => value == 4294967295, fn(i) => fn(value) =>
        decimal_digit(value, string_byte_at(token, i).fold(fn(byte) => byte, fn(unit) => 0)));
}

fn decimal_digit(value: u32, digit: u32) -> u32 {
    return if digit >= 48 && digit <= 57 { value * 10 + digit - 48 } else { 4294967295 };
}

fn optional_word(query: List<json.Member>, key: String, default: u32) -> u32 {
    return json.lookup(query, key).fold(fn(value) => word(value), fn(unit) => default);
}

fn point(values: List<json.Json>, g: mask.Grid) -> Vec2<u32> {
    if length(values) != 2 { return vec2(g.width, g.height); }
    return vec2(word(values.at_or(0, json.null())), word(values.at_or(1, json.null())));
}

fn inside(p: Vec2<u32>, g: mask.Grid) -> Bool { return p.x < g.width && p.y < g.height; }

fn bad(issue: String) -> Choice { return Choice { mask: [], issue: issue }; }
fn chosen(value: List<u32>) -> Choice { return Choice { mask: value, issue: "" }; }
fn bad_tool() -> String { return "Choose a rectangle, ellipse, lasso, polygon, wand or selection operation"; }

fn marquee(g: mask.Grid, query: List<json.Member>, ellipse: Bool) -> Choice {
    if !allowed(query, ["rect"]) { return bad(bad_tool()); }
    let r = items(field(query, "rect"));
    let x = word(r.at_or(0, json.null()));
    let y = word(r.at_or(1, json.null()));
    let w = word(r.at_or(2, json.null()));
    let h = word(r.at_or(3, json.null()));
    if length(r) != 4 || x >= g.width || y >= g.height || w == 0 || h == 0 || w > g.width - x || h > g.height - y {
        return bad("A marquee needs an in-bounds [x, y, width, height] rectangle");
    }
    return chosen(mask.marquee(g, mask.Rect { x: x, y: y, w: w, h: h }, ellipse));
}

fn points(raw: List<json.Json>, g: mask.Grid) -> List<Vec2<u32>> {
    return raw.map(fn(value) => point(items(value), g));
}

fn in_grid(coords: List<Vec2<u32>>, g: mask.Grid) -> Bool {
    return foldl(coords, true, fn(p) => fn(valid) => valid && inside(p, g));
}

fn lasso(g: mask.Grid, query: List<json.Member>, polygon: Bool) -> Choice {
    if !allowed(query, ["points"]) { return bad(bad_tool()); }
    let raw = items(field(query, "points"));
    let coords = points(raw, g);
    let n = length(coords);
    let valid = if polygon { n >= 3 && n <= 128 } else { n >= 1 && n <= 4096 };
    if !valid || !in_grid(coords, g) {
        return bad("A lasso needs 1–4096 native points or a polygon needs 3–128 native vertices");
    }
    return chosen(mask.lasso(g, coords));
}

fn has_duplicate(sorted: List<u32>) -> Bool {
    return repeat_until(length(sorted), false, fn(found) => found, fn(i) => fn(found) =>
        i > 0 && sorted.at_or(i, 0) == sorted.at_or(i - 1, 0));
}

fn literal(g: mask.Grid, raw: json.Json) -> Choice {
    let has_pixels = json.elements(raw).fold(fn(values) => length(values) <= mask.size(g), fn(reason) => false);
    if !has_pixels { return bad("A pixel mask needs a list of native coordinates"); }
    let coords = points(items(raw), g);
    if !in_grid(coords, g) { return bad("A selection pixel is outside the native grid"); }
    if has_duplicate(coords.map(fn(p) => mask.index(g, p)).sort()) { return bad("A selection mask repeats a pixel"); }
    return chosen(mask.literal(g, coords));
}

fn recall(input: Inputs, query: List<json.Member>) -> Choice {
    let id = field(query, "id");
    if !allowed(query, ["id"]) || !is_text(id) { return bad("Recall needs a saved selection ID"); }
    return json.lookup(input.saved, text(id)).fold(fn(raw) => literal(input.grid, raw),
        fn(unit) => bad(string_concat("Unknown saved selection ", text(id))));
}

fn wand(input: Inputs, query: List<json.Member>) -> Choice {
    if !allowed(query, ["at", "tolerance", "connected"]) { return bad(bad_tool()); }
    let p = point(items(field(query, "at")), input.grid);
    let tolerance = optional_word(query, "tolerance", 0);
    let connected = json.lookup(query, "connected").fold(fn(value) => json.as_boolean(value), fn(unit) => Ok(true));
    let valid = connected.fold(fn(value) => true, fn(reason) => false);
    if !inside(p, input.grid) || tolerance > 255 || !valid || length(input.rgba) != mask.size(input.grid) {
        return bad("A wand needs a native seed, a tolerance from 0 to 255, and an optional connected flag");
    }
    return chosen(mask.wand(input.grid, input.rgba, p, tolerance, connected.fold(fn(value) => value, fn(reason) => true)));
}

fn leaf(input: Inputs, operation: String, query: List<json.Member>) -> Choice {
    if operation == "rectangle" || operation == "ellipse" { return marquee(input.grid, query, operation == "ellipse"); }
    if operation == "lasso" || operation == "polygon" { return lasso(input.grid, query, operation == "polygon"); }
    if operation == "wand" { return wand(input, query); }
    if operation == "recall" { return recall(input, query); }
    if operation == "pixels" {
        return if allowed(query, ["pixels"]) { literal(input.grid, field(query, "pixels")) }
            else { bad("A literal selection needs native pixels") };
    }
    if operation == "swatch" || operation == "binding" || operation == "object" || operation == "part" ||
        operation == "material" || operation == "depth" || operation == "channel" {
        return bad(string_concat("A semantic selection needs a source for ", operation));
    }
    return bad(bad_tool());
}

fn merge_op(op: String) -> Bool { return op == "combine" || op == "subtract" || op == "intersect"; }
fn modifier_op(op: String) -> Bool { return op == "invert" || op == "grow" || op == "shrink" || op == "outline"; }
fn node(value: json.Json) -> Job { return Job { operation: "", query: value }; }

fn child(input: Inputs, pointer: json.Json) -> json.Json {
    return input.nodes.at_or(word(pointer) - 1, json.null());
}

fn publish(run: Run, value: Choice) -> Run {
    if value.issue != "" { return Run { ..run, issue: value.issue }; }
    return Run { ..run, values: run.values.push(value.mask) };
}

fn schedule(input: Inputs, value: json.Json, old: Run) -> Run {
    if old.count == 32 { return Run { ..old, issue: "A selection query supports at most 32 operations" }; }
    let run = Run { ..old, count: old.count + 1 };
    let query = members(value);
    let op = text(field(query, "type"));
    let finished = Job { operation: op, query: value };
    if merge_op(op) {
        if !allowed(query, ["base", "with"]) { return Run { ..run, issue: "Combine, subtract and intersect need base and with masks" }; }
        return Run { ..run, pending: run.pending.push(finished)
            .push(node(child(input, field(query, "with")))).push(node(child(input, field(query, "base")))) };
    }
    if modifier_op(op) {
        let keys = if op == "outline" { ["source", "amount", "side"] }
            else { if op == "invert" { ["source"] } else { ["source", "amount"] } };
        if !allowed(query, keys) { return Run { ..run, issue: "A selection modifier needs a source mask and valid options" }; }
        return Run { ..run, pending: run.pending.push(finished).push(node(child(input, field(query, "source")))) };
    }
    if op == "cluster" {
        let p = point(items(field(query, "at")), input.grid);
        let connectivity = optional_word(query, "connectivity", 4);
        if !allowed(query, ["at", "source", "connectivity"]) || !inside(p, input.grid) ||
            !(connectivity == 4 || connectivity == 8) {
            return Run { ..run, issue: "A cluster needs a native seed and optional 4 or 8 connectivity" };
        }
        let source = json.lookup(query, "source").fold(fn(raw) => child(input, raw), fn(unit) =>
            json.object([json.Member { key: "type", value: json.text("swatch") }]));
        return Run { ..run, pending: run.pending.push(finished).push(node(source)) };
    }
    return publish(run, leaf(input, op, query));
}

fn apply(g: mask.Grid, job: Job, source: List<u32>) -> Choice {
    let q = members(job.query);
    if job.operation == "cluster" {
        let p = point(items(field(q, "at")), g);
        return chosen(mask.cluster(g, source, p, optional_word(q, "connectivity", 4) == 8));
    }
    let amount = optional_word(q, "amount", 1);
    let side = json.lookup(q, "side").fold(fn(v) => text(v), fn(unit) => "inside");
    if amount == 0 || amount > 512 || !(side == "inside" || side == "outside" || side == "both") {
        return bad("Selection radius must be 1–512 pixels and outline side must be inside, outside or both");
    }
    return chosen(mask.modifier(g, source, job.operation, amount, side));
}

fn step(input: Inputs, old: Run) -> Run {
    let job = old.pending.at_or(old.pending.len() - 1, node(json.null()));
    let run = Run { ..old, pending: old.pending.pop() };
    if job.operation == "" { return schedule(input, job.query, run); }
    let n = run.values.len();
    let last = run.values.at_or(n - 1, []);
    if merge_op(job.operation) {
        let first = run.values.at_or(n - 2, []);
        return Run { ..run, values: run.values.pop().pop().push(mask.merge(first, last, job.operation)) };
    }
    return publish(Run { ..run, values: run.values.pop() }, apply(input.grid, job, last));
}

fn select(width: u32, height: u32, query: List<json.Json>, rgba: List<u32>, saved: json.Json) -> Result<List<u32>, String> {
    if width == 0 || height == 0 || width > 512 || height > 512 {
        return Err("Pixel selections need a canvas from 1 to 512 pixels on each axis");
    }
    let input = Inputs { grid: mask.Grid { width: width, height: height }, nodes: query, rgba: rgba, saved: members(saved) };
    let run = Run { pending: buffer([node(query.at_or(0, json.null()))]), values: Buffer.empty(), count: 0, issue: "" };
    let result = repeat_until(65, run, fn(run) => run.issue != "" || run.pending.len() == 0,
        fn(i) => fn(run) => step(input, run));
    if result.issue != "" { return Err(result.issue); }
    let selected = result.values.at_or(0, []);
    let pixels = selected.map_indexed(fn(i) => fn(on) => if on == 0 { 4294967295 } else { i });
    return Ok(pixels.filter(fn(i) => i != 4294967295));
}
