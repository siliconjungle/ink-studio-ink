module StudioPixelCanvasRegistration;

import "std:json" as json;
import "std:binary64_decimal" as decimal;
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
