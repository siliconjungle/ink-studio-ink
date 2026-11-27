module StudioPixelSlices;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_capture.ink" as labels;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_timeline.ink" as timeline;
import "pixel_values.ink" as value;

record Edit { rows: List<json.Json>, fields: List<json.Member>, }

fn member(key: String, raw: json.Json) -> json.Member { return paint.member(key, raw); }
fn id(row: json.Json) -> String { return value.text(value.get(value.fields(row), "id")); }
fn number(n: u32) -> json.Json { return json.number(frame.decimal(n)); }

fn nonnegative(n: f64) -> Bool { return n >= 0.0f64 && n <= 9007199254740991.0f64 && n == floor(n); }
fn half(n: f64) -> Bool { return n >= -8192.0f64 && n <= 8192.0f64 && n * 2.0f64 == floor(n * 2.0f64); }

fn key_error(id: String, issue: String) -> String {
    return string_concat("Slice ", string_concat(id, issue));
}

fn valid_numbers(values: List<json.Json>, n: u32, test: fn(f64) -> Bool) -> Bool {
    return length(values) == n && foldl(values, true, fn(raw) => fn(ok) => ok && test(value.number(raw)));
}

fn coordinates(row: List<json.Member>, id: String, grid: mask.Grid) -> Result<Unit, String> {
    let raw = value.get(row, "bounds");
    if value.has(row, "bounds") && raw == json.null() && !value.has(row, "pivot") && !value.has(row, "nineSlice") {
        return Ok(());
    }
    let bounds = value.items(raw);
    if !valid_numbers(bounds, 4, fn(n) => nonnegative(n)) {
        return Err(key_error(id, " needs integer [x,y,width,height] bounds"));
    }
    let x = value.number(bounds.at_or(0, json.null()));
    let y = value.number(bounds.at_or(1, json.null()));
    let w = value.number(bounds.at_or(2, json.null()));
    let h = value.number(bounds.at_or(3, json.null()));
    if w < 1.0f64 || h < 1.0f64 || x + w > f64_from_u32(grid.width) || y + h > f64_from_u32(grid.height) {
        return Err(key_error(id, " bounds must be inside the native canvas"));
    }
    if value.has(row, "pivot") && !valid_numbers(value.items(value.get(row, "pivot")), 2, fn(n) => half(n)) {
        return Err(key_error(id, " pivot needs finite half-pixel coordinates"));
    }
    return stretch(row, id, w, h);
}

fn stretch(row: List<json.Member>, id: String, w: f64, h: f64) -> Result<Unit, String> {
    if !value.has(row, "nineSlice") { return Ok(()); }
    let inset = value.items(value.get(row, "nineSlice"));
    if !valid_numbers(inset, 4, fn(n) => nonnegative(n)) {
        return Err(key_error(id, " nine-slice needs [left,top,right,bottom] insets"));
    }
    let x = value.number(inset.at_or(0, json.null())) + value.number(inset.at_or(2, json.null()));
    let y = value.number(inset.at_or(1, json.null())) + value.number(inset.at_or(3, json.null()));
    if x >= w || y >= h { return Err(key_error(id, " nine-slice needs a nonempty stretch rectangle")); }
    return Ok(());
}

fn check_key(raw: json.Json, id: String, frames: List<String>, grid: mask.Grid, seen: Result<List<String>, String>) ->
    Result<List<String>, String> {
    let previous = seen?;
    let issue = key_error(id, " needs distinct keys on known frames");
    let row = json.members(raw).map_err(fn(error) => issue)?;
    let frame_id = value.text(value.get(row, "frame"));
    if !value.only(row, ["frame", "bounds", "pivot", "nineSlice"]) ||
        !frame.known_frame(frames, frame_id) || commands.includes(previous, frame_id) { return Err(issue); }
    let checked = coordinates(row, id, grid)?;
    return Ok(previous.concat([frame_id]));
}

fn check_slice(raw: json.Json, frames: List<String>, grid: mask.Grid, seen: Result<List<String>, String>) ->
    Result<List<String>, String> {
    let previous = seen?;
    let issue = "Pixel slices need a unique ID and a list of frame keys";
    let row = json.members(raw).map_err(fn(error) => issue)?;
    let keys = json.elements(value.get(row, "keys")).map_err(fn(error) => issue)?;
    let name = id(raw);
    let label_ok = !value.has(row, "label") || commands.non_blank(value.text(value.get(row, "label")));
    if !value.only(row, ["id", "label", "keys"]) || !brush.stable_id(name) || !label_ok ||
        commands.includes(previous, name) || length(keys) > length(frames) { return Err(issue); }
    let initial: Result<List<String>, String> = Ok([]);
    let checked = foldl(keys, initial, fn(raw) => fn(out) => check_key(raw, name, frames, grid, out))?;
    return Ok(previous.concat([name]));
}

fn validate(raw: json.Json, frames: List<String>, grid: mask.Grid) -> Result<List<json.Json>, String> {
    let message = "Use a list of up to 256 pixel slices";
    let rows = json.elements(raw).map_err(fn(issue) => message)?;
    if length(rows) > 256 { return Err(message); }
    let initial: Result<List<String>, String> = Ok([]);
    let checked = foldl(rows, initial, fn(row) => fn(out) => check_slice(row, frames, grid, out))?;
    return Ok(rows);
}

fn find_by(rows: List<json.Json>, key: String, wanted: json.Json) -> json.Json {
    return foldl(rows, json.null(), fn(row) => fn(found) =>
        if value.get(value.fields(row), key) == wanted { row } else { found });
}

fn updated(rows: List<json.Json>, key: String, wanted: json.Json, raw: json.Json) -> List<json.Json> {
    if raw == json.null() { return rows.filter(fn(row) => value.get(value.fields(row), key) != wanted); }
    if find_by(rows, key, wanted) == json.null() { return rows.concat([raw]); }
    return rows.map(fn(row) => if value.get(value.fields(row), key) == wanted { raw } else { row });
}

fn set_key(before: json.Json, op: List<json.Member>, name: json.Json) -> Result<json.Json, String> {
    let prior = value.fields(before);
    let key = value.get(op, "key");
    let raw_label = value.get(op, "label");
    let label = if value.has(op, "label") { raw_label } else { value.get(prior, "label") };
    if (label != json.null() && !commands.non_blank(value.text(label))) || key == json.null() ||
        key == json.boolean(false) || key == json.text("") || key == json.number("0") {
        return Err("Set a slice key with frame and bounds");
    }
    let keys = updated(value.items(value.get(prior, "keys")), "frame", value.get(value.fields(key), "frame"), key);
    let names: List<json.Member> = if label == json.null() { [] } else { [member("label", label)] };
    return Ok(json.object([member("id", name)].concat(names).concat([member("keys", json.array(keys))])));
}

fn remove_key(before: json.Json, name: String, tool: String, op: List<json.Member>) -> Result<json.Json, String> {
    if before == json.null() { return Err(string_concat("Unknown pixel slice ", name)); }
    if tool == "remove-slice" { return Ok(json.null()); }
    let row = value.fields(before);
    let keys = value.items(value.get(row, "keys"));
    let id = value.get(op, "frame");
    if find_by(keys, "frame", id) == json.null() {
        return Err(key_error(name, string_concat(" has no key on frame ", timeline_label(op, "frame"))));
    }
    let next = updated(keys, "frame", id, json.null());
    return Ok(if length(next) == 0 { json.null() } else { json.object(paint.replace(row, "keys", json.array(next))) });
}

fn timeline_label(row: List<json.Member>, key: String) -> String {
    return json.lookup(row, key).fold(fn(raw) => labels.label(raw), fn(unit) => "undefined");
}

fn apply(rows: List<json.Json>, tool: String, op: List<json.Member>, frames: List<String>, grid: mask.Grid) ->
    Result<Edit, String> {
    let more: List<String> = if tool == "set-slice-key" { ["label", "key"] }
        else { if tool == "remove-slice-key" { ["frame"] } else { [] } };
    let key = value.get(op, "id");
    let name = value.text(key);
    if !brush.stable_id(name) || !value.only(op, ["type", "id"].concat(more)) {
        return Err("Choose a slice ID and set-slice-key, remove-slice-key, or remove-slice");
    }
    let prior = find_by(rows, "id", key);
    let requested = if tool == "set-slice-key" { set_key(prior, op, key) } else { remove_key(prior, name, tool, op) };
    let after = requested?;
    let next = validate(json.array(updated(rows, "id", key, after)), frames, grid)?;
    let frame_id = if tool == "set-slice-key" { value.get(value.fields(value.get(op, "key")), "frame") }
        else { value.get(op, "frame") };
    let scoped: List<json.Member> = if value.text(frame_id) == "" { [] } else { [member("frame", frame_id)] };
    return Ok(Edit { rows: next, fields: [member("slice", key)].concat(scoped)
        .concat([member("before", prior), member("after", after)]) });
}

record ActiveKey { position: u32, key: json.Json, }
record Image { report: json.Json, width: u32, height: u32, pixels: List<u32>, }

fn key_at(keys: List<json.Json>, frames: List<String>, index: u32) -> json.Json {
    return foldl(keys, ActiveKey { position: 0, key: json.null() }, fn(row) => fn(found) =>
        choose_key(row, frames, index, found)).key;
}

fn choose_key(row: json.Json, frames: List<String>, index: u32, found: ActiveKey) -> ActiveKey {
    let position = selection.named_slot(frames, value.text(value.get(value.fields(row), "frame")));
    return if position <= index && (found.key == json.null() || position > found.position) {
        ActiveKey { position: position, key: row }
    } else { found };
}

fn registration(bounds: List<json.Json>, raw: json.Json) -> json.Json {
    let pivot = value.items(raw);
    let axes: List<u32> = [0, 1];
    return json.array(axes.map(fn(i) =>
        timeline.number(value.number(bounds.at_or(i, json.null())) + value.number(pivot.at_or(i, json.null())))));
}

fn stretch_rect(bounds: List<json.Json>, raw: json.Json) -> json.Json {
    let inset = value.items(raw);
    let w = value.word(bounds.at_or(2, json.null()), 512);
    let h = value.word(bounds.at_or(3, json.null()), 512);
    let x = value.word(inset.at_or(0, json.null()), 512);
    let y = value.word(inset.at_or(1, json.null()), 512);
    return json.array([number(x), number(y), number(w - x - value.word(inset.at_or(2, json.null()), 512)),
        number(h - y - value.word(inset.at_or(3, json.null()), 512))]);
}

fn active_row(raw: json.Json, frames: List<String>, index: u32) -> json.Json {
    let row = value.fields(raw);
    let key = value.fields(key_at(value.items(value.get(row, "keys")), frames, index));
    let inside = value.get(key, "bounds");
    if inside == json.null() { return json.null(); }
    let bounds = value.items(inside);
    let pivot = json.lookup(key, "pivot").fold(fn(at) => [member("pivot", at), member("registration", registration(bounds, at))], fn(unit) => []);
    let stretch = json.lookup(key, "nineSlice").fold(fn(inset) =>
        [member("nineSlice", inset), member("stretch", stretch_rect(bounds, inset))], fn(unit) => []);
    return json.object([member("id", value.get(row, "id"))].concat(timeline.optional(row, "label")).concat([
        member("keyFrame", value.get(key, "frame")), member("bounds", inside)]).concat(pivot).concat(stretch));
}

fn describe(source: json.Json, art: frame.Artwork, revision: String, requested: Option<String>) -> Result<json.Json, String> {
    let rows = value.items(value.get(value.fields(source), "slices"));
    let base = [member("format", json.text("ink-studio/pixel-slices")), member("version", json.number("1")),
        member("revision", json.text(revision)), member("grid", json.array([number(art.grid.width), number(art.grid.height)])),
        member("slices", json.array(rows))];
    return requested.fold(fn(id) => scoped_report(base, rows, art.frames, id), fn(unit) => Ok(json.object(base)));
}

fn scoped_report(base: List<json.Member>, rows: List<json.Json>, frames: List<String>, id: String) -> Result<json.Json, String> {
    let index = selection.named_slot(frames, id);
    if index >= length(frames) { return Err(string_concat("Unknown pixel frame ", id)); }
    let active = rows.map(fn(row) => active_row(row, frames, index)).filter(fn(row) => row != json.null());
    return Ok(json.object(base.concat([member("frame", json.text(id)), member("active", json.array(active))])));
}

fn picture(source: json.Json, art: frame.Artwork, revision: String, name: String, requested: Option<String>) -> Result<Image, String> {
    let id = requested.fold(fn(frame_id) => frame_id, fn(unit) => art.frames.at_or(0, ""));
    let order = selection.named_slot(art.frames, id);
    if order >= length(art.frames) { return Err(string_concat("Unknown pixel frame ", id)); }
    let doc = value.fields(source);
    let rows = value.items(value.get(doc, "slices"));
    let selected = active_row(find_by(rows, "id", json.text(name)), art.frames, order);
    if selected == json.null() {
        return Err(key_error(name, string_concat(" has no active key on frame ", id)));
    }
    let view = frame.paint_view(art, frame.Scope { frame: id, layer: "" })?;
    let report = [member("format", json.text("ink-studio/pixel-slice")), member("version", json.number("1")),
        member("revision", json.text(revision)), member("frame", json.text(id)), member("pixelAspect", value.get(doc, "pixelAspect"))];
    return Ok(crop(art.grid, view.pixels, value.fields(selected), report));
}

fn crop(g: mask.Grid, pixels: List<frame.Pixel>, slice: List<json.Member>, report: List<json.Member>) -> Image {
    let box = value.items(value.get(slice, "bounds"));
    let x = value.word(box.at_or(0, json.null()), 512);
    let y = value.word(box.at_or(1, json.null()), 512);
    let w = value.word(box.at_or(2, json.null()), 512);
    let h = value.word(box.at_or(3, json.null()), 512);
    let initial: Buffer<u32> = Buffer.empty();
    let region = repeat_until(w * h, initial, fn(out) => false, fn(i) => fn(out) =>
        out.push(rgba(pixels.at_or((y + quot_or(i, w, 0)) * g.width + x + rem_or(i, w, 0), frame.blank()))));
    return Image { report: json.object(report.concat(slice)), width: w, height: h, pixels: region.freeze() };
}

fn rgba(pixel: frame.Pixel) -> u32 {
    return if pixel.slot < 0 { 0 } else { frame.rgba(pixel.color, pixel.alpha) };
}
