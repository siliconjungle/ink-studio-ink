module StudioPixelTimelineEdit;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_commands.ink" as commands;
import "pixel_fault.ink" as fault;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_brush_capture.ink" as labels;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_timeline.ink" as timeline;
import "pixel_values.ink" as value;

record Edit { source: json.Json, artwork: frame.Artwork, target: json.Json, changes_art: Bool, }
record FrameEdit { frames: List<json.Json>, details: List<json.Member>, drawing: String, origin: frame.Cel, }
record Address { frame_id: String, layer: frame.Layer, raw: List<json.Member>, cel: frame.Cel, }

fn member(key: String, raw: json.Json) -> json.Member { return history.member(key, raw); }
fn invalid(message: String) -> json.Json { return history.problem("invalid-edit", message, []); }

fn replace(source: json.Json, key: String, raw: json.Json) -> json.Json {
    return json.object(paint.replace(value.fields(source), key, raw));
}

fn label(row: List<json.Member>, key: String) -> String {
    return json.lookup(row, key).fold(fn(raw) => labels.label(raw), fn(unit) => "undefined");
}

fn operation_keys(tool: String) -> List<String> {
    if tool == "add-frame" { return ["type", "frame", "durationMs", "label", "before"]; }
    if tool == "duration" { return ["type", "frame", "durationMs"]; }
    if tool == "set-tag" || tool == "remove-tag" { return ["type", "tag"]; }
    if tool == "layer-offset" { return ["type", "layer", "offset"]; }
    if tool == "cel-offset" { return ["type", "frame", "layer", "offset"]; }
    if tool == "blank" || tool == "unlink" { return ["type", "frame", "layer"]; }
    if commands.includes(["duplicate", "hold", "move", "copy"], tool) { return ["type", "from", "to", "replace"]; }
    return [];
}

fn target(tool: String, details: List<json.Member>) -> json.Json {
    return json.object([member("destination", json.text("timeline")), member("kind", json.text("timeline")),
        member("tool", json.text(tool))].concat(details));
}

fn positive_duration(raw: json.Json) -> Bool {
    let n = value.number(raw);
    return n > 0.0f64 && n <= 9007199254740991.0f64 && n == floor(n);
}

fn frame_slot(frames: List<String>, op: List<json.Member>, key: String) -> Result<u32, json.Json> {
    let index = selection.named_slot(frames, value.text(value.get(op, key)));
    if index >= length(frames) {
        return Err(invalid(string_concat("Unknown pixel frame ", label(op, key))));
    }
    return Ok(index);
}

fn replace_at(rows: List<json.Json>, index: u32, raw: json.Json) -> List<json.Json> {
    return rows.map_indexed(fn(i) => fn(row) => if i == index { raw } else { row });
}

fn timing(rows: List<json.Json>) -> Result<List<json.Json>, json.Json> {
    let measured = foldl(rows, timeline.Time { elapsed: 0.0f64, rows: Buffer.empty() },
        fn(row) => fn(out) => timeline.append_frame(row, out));
    if measured.elapsed > 9007199254740991.0f64 {
        return Err(invalid("Pixel timeline duration exceeds the safe millisecond range"));
    }
    return Ok(measured.rows.freeze());
}

fn durations(rows: List<json.Json>) -> List<f64> {
    return rows.map(fn(row) => value.number(value.get(value.fields(row), "durationMs")));
}

fn retime(source: json.Json, art: frame.Artwork, frames: List<json.Json>, op: List<json.Member>) -> Result<Edit, json.Json> {
    let i = frame_slot(art.frames, op, "frame")?;
    let next = value.get(op, "durationMs");
    if !positive_duration(next) { return Err(invalid("Frame duration must be a positive integer in milliseconds")); }
    let row = frames.at_or(i, json.null());
    let after = replace_at(frames, i, replace(row, "durationMs", next));
    let measured = timing(after)?;
    let revised = replace(source, "frames", json.array(after));
    let tags = timeline.describe_tags(value.fields(revised), art.frames, durations(after), true).map_err(fn(issue) => invalid(issue))?;
    return Ok(Edit { source: revised, artwork: art, changes_art: false,
        target: target("duration", [member("frame", value.get(op, "frame")),
            member("before", value.get(value.fields(row), "durationMs")), member("after", next)]) });
}

fn add_frame(source: json.Json, art: frame.Artwork, frames: List<json.Json>, op: List<json.Member>) -> Result<Edit, json.Json> {
    let id = value.text(value.get(op, "frame"));
    let duration = value.get(op, "durationMs");
    let label_ok = !value.has(op, "label") || commands.non_blank(value.text(value.get(op, "label")));
    if !brush.stable_id(id) || !positive_duration(duration) || !label_ok || frame.known_frame(art.frames, id) {
        return Err(invalid("Add frame needs an unused ID and positive integer duration in milliseconds"));
    }
    let slot = if value.has(op, "before") { frame_slot(art.frames, op, "before") } else { Ok(length(frames)) };
    let i = slot?;
    let row = json.object([member("id", json.text(id))].concat(timeline.optional(op, "label")).concat([
        member("durationMs", duration), member("cels", json.object([]))]));
    let rows = frames.take(i).concat([row]).concat(frames.drop(i));
    let measured = timing(rows)?;
    let ids = art.frames.take(i).concat([id]).concat(art.frames.drop(i));
    let revised = replace(source, "frames", json.array(rows));
    let tags = timeline.describe_tags(value.fields(revised), ids, durations(rows), true).map_err(fn(issue) => invalid(issue))?;
    return Ok(Edit { source: revised, artwork: frame.Artwork { ..art, frames: ids }, changes_art: true,
        target: target("add-frame", [member("frame", json.text(id)), member("after", measured.at_or(i, json.null()))]) });
}

fn named(rows: List<json.Json>, id: json.Json) -> json.Json {
    return foldl(rows, json.null(), fn(row) => fn(found) =>
        if value.get(value.fields(row), "id") == id { row } else { found });
}

fn update_tag(source: json.Json, art: frame.Artwork, frames: List<json.Json>, tool: String,
    op: List<json.Member>) -> Result<Edit, json.Json> {
    let raw = value.get(op, "tag");
    let key = if tool == "set-tag" { value.get(value.fields(raw), "id") } else { raw };
    let tags = value.items(value.get(value.fields(source), "tags"));
    let before = named(tags, key);
    if tool == "remove-tag" && before == json.null() {
        return Err(history.problem("missing-tag", string_concat("Unknown playback tag ", label(op, "tag")),
            timeline.optional(op, "tag")));
    }
    let updated = if tool == "remove-tag" { tags.filter(fn(row) => value.get(value.fields(row), "id") != key) }
        else { if before == json.null() { tags.concat([raw]) } else {
            tags.map(fn(row) => if value.get(value.fields(row), "id") == key { raw } else { row })
        } };
    let revised = replace(source, "tags", json.array(updated));
    let planned = timeline.describe_tags(value.fields(revised), art.frames, durations(frames), false).map_err(fn(issue) => invalid(issue))?;
    return Ok(Edit { source: revised, artwork: art, changes_art: false,
        target: target(tool, [member("tag", key), member("before", before), member("after", named(planned, key))]) });
}

fn address(art: frame.Artwork, raw: json.Json) -> Result<Address, json.Json> {
    let message = "A timeline address needs frame and layer IDs";
    let fields = json.members(raw).map_err(fn(issue) => invalid(message))?;
    if !value.only(fields, ["frame", "layer"]) { return Err(invalid(message)); }
    let layer = resolved_layer(art, value.text(value.get(fields, "layer")));
    if layer.id == "" || layer.kind == "group" {
        return Err(invalid(string_concat("Unknown cel layer ", label(fields, "layer"))));
    }
    let index = frame_slot(art.frames, fields, "frame")?;
    let id = art.frames.at_or(index, "");
    return Ok(Address { frame_id: id, layer: layer, raw: fields, cel: frame.active_cel(art.cels, id, layer.id) });
}

fn resolved_layer(art: frame.Artwork, id: String) -> frame.Layer {
    return art.layers.at_or(frame.clip_index(art.layers, id, length(art.layers)), frame.empty_layer());
}

fn address_fields(op: List<json.Member>) -> json.Json {
    return json.object(timeline.optional(op, "frame").concat(timeline.optional(op, "layer")));
}

fn writable(art: frame.Artwork, layer: frame.Layer) -> Result<Unit, json.Json> {
    if layer.id == "" || layer.kind == "group" { return Err(invalid("Choose a layer that can contain cels")); }
    if paint.locked_layer(art.layers, layer) {
        return Err(history.problem("locked-layer", string_concat("Layer ", string_concat(layer.id, " does not accept timeline edits")),
            [member("layer", json.text(layer.id))]));
    }
    return Ok(());
}

fn position(raw: json.Json) -> Result<json.Json, json.Json> {
    let coords = value.items(raw);
    let valid = foldl(coords, length(coords) == 2, fn(v) => fn(ok) =>
        ok && value.integer(v, -1000000, 1000000).fold(fn(n) => true, fn(unit) => false));
    if !valid { return Err(invalid("Timeline offsets need a bounded integer [x,y] pair")); }
    return Ok(raw);
}

fn refresh(fields: List<json.Member>, key: String, raw: json.Json) -> List<json.Member> {
    return if raw == json.null() { fields.filter(fn(row) => row.key != key) } else { paint.replace(fields, key, raw) };
}

fn set_cell(rows: List<json.Json>, frame_id: String, layer: String, raw: json.Json) -> List<json.Json> {
    return rows.map(fn(row) => if frame.frame_name(row) == frame_id {
        replace(row, "cels", json.object(refresh(value.fields(value.get(value.fields(row), "cels")), layer, raw)))
    } else { row });
}

fn locate(row: frame.Cel) -> List<json.Member> {
    return [member("cel", json.text(row.id)), member("frame", json.text(row.frame)), member("layer", json.text(row.layer))];
}

fn placement_fields(cel: frame.Cel) -> List<json.Member> {
    return timeline.optional(cel.fields, "label").concat(timeline.optional(cel.fields, "offset"))
        .concat(timeline.optional(cel.fields, "opacity"));
}

fn independent(cel: frame.Cel, root: frame.Cel) -> List<json.Member> {
    if !value.has(cel.fields, "hold") { return cel.fields; }
    return cel.fields.filter(fn(row) => row.key != "hold").concat(timeline.optional(root.fields, "marks"))
        .concat(timeline.optional(root.fields, "slots"));
}

fn detach(art: frame.Artwork, rows: List<json.Json>, at: Address) -> Result<FrameEdit, json.Json> {
    let current = at.cel;
    let prior = value.get(current.fields, "hold");
    if prior == json.null() {
        return Err(history.problem("unlinked-cel", "Choose a cel with a hold to unlink", at.raw));
    }
    let root = frame.resolved_cel(art.cels, current);
    let direct = art.cels.filter(fn(row) => value.get(row.fields, "hold") == json.text(current.id));
    let changed = set_cell(rows, at.frame_id, at.layer.id, json.object(independent(current, root)));
    let next = foldl(direct, changed, fn(cel) => fn(out) =>
        set_cell(out, cel.frame, cel.layer, json.object(paint.replace(cel.fields, "hold", prior))));
    return Ok(FrameEdit { frames: next, drawing: current.id, origin: root, details: locate(current).concat([
        member("source", json.object(locate(root))), member("retargeted", json.array(direct.map(fn(row) => json.object(locate(row)))) )]) });
}

fn cell_edit(art: frame.Artwork, frames: List<json.Json>, tool: String, op: List<json.Member>) -> Result<FrameEdit, json.Json> {
    let at = address(art, address_fields(op))?;
    let allowed = writable(art, at.layer)?;
    if tool == "unlink" { return detach(art, frames, at); }
    let current = at.cel;
    let key = paint.choose_cel(art, frame.Scope { frame: at.frame_id, layer: at.layer.id });
    let site = [member("frame", json.text(at.frame_id)), member("layer", json.text(at.layer.id)), member("cel", json.text(key))];
    if tool == "blank" {
        let raw = json.object([member("id", json.text(key))].concat(placement_fields(current)).concat([
            member("marks", json.array([]))]));
        return Ok(FrameEdit { frames: set_cell(frames, at.frame_id, at.layer.id, raw), drawing: key,
            origin: frame.no_cel(), details: site });
    }
    if current.id == "" { return Err(history.problem("missing-cel", "Cel offset needs an existing cel", at.raw)); }
    let offset = position(value.get(op, "offset"))?;
    let raw = json.object(paint.replace(current.fields, "offset", offset));
    return Ok(FrameEdit { frames: set_cell(frames, at.frame_id, at.layer.id, raw), drawing: key, origin: current,
        details: site.concat([member("before", timeline.offset(current.fields)), member("after", offset)]) });
}

fn transfer(art: frame.Artwork, frames: List<json.Json>, tool: String, op: List<json.Member>) -> Result<FrameEdit, json.Json> {
    let from = address(art, value.get(op, "from"))?;
    let next_index = selection.named_slot(art.frames, from.frame_id) + 1;
    let destination = if tool == "duplicate" && !value.has(op, "to") {
        json.object([member("frame", json.text(art.frames.at_or(next_index, ""))), member("layer", json.text(from.layer.id))])
    } else { value.get(op, "to") };
    if from.cel.id == "" { return Err(history.problem("missing-cel", "Source timeline cell is empty", from.raw)); }
    if tool == "duplicate" && value.text(value.get(value.fields(destination), "frame")) == "" {
        return Err(invalid("Duplicate needs the next frame or an explicit destination"));
    }
    let to = address(art, destination)?;
    let allowed = writable(art, to.layer)?;
    let movable = if tool == "move" { writable(art, from.layer) } else { Ok(()) };
    let moving = movable?;
    if from.frame_id == to.frame_id && from.layer.id == to.layer.id { return Err(invalid("Choose a different destination cell")); }
    if to.cel.id != "" && !value.flag(op, "replace", false) {
        return Err(history.problem("occupied-cel", "Destination timeline cell is occupied", to.raw));
    }
    return Ok(readdress(art, frames, tool, from, to));
}

fn readdress(art: frame.Artwork, frames: List<json.Json>, tool: String, from: Address, to: Address) -> FrameEdit {
    let scope = frame.Scope { frame: to.frame_id, layer: to.layer.id };
    let key = if tool == "move" { from.cel.id } else { available_id(art, scope) };
    let root = frame.resolved_cel(art.cels, from.cel);
    let original = if tool == "move" { from.cel } else { root };
    let raw = if tool == "hold" {
        [member("id", json.text(key)), member("hold", json.text(root.id))].concat(placement_fields(from.cel))
    } else { paint.replace(if tool == "move" { from.cel.fields } else { independent(from.cel, root) }, "id", json.text(key)) };
    let rows = if tool == "move" { set_cell(frames, from.frame_id, from.layer.id, json.null()) } else { frames };
    let details = [member("from", json.object(from.raw.concat([member("cel", json.text(from.cel.id))]))),
        member("to", json.object(to.raw.concat([member("cel", json.text(key))])))];
    let replaced: List<json.Member> = if to.cel.id == "" { [] } else { [member("replaced", json.text(to.cel.id))] };
    return FrameEdit { frames: set_cell(rows, to.frame_id, to.layer.id, json.object(raw)), drawing: key,
        origin: if tool == "hold" { frame.no_cel() } else { original },
        details: details.concat(replaced).concat(timeline.optional(raw, "hold")) };
}

fn available_id(art: frame.Artwork, scope: frame.Scope) -> String {
    let base = paint.default_id(scope);
    if frame.location(art.locations, base).id == "" { return base; }
    return repeat_until(length(art.locations) + 1, "", fn(id) => id != "",
        fn(i) => fn(id) => paint.unused_cel(art.locations, scope, i + 2));
}

fn restore_drawing(cel: frame.Cel, before: frame.Cel) -> frame.Cel {
    return frame.Cel { ..cel, runs: before.runs, prepared: before.prepared, plane: before.plane, run_plane: before.run_plane };
}

fn art_edit(source: json.Json, art: frame.Artwork, changed: FrameEdit, tool: String) -> Edit {
    let slots = timeline.cells_index(art.cels);
    let ordered = frame.all_cels(changed.frames);
    let indices = ordered.map(fn(cel) => timeline.find_index(slots.get_or(timeline.cell_key(cel.frame, cel.layer), []),
        cel.frame, cel.layer));
    let cels = ordered.map_indexed(fn(i) => fn(cel) => restore_drawing(cel, if cel.id == changed.drawing { changed.origin }
        else { art.cels.at_or(indices.at_or(i, 4294967295), frame.no_cel()) }));
    let revised = frame.Artwork { ..art, cels: cels,
        locations: cels.map(fn(row) => frame.Location { id: row.id, frame: row.frame, layer: row.layer }) };
    return Edit { source: replace(source, "frames", json.array(changed.frames)), artwork: revised, changes_art: true,
        target: target(tool, changed.details) };
}

fn move_layer(source: json.Json, art: frame.Artwork, op: List<json.Member>) -> Result<Edit, json.Json> {
    let layer = resolved_layer(art, value.text(value.get(op, "layer")));
    let allowed = writable(art, layer)?;
    let next = position(value.get(op, "offset"))?;
    let i = frame.clip_index(art.layers, layer.id, length(art.layers));
    let before = art.inputs.at_or(i, json.null());
    let rows = replace_at(art.inputs, i, replace(before, "offset", next));
    return Ok(Edit { source: replace(source, "layers", json.array(rows)), artwork: frame.Artwork { ..art, inputs: rows },
        changes_art: true, target: target("layer-offset", [member("layer", json.text(layer.id)),
            member("before", timeline.offset(value.fields(before))), member("after", next)]) });
}

fn protected_problem(issue: fault.Fault) -> json.Json {
    if issue.code != "protected-pixel" { return invalid(issue.message); }
    let at = issue.at.fold(fn(p) => json.array([json.number(frame.decimal(p.x)), json.number(frame.decimal(p.y))]),
        fn(unit) => json.null());
    return history.problem(issue.code, issue.message, [member("frame", json.text(issue.frame_id)),
        member("detail", json.text(issue.detail)), member("at", at)]);
}

fn check_protection(source: json.Json, art: frame.Artwork, next: frame.Artwork) -> Result<Unit, json.Json> {
    let details = paint.protections(source, art).map_err(fn(issue) => invalid(issue))?;
    if length(details) == 0 { return Ok(()); }
    let initial: Result<Unit, json.Json> = Ok(());
    return repeat_until(length(art.frames), initial, fn(out) => out.fold(fn(unit) => false, fn(issue) => true),
        fn(i) => fn(out) => paint.compare_frame(art, next, i, paint.active_details(details, i))
            .map_err(fn(issue) => protected_problem(issue)));
}

fn apply(source: json.Json, art: frame.Artwork, operation: json.Json) -> Result<Edit, json.Json> {
    let message = "Choose add-frame, duration, set-tag, remove-tag, set-directional, set-tilemap, place-tiles, make-local-variant, reuse-exact-tile, layer-offset, cel-offset, blank, duplicate, hold, unlink, move, copy, edit-cels, or write-cels";
    let op = json.members(operation).map_err(fn(issue) => invalid(message))?;
    let tool = value.text(value.get(op, "type"));
    let keys = operation_keys(tool);
    let replace_ok = json.lookup(op, "replace").fold(fn(raw) =>
        json.as_boolean(raw).fold(fn(b) => true, fn(issue) => false), fn(unit) => true);
    if length(keys) == 0 || !value.only(op, keys) || !replace_ok { return Err(invalid(message)); }
    let frames = value.items(value.get(value.fields(source), "frames"));
    if tool == "duration" { return retime(source, art, frames, op); }
    if tool == "add-frame" { return add_frame(source, art, frames, op); }
    if tool == "set-tag" || tool == "remove-tag" { return update_tag(source, art, frames, tool, op); }
    if tool == "layer-offset" { return move_layer(source, art, op); }
    let authored = paint.authored_cels(source, art.cels.filter(fn(cel) => length(cel.runs) != 0));
    let drawn = value.items(value.get(value.fields(authored), "frames"));
    let outcome = if tool == "blank" || tool == "cel-offset" || tool == "unlink" { cell_edit(art, drawn, tool, op) }
        else { transfer(art, drawn, tool, op) };
    let changed = outcome?;
    return Ok(art_edit(authored, art, changed, tool));
}
