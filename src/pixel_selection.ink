module StudioPixelSelection;

import "std:json" as json;
import "pixel_mask.ink" as mask;
import "pixel_labels.ink" as labels;

record Inputs {
    grid: mask.Grid,
    nodes: List<json.Json>,
    saved: List<json.Member>,
    runs: List<List<u32>>,
    packed: Bool,
}
record Image { rgba: List<u32>, palette: mask.PaletteRaster, }
record Named { ids: List<String>, frames: List<String>, packed: List<Bool>, pixels: List<List<u32>>, }
record Job { operation: String, query: json.Json, }
record Run { pending: Buffer<Job>, values: Buffer<List<u32>>, count: u32, issue: String, }
record Choice { mask: List<u32>, issue: String, }
record Literal { words: Buffer<u32>, issue: String, total: u32, }

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
    if size == 0 || size > 4 { return 4294967295; }
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

fn append_points(g: mask.Grid, points: Buffer<Vec2<u32>>, first: u32, n: u32, total: u32) -> Buffer<Vec2<u32>> {
    if first >= mask.size(g) || n == 0 || n > mask.size(g) - first || n > total - points.len() {
        return points.push(vec2(g.width, g.height));
    }
    return repeat_until(n, points, fn(out) => false, fn(i) => fn(out) =>
        out.push(vec2(rem_or(first + i, g.width, 0), quot_or(first + i, g.width, 0))));
}

fn packed_points(input: Inputs, raw: json.Json, limit: u32) -> List<Vec2<u32>> {
    let runs = input.runs.at_or(word(raw) - 1, []);
    let n = length(runs);
    let count = runs.at_or(0, 4294967295);
    if count > limit || rem_or(n, 2, 0) != 1 { return []; }
    let out: Buffer<Vec2<u32>> = Buffer.empty();
    let points = repeat_until(quot_or(n, 2, 0), out, fn(out) => out.len() > count, fn(i) => fn(out) =>
        append_points(input.grid, out, runs.at_or(i * 2 + 1, 4294967295), runs.at_or(i * 2 + 2, 0), count));
    if points.len() != count { return []; }
    return points.freeze();
}

fn lasso(input: Inputs, query: List<json.Member>, polygon: Bool) -> Choice {
    if !allowed(query, ["points"]) { return bad(bad_tool()); }
    let g = input.grid;
    let raw = field(query, "points");
    let limit: u32 = if polygon { 128 } else { 4096 };
    let coords = if input.packed { packed_points(input, raw, limit) } else { points(items(raw), g) };
    let n = length(coords);
    let valid = if polygon { n >= 3 && n <= 128 } else { n >= 1 && n <= 4096 };
    if !valid || !in_grid(coords, g) {
        return bad("A lasso needs 1–4096 native points or a polygon needs 3–128 native vertices");
    }
    return chosen(mask.lasso(g, coords));
}

fn add_run(g: mask.Grid, first: u32, n: u32, old: Literal) -> Literal {
    let size = mask.size(g);
    if old.issue != "" { return old; }
    if first >= size || n > size - first || n == 0 {
        return Literal { ..old, issue: "A selection pixel is outside the native grid" };
    }
    let last = first + n - 1;
    let start = mask.word_slot(first);
    let overlap = old.total != 0 && repeat_until(mask.word_slot(last) - start + 1, false, fn(on) => on, fn(i) => fn(on) =>
        word_and(old.words.at_or(start + i, 0), mask.span_bits(start + i, first, last)) != 0);
    if overlap {
        return Literal { ..old, issue: "A selection mask repeats a pixel" };
    }
    return Literal { words: mask.fill(old.words, first, last), total: old.total + n, issue: "" };
}

fn literal_error() -> String { return "A pixel mask needs a list of native coordinates"; }

fn initial_literal(g: mask.Grid) -> Literal { return Literal { words: mask.blank(g), total: 0, issue: "" }; }

fn finish_literal(raster: Literal, expected: u32) -> Choice {
    if raster.issue != "" { return bad(raster.issue); }
    if raster.total != expected { return bad(literal_error()); }
    return chosen(raster.words.freeze());
}

fn packed_literal(input: Inputs, pointer: json.Json) -> Choice {
    let runs = input.runs.at_or(word(pointer) - 1, []);
    let n = length(runs);
    let expected = runs.at_or(0, 4294967295);
    if expected > mask.size(input.grid) || rem_or(n, 2, 0) != 1 { return bad(literal_error()); }
    if n == 3 && expected == mask.size(input.grid) && runs.at_or(1, 4294967295) == 0 &&
        runs.at_or(2, 0) == expected { return chosen(mask.full(input.grid)); }
    let raster = repeat_until(quot_or(n, 2, 0), initial_literal(input.grid),
        fn(old) => old.issue != "", fn(i) => fn(old) =>
        add_run(input.grid, runs.at_or(2 * i + 1, 4294967295), runs.at_or(2 * i + 2, 0), old));
    return finish_literal(raster, expected);
}

fn literal(input: Inputs, raw: json.Json) -> Choice {
    if input.packed { return packed_literal(input, raw); }
    let g = input.grid;
    let has_pixels = json.elements(raw).fold(fn(values) => length(values) <= mask.size(g), fn(reason) => false);
    if !has_pixels { return bad(literal_error()); }
    let coords = points(items(raw), g);
    let raster = foldl(coords, initial_literal(g), fn(p) => fn(old) =>
        add_run(g, if inside(p, g) { mask.index(g, p) } else { 4294967295 }, 1, old));
    return finish_literal(raster, length(coords));
}

fn recall(input: Inputs, named: Named, frame: String, query: List<json.Member>) -> Choice {
    let id = field(query, "id");
    if !allowed(query, ["id"]) || !is_text(id) { return bad("Recall needs a saved selection ID"); }
    let name = text(id);
    return json.lookup(input.saved, name).fold(fn(raw) => literal(input, raw),
        fn(unit) => recall_named(input.grid, named, frame, name));
}

fn no_named() -> Named { return Named { ids: [], frames: [], packed: [], pixels: [] }; }

fn named_slot(ids: List<String>, name: String) -> u32 {
    return repeat_until(length(ids), 4294967295, fn(found) => found != 4294967295,
        fn(i) => fn(found) => if ids.at_or(i, "") == name { i } else { found });
}

fn recall_named(g: mask.Grid, named: Named, frame: String, name: String) -> Choice {
    let slot = named_slot(named.ids, name);
    if slot == 4294967295 {
        return bad(string_concat(if frame == "" { "Unknown saved selection " } else { "Unknown pixel selection " }, name));
    }
    let scope = named.frames.at_or(slot, "");
    if scope != "" && scope != frame { return bad(string_concat("Pixel selection belongs to frame ", scope)); }
    let pixels = named.pixels.at_or(slot, []);
    if named.packed.at_or(slot, false) { return chosen(pixels); }
    let words = foldl(pixels, mask.blank(g), fn(p) => fn(out) => mask.mark(out, p));
    return chosen(words.freeze());
}

fn wand(g: mask.Grid, rgba: List<u32>, query: List<json.Member>) -> Choice {
    if !allowed(query, ["at", "tolerance", "connected"]) { return bad(bad_tool()); }
    let p = point(items(field(query, "at")), g);
    let tolerance = optional_word(query, "tolerance", 0);
    let connected = json.lookup(query, "connected").fold(fn(value) => json.as_boolean(value), fn(unit) => Ok(true));
    let valid = connected.fold(fn(value) => true, fn(reason) => false);
    if !inside(p, g) || tolerance > 255 || !valid || length(rgba) != mask.size(g) {
        return bad("A wand needs a native seed, a tolerance from 0 to 255, and an optional connected flag");
    }
    return chosen(mask.wand(g, rgba, p, tolerance, connected.fold(fn(value) => value, fn(reason) => true)));
}

fn find_swatch(ids: List<String>, id: String) -> i32 {
    let none: i32 = -1;
    return repeat_until(length(ids), none, fn(slot) => slot >= 0, fn(i) => fn(slot) =>
        if ids.at_or(i, "") == id {
            i32_from_f64(f64_from_u32(i)).fold(fn(value) => value, fn(unit) => none)
        } else { slot });
}

fn palette_issue(g: mask.Grid, palette: mask.PaletteRaster) -> String {
    let count = mask.size(g);
    if length(palette.slots) == 0 { return "A semantic selection needs a source for swatch"; }
    if length(palette.slots) != count || (length(palette.alpha) != 0 && length(palette.alpha) != count) ||
        (length(palette.clipping) != 0 && length(palette.clipping) != count) {
        return "The indexed selection raster must match the native grid";
    }
    return "";
}

fn swatch(g: mask.Grid, palette: mask.PaletteRaster, query: List<json.Member>) -> Choice {
    if !allowed(query, ["id", "at"]) { return bad("Unknown swatch selection field"); }
    let id = text(field(query, "id"));
    let at = point(items(field(query, "at")), g);
    let has_id = json.lookup(query, "id").fold(fn(value) => true, fn(unit) => false);
    let has_at = json.lookup(query, "at").fold(fn(value) => true, fn(unit) => false);
    if has_id == has_at || (if has_id { !labels.present(id) } else { !inside(at, g) }) {
        return bad("Choose a swatch ID or a native seed pixel and optional part scope");
    }
    let issue = palette_issue(g, palette);
    if issue != "" { return bad(issue); }
    let blank = mask.blank(g);
    let seed = mask.index(g, at);
    if has_at && !mask.palette_visible(palette, seed) { return chosen(blank.freeze()); }
    let target = if has_at { palette.slots.at_or(seed, -1) } else { find_swatch(palette.ids, id) };
    if target < 0 { return chosen(blank.freeze()); }
    let bits = repeat_until(mask.size(g), blank, fn(old) => false, fn(i) => fn(old) =>
        if mask.palette_match(palette, i, target) { mask.mark(old, i) } else { old });
    return chosen(bits.freeze());
}

fn leaf(input: Inputs, image: Image, named: Named, frame: String, operation: String, query: List<json.Member>) -> Choice {
    if operation == "rectangle" || operation == "ellipse" { return marquee(input.grid, query, operation == "ellipse"); }
    if operation == "lasso" || operation == "polygon" { return lasso(input, query, operation == "polygon"); }
    if operation == "wand" { return wand(input.grid, image.rgba, query); }
    if operation == "recall" { return recall(input, named, frame, query); }
    if operation == "pixels" {
        return if allowed(query, ["pixels"]) { literal(input, field(query, "pixels")) }
            else { bad("A literal selection needs native pixels") };
    }
    if operation == "swatch" { return swatch(input.grid, image.palette, query); }
    if operation == "binding" || operation == "object" || operation == "part" ||
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

fn schedule(input: Inputs, image: Image, named: Named, frame: String, value: json.Json, old: Run) -> Run {
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
        return json.lookup(query, "source").fold(fn(raw) =>
            Run { ..run, pending: run.pending.push(finished).push(node(child(input, raw))) },
            fn(unit) => cluster_swatch(input.grid, image.palette, p, connectivity == 8, run));
    }
    return publish(run, leaf(input, image, named, frame, op, query));
}

fn cluster_swatch(g: mask.Grid, palette: mask.PaletteRaster, p: Vec2<u32>, diagonal: Bool, run: Run) -> Run {
    // The implicit swatch consumes an operation even when the flood reads it directly.
    if run.count == 32 { return Run { ..run, issue: "A selection query supports at most 32 operations" }; }
    let issue = palette_issue(g, palette);
    if issue != "" { return Run { ..run, issue: issue }; }
    let result = mask.palette_cluster(g, palette, mask.index(g, p), diagonal);
    return Run { ..run, count: run.count + 1, values: run.values.push(result) };
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

fn step(input: Inputs, image: Image, named: Named, frame: String, old: Run) -> Run {
    let job = old.pending.at_or(old.pending.len() - 1, node(json.null()));
    let run = Run { ..old, pending: old.pending.pop() };
    if job.operation == "" { return schedule(input, image, named, frame, job.query, run); }
    let n = run.values.len();
    let last = run.values.at_or(n - 1, []);
    if merge_op(job.operation) {
        let first = run.values.at_or(n - 2, []);
        return Run { ..run, values: run.values.pop().pop().push(mask.merge(first, last, job.operation)) };
    }
    return publish(Run { ..run, values: run.values.pop() }, apply(input.grid, job, last));
}

fn select(width: u32, height: u32, query: List<json.Json>, rgba: List<u32>, saved: json.Json,
    runs: List<List<u32>>, packed: Bool, large: Bool, palette: mask.PaletteRaster) -> Result<List<u32>, String> {
    let limit: u32 = if large { 8192 } else { 512 };
    if width == 0 || height == 0 || width > limit || height > limit || width * height > 16777216 {
        return Err(if large { "Selection exceeds the material canvas budget" }
            else { "Pixel selections need a canvas from 1 to 512 pixels on each axis" });
    }
    let g = mask.Grid { width: width, height: height };
    let input = request(g, query, saved, runs, packed);
    return evaluate(input, Image { rgba: rgba, palette: palette }, no_named(), "");
}

fn request(g: mask.Grid, query: List<json.Json>, saved: json.Json, runs: List<List<u32>>, packed: Bool) -> Inputs {
    return Inputs { grid: g, nodes: query, saved: members(saved), runs: runs, packed: packed };
}

fn evaluate(input: Inputs, image: Image, named: Named, frame: String) -> Result<List<u32>, String> {
    let run = Run { pending: buffer([node(input.nodes.at_or(0, json.null()))]), values: Buffer.empty(), count: 0, issue: "" };
    let result = repeat_until(65, run, fn(run) => run.issue != "" || run.pending.len() == 0,
        fn(i) => fn(run) => step(input, image, named, frame, run));
    if result.issue != "" { return Err(result.issue); }
    return Ok(result.values.at_or(0, []));
}
