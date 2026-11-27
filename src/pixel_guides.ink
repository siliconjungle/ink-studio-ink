module StudioPixelGuides;

import "std:json" as json;
import "std:binary64_decimal" as decimal;
import "pixel_asset_export.ink" as assets;
import "pixel_brush.ink" as brush;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_inspect.ink" as inspection;
import "pixel_values.ink" as value;

record Position { x: f64, y: f64, }
record Axis { id: String, distance: f64, value: f64, priority: u32, }
record Point { id: String, distance: f64, at: Position, }
record Choice { x: Axis, y: Axis, point: Point, }
record Native { at: Position, limits: Position, radius: f64, }

fn portion(raw: json.Json) -> Position {
    let items = value.items(raw);
    return Position { x: value.number(items.at_or(0, json.null())), y: value.number(items.at_or(1, json.null())) };
}

fn number(n: f64) -> json.Json {
    return decimal.finite(n).fold(fn(token) => json.number(token), fn(unit) => json.null());
}

fn pair(point: Position) -> json.Json { return json.array([number(point.x), number(point.y)]); }

fn absolute(n: f64) -> f64 { return if n < 0.0f64 { -n } else { n }; }

fn whole(n: f64, low: f64, high: f64) -> Bool { return n >= low && n <= high && n == trunc(n); }

fn coordinate(n: f64) -> Bool {
    return n >= -8192.0f64 && n <= 8192.0f64 && n * 2.0f64 == trunc(n * 2.0f64);
}

fn valid(scope: List<String>, raw: json.Json, progress: Result<List<String>, String>) -> Result<List<String>, String> {
    let ids = progress?;
    let row = value.fields(raw);
    let id = value.text(value.get(row, "id"));
    let kind = value.text(value.get(row, "kind"));
    let guide_frame = value.get(row, "frame");
    let label = value.get(row, "label");
    let base = ["id", "kind", "frame", "label", "at"];
    let allowed = if kind == "grid" { base.concat(["step"]) } else { if kind == "axis" { base.concat(["axis"]) } else { base } };
    if !commands.includes(["grid", "axis", "pivot", "registration"], kind) ||
        !brush.stable_id(id) || commands.includes(ids, id) || !value.only(row, allowed) ||
        (value.has(row, "frame") && !commands.includes(scope, value.text(guide_frame))) ||
        (value.has(row, "label") && !commands.non_blank(value.text(label))) {
        return Err("Pixel guides need unique IDs, known kinds, and an optional known frame");
    }
    let at = value.get(row, "at");
    let point = portion(at);
    if kind == "axis" {
        if !commands.includes(["x", "y"], value.text(value.get(row, "axis"))) || !coordinate(value.number(at)) {
            return Err("An axis guide needs x or y and a native coordinate");
        }
    } else {
        let two = length(value.items(at)) == 2;
        if kind == "grid" {
            let spacing = value.get(row, "step");
            let step = portion(spacing);
            if !two || !whole(point.x, -8192.0f64, 8192.0f64) || !whole(point.y, -8192.0f64, 8192.0f64) ||
                length(value.items(spacing)) != 2 || !whole(step.x, 1.0f64, 8192.0f64) || !whole(step.y, 1.0f64, 8192.0f64) {
                return Err("A grid guide needs an integer origin and positive integer steps");
            }
        } else {
            if !two || !coordinate(point.x) || !coordinate(point.y) {
                return Err("Pivots and registration guides need a pair of native coordinates");
            }
        }
    }
    return Ok(ids.concat([id]));
}

fn validate(doc: List<json.Member>, frames: List<String>) -> Result<Unit, String> {
    if !value.has(doc, "guides") { return Ok(()); }
    let ready = prepare(value.get(doc, "guides"), frames)?;
    return Ok(());
}

fn prepare(raw: json.Json, frames: List<String>) -> Result<List<json.Json>, String> {
    let error = "Pixel guides need a list of at most 256 entries";
    let guides = json.elements(raw).map_err(fn(issue) => error)?;
    if length(guides) > 256 { return Err(error); }
    let start: Result<List<String>, String> = Ok([]);
    let unique = foldl(guides, start, fn(row) => fn(out) => valid(frames, row, out))?;
    return Ok(guides);
}

fn id(row: json.Json) -> String { return value.text(value.get(value.fields(row), "id")); }

fn edit_error(issue: String) -> json.Json { return history.problem("invalid-edit", issue, []); }

fn edit(source: json.Json, frames: List<String>, operation: json.Json) -> Result<json.Json, json.Json> {
    let message = "A guide edit needs an upsert or remove operation";
    let options = json.members(operation).map_err(fn(issue) => edit_error(message))?;
    if !value.only(options, ["upsert", "remove"]) { return Err(edit_error(message)); }
    let additions = json.lookup(options, "upsert").fold(fn(raw) => raw, fn(unit) => json.array([]));
    let changes = prepare(additions, frames).map_err(fn(issue) => edit_error(issue))?;
    let ids = changes.map(fn(row) => id(row));
    let invalid = "Guide edits need unique IDs and may update or remove each guide once";
    let raw = json.lookup(options, "remove").fold(fn(raw) => raw, fn(unit) => json.array([]));
    let removals = json.elements(raw).map_err(fn(issue) => edit_error(invalid))?;
    let remove = removals.map(fn(row) => value.text(row));
    let checked = foldl(remove, ids, fn(name) => fn(used) =>
        if !brush.stable_id(name) || commands.includes(used, name) { used } else { used.concat([name]) });
    if length(checked) != length(ids) + length(remove) || length(checked) == 0 { return Err(edit_error(invalid)); }
    return update(source, changes, remove);
}

fn update(source: json.Json, changes: List<json.Json>, remove: List<String>) -> Result<json.Json, json.Json> {
    let doc = value.fields(source);
    let old = value.items(value.get(doc, "guides"));
    let known = old.map(fn(row) => id(row));
    let missing = foldl(remove, "", fn(name) => fn(found) =>
        if found != "" || commands.includes(known, name) { found } else { name });
    if missing != "" {
        return Err(history.problem("missing-guide", string_concat("Unknown pixel guide ", missing),
            [history.member("guide", json.text(missing))]));
    }
    let updates = changes.map(fn(row) => history.member(id(row), row));
    let retained = old.filter(fn(row) => !commands.includes(remove, id(row)))
        .map(fn(row) => json.lookup(updates, id(row)).fold(fn(replacement) => replacement, fn(unit) => row));
    let added = changes.filter(fn(row) => !commands.includes(known, id(row)));
    let next = retained.concat(added);
    if length(next) > 256 { return Err(edit_error("Pixel guides need a list of at most 256 entries")); }
    let field = history.member("guides", json.array(next));
    return Ok(json.object(if value.has(doc, "guides") { doc.map(fn(row) => if row.key == "guides" { field } else { row }) }
        else { doc.concat([field]) }));
}

fn lexical(a: String, b: String) -> Bool {
    let n = string_byte_len(a);
    let m = string_byte_len(b);
    let shorter = if n < m { n } else { m };
    let index: u32 = repeat_until(shorter, 0, fn(i) => byte(a, i) != byte(b, i), fn(step) => fn(i) => i + 1);
    return if index == shorter { n < m } else { byte(a, index) < byte(b, index) };
}

fn byte(text: String, index: u32) -> u32 {
    return string_byte_at(text, index).fold(fn(n) => n, fn(unit) => 0);
}

fn closest(previous: Axis, id: String, priority: u32, on: f64, origin: f64, limit: f64, radius: f64) -> Axis {
    let distance = absolute(on - origin);
    if distance > radius || on < 0.0f64 || on > limit { return previous; }
    let better_tie = priority < previous.priority || (priority == previous.priority &&
        (lexical(id, previous.id) || (id == previous.id && on < previous.value)));
    if previous.id == "" || distance < previous.distance || (distance == previous.distance && better_tie) {
        return Axis { id: id, distance: distance, value: on, priority: priority };
    }
    return previous;
}

fn clamp(n: f64, low: f64, high: f64) -> f64 { return value.max(low, value.min(n, high)); }

fn grid(previous: Axis, id: String, origin: f64, step: f64, requested: f64, limit: f64, radius: f64) -> Axis {
    let first = ceil(-origin / step);
    let last = floor((limit - origin) / step);
    if first > last { return previous; }
    let near = floor((requested - origin) / step);
    let left = closest(previous, id, 1, origin + clamp(near, first, last) * step, requested, limit, radius);
    return closest(left, id, 1, origin + clamp(near + 1.0f64, first, last) * step, requested, limit, radius);
}

fn distance(x: f64, y: f64) -> f64 {
    let scale = value.max(absolute(x), absolute(y));
    if scale == 0.0f64 { return 0.0f64; }
    let a = x / scale;
    let b = y / scale;
    return sqrt(a * a + b * b) * scale;
}

fn anchor(view: Native, previous: Point, at: Position, id: String) -> Point {
    if at.x < 0.0f64 || at.y < 0.0f64 || at.x > view.limits.x || at.y > view.limits.y { return previous; }
    let x = at.x - view.at.x;
    let y = at.y - view.at.y;
    if absolute(x) > view.radius || absolute(y) > view.radius { return previous; }
    let d = distance(x, y);
    if d <= view.radius && (previous.id == "" || d < previous.distance || (d == previous.distance && lexical(id, previous.id))) {
        return Point { id: id, distance: d, at: at };
    }
    return previous;
}

fn route(view: Native, choice: Choice, raw: json.Json) -> Choice {
    let row = value.fields(raw);
    let kind = value.text(value.get(row, "kind"));
    let id = value.text(value.get(row, "id"));
    let at = value.get(row, "at");
    if kind == "axis" {
        let coordinate = value.number(at);
        if value.text(value.get(row, "axis")) == "x" {
            return Choice { ..choice, x: closest(choice.x, id, 0, coordinate, view.at.x, view.limits.x, view.radius) };
        }
        return Choice { ..choice, y: closest(choice.y, id, 0, coordinate, view.at.y, view.limits.y, view.radius) };
    }
    let point = portion(at);
    if kind == "grid" {
        let step = portion(value.get(row, "step"));
        return Choice { ..choice,
            x: grid(choice.x, id, point.x, step.x, view.at.x, view.limits.x, view.radius),
            y: grid(choice.y, id, point.y, step.y, view.at.y, view.limits.y, view.radius) };
    }
    return Choice { ..choice, point: anchor(view, choice.point, point, id) };
}

fn hit(axis: Axis, name: String) -> List<json.Member> {
    return if axis.id == "" { [] } else { [history.member(name, json.text(axis.id))] };
}

fn native(n: f64, limit: f64) -> f64 {
    let base = floor(n);
    return clamp(if n - base >= 0.5f64 { base + 1.0f64 } else { base }, 0.0f64, limit);
}

fn report(view: Native, rows: List<json.Json>) -> List<json.Member> {
    let start = Axis { id: "", distance: 0.0f64, value: 0.0f64, priority: 0 };
    let initial = Choice { x: Axis { ..start, value: view.at.x }, y: Axis { ..start, value: view.at.y },
        point: Point { id: "", distance: 0.0f64, at: view.at } };
    let found = foldl(rows, initial, fn(row) => fn(choice) => route(view, choice, row));
    let picked = found.point.id != "";
    let position = if picked { found.point.at } else { Position { x: found.x.value, y: found.y.value } };
    let hits = if picked { [history.member("point", json.text(found.point.id))] } else { hit(found.x, "x").concat(hit(found.y, "y")) };
    return [history.member("at", pair(Position { x: native(position.x, view.limits.x), y: native(position.y, view.limits.y) })),
        history.member("position", pair(position)), history.member("hits", json.object(hits))];
}

fn snap(source: json.Json, art: frame.Artwork, revision: String, point: json.Json, options: json.Json) -> Result<json.Json, String> {
    let settings = value.fields(options);
    let id = assets.scope_arg(settings, "frame")?;
    let scope = frame.resolve(art, id, None, None)?;
    let radius = json.lookup(settings, "radius").fold(fn(raw) => value.number(raw), fn(unit) => 1.0f64);
    let at = portion(point);
    if length(value.items(point)) != 2 || !is_finite(at.x) || !is_finite(at.y) ||
        !is_finite(radius) || radius < 0.0f64 || radius > 32.0f64 {
        return Err("Snap needs native dimensions, a finite point and a radius from 0 to 32 pixels");
    }
    let view = Native { at: at, limits: Position { x: f64_from_u32(art.grid.width - 1), y: f64_from_u32(art.grid.height - 1) }, radius: radius };
    let doc = value.fields(source);
    return Ok(json.object(inspection.observed_frame(doc, scope.frame, revision).concat([history.member("input", point)])
        .concat(report(view, assets.scoped_rows(doc, "guides", scope.frame, true)))));
}
