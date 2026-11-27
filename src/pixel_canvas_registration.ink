module StudioPixelCanvasRegistration;

import "std:json" as json;
import "std:binary64_decimal" as decimal;
import "pixel_brush.ink" as brush;
import "pixel_commands.ink" as commands;
import "pixel_canvas.ink" as canvas;
import "pixel_paint.ink" as paint;
import "pixel_values.ink" as value;

fn number(n: f64) -> json.Json {
    return decimal.finite(n).fold(fn(token) => json.number(token), fn(unit) => json.null());
}

fn pair(x: f64, y: f64) -> json.Json {
    return json.array([number(x), number(y)]);
}

fn scale(map: canvas.Canvas) -> json.Json { return pair(map.sx, map.sy); }

fn preserve(map: canvas.Canvas, prior: json.Json, before: json.Json, after: json.Json) -> Result<json.Json, String> {
    let fields = value.fields(prior);
    let size = if prior == json.null() { before } else { value.get(fields, "size") };
    let offset_key = if prior == json.null() { pair(0.0f64, 0.0f64) } else { value.get(fields, "offset") };
    let scale_key = if prior == json.null() { pair(1.0f64, 1.0f64) } else { value.get(fields, "scale") };
    let offsets = value.items(offset_key);
    let scales = value.items(scale_key);
    let sx = value.number(scales.at_or(0, json.null()));
    let sy = value.number(scales.at_or(1, json.null()));
    let x = value.number(offsets.at_or(0, json.null())) + f64_from_i32(map.offset.x) * sx;
    let y = value.number(offsets.at_or(1, json.null())) + f64_from_i32(map.offset.y) * sy;
    return registration(size, after, x, y, sx * map.sx, sy * map.sy);
}

fn registration(size: json.Json, grid: json.Json, x: f64, y: f64, sx: f64, sy: f64) -> Result<json.Json, String> {
    if !is_finite(x) || !is_finite(y) || !is_finite(sx) || !is_finite(sy) || sx <= 0.0f64 || sy <= 0.0f64 {
        return Err("Canvas registration is outside the numeric range");
    }
    if size == grid && x == 0.0f64 && y == 0.0f64 && sx == 1.0f64 && sy == 1.0f64 { return Ok(json.null()); }
    return Ok(json.object([paint.member("size", size), paint.member("offset", pair(x, y)),
        paint.member("scale", pair(sx, sy))]));
}

fn invalid_view() -> String {
    return "Directional views need distinct document frames, registered angles, scale and valid anchors";
}

fn view_coordinate(n: f64) -> Bool {
    return is_finite(n) && n >= -1000000.0f64 && n <= 1000000.0f64;
}

fn shift(map: canvas.Canvas, old: json.Json) -> Result<json.Json, String> {
    let raw = value.items(old);
    let x = (value.number(raw.at_or(0, json.null())) - f64_from_i32(map.offset.x)) / map.sx;
    let y = (value.number(raw.at_or(1, json.null())) - f64_from_i32(map.offset.y)) / map.sy;
    if !view_coordinate(x) || !view_coordinate(y) { return Err(invalid_view()); }
    return Ok(pair(x, y));
}

fn anchor(map: canvas.Canvas, member: json.Member, progress: Result<List<json.Member>, String>)
    -> Result<List<json.Member>, String> {
    let rows = progress?;
    let position = shift(map, member.value)?;
    return Ok(rows.concat([paint.member(member.key, position)]));
}

fn transform_view(map: canvas.Canvas, raw: json.Json) -> Result<json.Json, String> {
    let row = value.fields(raw);
    let pivot = shift(map, value.get(row, "pivot"))?;
    let units = value.number(value.get(row, "unitsPerPixel")) * map.sx;
    if !is_finite(units) || units < 0.000001f64 { return Err(invalid_view()); }
    let view = paint.replace(paint.replace(row, "pivot", pivot), "unitsPerPixel", number(units));
    if !value.has(row, "anchors") { return Ok(json.object(view)); }
    let initial: Result<List<json.Member>, String> = Ok([]);
    let anchors = foldl(value.fields(value.get(row, "anchors")), initial, fn(member) => fn(rows) => anchor(map, member, rows))?;
    return Ok(json.object(paint.replace(view, "anchors", json.object(anchors))));
}

fn append_view(map: canvas.Canvas, row: json.Json, progress: Result<List<json.Json>, String>)
    -> Result<List<json.Json>, String> {
    let rows = progress?;
    let view = transform_view(map, row)?;
    return Ok(rows.concat([view]));
}

fn directional(map: canvas.Canvas, source: json.Json) -> Result<json.Json, String> {
    if map.sx != map.sy { return Err("Directional view registration needs uniform canvas resampling"); }
    let row = value.fields(source);
    let initial: Result<List<json.Json>, String> = Ok([]);
    let views = foldl(value.items(value.get(row, "views")), initial, fn(view) => fn(rows) => append_view(map, view, rows))?;
    return Ok(json.object(paint.replace(row, "views", json.array(views))));
}

fn vector(raw: json.Json, count: u32) -> Bool {
    let values = value.items(raw);
    return length(values) == count && foldl(values, true, fn(coord) => fn(ok) => ok && view_coordinate(value.number(coord)));
}

fn heading(yaw: f64) -> f64 {
    let circle = 6.283185307179586f64;
    return yaw - circle * floor(yaw / circle);
}

record Heading { frame_id: String, pose: u32, pitch: f64, yaw: f64, }

fn part_anchor(raw: json.Json, previous: Result<List<String>, String>) -> Result<List<String>, String> {
    let seen = previous?;
    let diagnostic = "Part anchors need a unique ID, named part and finite asset-space XYZ";
    let row = json.members(raw).map_err(fn(issue) => diagnostic)?;
    let id = value.text(value.get(row, "id"));
    if !brush.stable_id(id) || !brush.stable_id(value.text(value.get(row, "part"))) || commands.includes(seen, id) ||
        !value.only(row, ["id", "part", "point"]) || !vector(value.get(row, "point"), 3) { return Err(diagnostic); }
    return Ok(seen.concat([id]));
}

fn registered_point(row: List<json.Member>, anchors: List<String>) -> Bool {
    let handoff = value.text(value.get(row, "handoff"));
    let units = value.number(value.get(row, "unitsPerPixel"));
    if !vector(value.get(row, "pivot"), 2) || !is_finite(units) || units < 0.000001f64 ||
        (value.has(row, "handoff") && handoff != "exact" && handoff != "blend") { return false; }
    return json.lookup(row, "anchors").fold(fn(raw) => json.members(raw).fold(fn(points) =>
        value.only(points, anchors) && foldl(points, true, fn(point) => fn(ok) => ok && vector(point.value, 2)),
        fn(issue) => false), fn(unit) => true);
}

fn same_heading(old: Heading, next: Heading) -> Bool {
    let distance = value.max(old.yaw, next.yaw) - value.min(old.yaw, next.yaw);
    return old.pose == next.pose && old.pitch == next.pitch && value.min(distance, 6.283185307179586f64 - distance) < 0.00000001f64;
}

fn view(raw: json.Json, frames: List<String>, anchors: List<String>, previous: Result<List<Heading>, String>) ->
    Result<List<Heading>, String> {
    let seen = previous?;
    let issue = invalid_view();
    let row = json.members(raw).map_err(fn(error) => issue)?;
    let id = value.text(value.get(row, "frame"));
    let pose = value.word(value.get(row, "pose"), 32767);
    let yaw = value.number(value.get(row, "yaw"));
    let pitch = value.number(value.get(row, "pitch"));
    if !commands.includes(frames, id) || pose > 32767 || !view_coordinate(yaw) || !is_finite(pitch) ||
        pitch < -1.5707963267948966f64 || pitch > 1.5707963267948966f64 || !registered_point(row, anchors) ||
        !value.only(row, ["frame", "pose", "yaw", "pitch", "pivot", "unitsPerPixel", "anchors", "handoff"]) ||
        length(seen.filter(fn(old) => old.frame_id == id)) != 0 { return Err(issue); }
    let next = Heading { frame_id: id, pose: pose, pitch: pitch, yaw: heading(yaw) };
    if length(seen.filter(fn(row) => same_heading(row, next))) != 0 {
        return Err(string_concat("Directional views repeat a heading in pose ",
            string_concat(frame_number(pose), string_concat(" at pitch ", numeric_label(pitch)))));
    }
    return Ok(seen.concat([next]));
}

fn numeric_label(n: f64) -> String { return decimal.finite(n).fold(fn(token) => token, fn(unit) => "0"); }
fn frame_number(n: u32) -> String { return numeric_label(f64_from_u32(n)); }

fn swatches_ok(raw: json.Json, known: List<String>) -> Bool {
    let names = value.items(raw).map(fn(row) => value.text(row));
    let initial: List<String> = [];
    let unique = foldl(names, initial, fn(name) => fn(out) =>
        if !commands.includes(known, name) || commands.includes(out, name) { out } else { out.concat([name]) });
    return length(names) != 0 && length(names) == length(unique);
}

fn validate(source: json.Json, frames: List<String>, swatches: List<String>) -> Result<Unit, String> {
    let message = "Use a version 1 directional set with 1–512 registered views";
    let row = json.members(source).map_err(fn(issue) => message)?;
    let views = value.items(value.get(row, "views"));
    let blend = value.text(value.get(row, "viewBlend"));
    if !value.only(row, ["version", "views", "partAnchors", "approvedSwatches", "viewBlend"]) ||
        value.number(value.get(row, "version")) != 1.0f64 || length(views) == 0 || length(views) > 512 ||
        (value.has(row, "viewBlend") && blend != "nearest" && blend != "depth-reprojected") { return Err(message); }
    if value.has(row, "approvedSwatches") && !swatches_ok(value.get(row, "approvedSwatches"), swatches) {
        return Err("Approved directional swatches need unique document swatch IDs");
    }
    let anchors = value.get(row, "partAnchors");
    let part_message = "Use up to 64 directional part anchors";
    let decoded: Result<List<json.Json>, String> = if anchors == json.null() { Ok([]) }
        else { json.elements(anchors).map_err(fn(issue) => part_message) };
    let parts = decoded?;
    if length(parts) > 64 { return Err(part_message); }
    let initial: Result<List<String>, String> = Ok([]);
    let names = foldl(parts, initial, fn(part) => fn(out) => part_anchor(part, out))?;
    let empty: Result<List<Heading>, String> = Ok([]);
    let checked = foldl(views, empty, fn(raw) => fn(out) => view(raw, frames, names, out))?;
    return Ok(());
}
