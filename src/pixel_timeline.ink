module StudioPixelTimeline;

import "std:json" as json;
import "std:binary64_decimal" as decimal;
import "pixel_brush.ink" as brush;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_inspect.ink" as inspection;
import "pixel_labels.ink" as labels;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Time { elapsed: f64, rows: Buffer<json.Json>, }
record IndexedCel { frame: String, layer: String, index: u32, }
record Rows { slots: Map<u64, List<IndexedCel>>, layers: Buffer<json.Json>, }
record Group { id: String, source: json.Json, holds: List<json.Json>, }
record Playback { first: u32, last: u32, reverse: Bool, bounce: Bool, loop: Bool, passes: u32, }

fn number(n: f64) -> json.Json {
    return decimal.finite(n).fold(fn(token) => json.number(token), fn(unit) => json.null());
}

fn append_frame(raw: json.Json, timing: Time) -> Time {
    let fields = value.fields(raw);
    let id = value.get(fields, "id");
    let duration = value.get(fields, "durationMs");
    let elapsed = timing.elapsed + value.number(duration);
    let label = if value.has(fields, "label") { value.get(fields, "label") } else { id };
    let row = json.object([history.member("id", id), history.member("label", label),
        history.member("startMs", number(timing.elapsed)), history.member("durationMs", duration),
        history.member("endMs", number(elapsed))]);
    return Time { elapsed: elapsed, rows: timing.rows.push(row) };
}

fn zero_offset() -> json.Json { return json.array([json.number("0"), json.number("0")]); }

fn offset(fields: List<json.Member>) -> json.Json {
    return json.lookup(fields, "offset").fold(fn(raw) => raw, fn(unit) => zero_offset());
}

fn optional(fields: List<json.Member>, key: String) -> List<json.Member> {
    return json.lookup(fields, key).fold(fn(raw) => [history.member(key, raw)], fn(unit) => []);
}

fn cell_key(id: String, layer: String) -> u64 { return labels.id_hash(string_concat(id, string_concat("/", layer))); }

fn cells_index(cels: List<frame.Cel>) -> Map<u64, List<IndexedCel>> {
    var slots: Map<u64, List<IndexedCel>> = Map.empty();
    var i: u32 = 0;
    for cel in cels {
        let key = cell_key(cel.frame, cel.layer);
        let stored = slots.get_or(key, []);
        slots = slots.set(key, stored.concat([IndexedCel { frame: cel.frame, layer: cel.layer, index: i }]));
        i = i + 1;
    }
    return slots;
}

fn find_index(found: List<IndexedCel>, frame_id: String, layer: String) -> u32 {
    return fold_until(found, 4294967295, fn(row) => fn(i) => i != 4294967295,
        fn(row) => fn(i) => if row.frame == frame_id && row.layer == layer { row.index } else { i });
}

fn timeline_cell(id: String, cel: frame.Cel, source: String, layer_spec: json.Json) -> json.Json {
    let frame_field = history.member("frame", json.text(id));
    if cel.id == "" {
        return json.object([frame_field, history.member("state", json.text("empty")), history.member("cel", json.null())]);
    }
    let holding = value.has(cel.fields, "hold");
    let marks = length(value.items(value.get(cel.fields, "marks"))) != 0 || length(cel.runs) != 0 || cel.run_plane != 0;
    let state = if holding { "hold" } else { if value.has(cel.fields, "slots") || cel.plane != 0 || marks { "cel" } else { "blank" } };
    let placed = frame.placement(layer_spec, cel);
    let effective = json.array([number(f64_from_i32(placed.x)), number(f64_from_i32(placed.y))]);
    let details = [history.member("offset", offset(cel.fields)), history.member("effectiveOffset", effective)]
        .concat(optional(cel.fields, "opacity"));
    let hold = if holding { optional(cel.fields, "hold").concat([history.member("source", json.text(source))]) } else { [] };
    return json.object([frame_field, history.member("state", json.text(state)), history.member("cel", json.text(cel.id))]
        .concat(optional(cel.fields, "label")).concat(details).concat(hold));
}

fn timeline_layer(art: frame.Artwork, ordinal: u32, row: frame.Layer, cells: List<json.Json>) -> json.Json {
    let fields = value.fields(art.inputs.at_or(ordinal, json.null()));
    let kind = if row.kind == "" { "paint" } else { row.kind };
    let id = json.text(row.id);
    let name = if value.has(fields, "label") { value.get(fields, "label") } else { id };
    return json.object([history.member("id", id), history.member("label", name), history.member("kind", json.text(kind)),
        history.member("locked", json.boolean(kind == "reference" || inspection.effective_lock(art, ordinal)))]
        .concat(optional(fields, "parent")).concat([history.member("offset", offset(fields)), history.member("cells", json.array(cells))]));
}

fn locate(cel: frame.Cel) -> json.Json {
    return json.object([history.member("cel", json.text(cel.id)), history.member("frame", json.text(cel.frame)),
        history.member("layer", json.text(cel.layer))]);
}

fn append_hold(groups: List<Group>, cels: List<frame.Cel>, cel: frame.Cel, source: String) -> List<Group> {
    if !value.has(cel.fields, "hold") { return groups; }
    let raw = locate(cel);
    let present = fold_until(groups, false, fn(group) => fn(found) => found,
        fn(group) => fn(found) => group.id == source);
    if !present {
        let root = frame.find_cel(cels, source);
        return groups.concat([Group { id: source, source: locate(root), holds: [raw] }]);
    }
    return groups.map(fn(group) => if group.id == source { Group { ..group, holds: group.holds.concat([raw]) } } else { group });
}

fn link_groups(cels: List<frame.Cel>, origins: List<String>) -> List<json.Json> {
    let blank: List<Group> = [];
    let held = cels.map_indexed(fn(i) => fn(row) => i).filter(fn(i) => origins.at_or(i, "") != "");
    let groups = foldl(held, blank, fn(i) => fn(out) =>
        append_hold(out, cels, cels.at_or(i, frame.no_cel()), origins.at_or(i, "")));
    return groups.map(fn(group) => json.object([history.member("source", group.source), history.member("holds", json.array(group.holds))]));
}

fn tag_error(id: String, message: String, qualified: Bool) -> String {
    return if qualified { string_concat("Playback tag ", string_concat(id, string_concat(": ", message))) }
        else { message };
}

fn planned(row: List<json.Member>, ids: List<String>, durations: List<f64>, id: String, qualified: Bool) -> Result<json.Json, String> {
    let direction = json.lookup(row, "direction").fold(fn(raw) => value.text(raw), fn(unit) => "forward");
    let has_repeat = value.has(row, "repeat");
    let repeats = value.word(value.get(row, "repeat"), 65535);
    let loop = value.flag(row, "loop", !has_repeat);
    let loop_ok = json.lookup(row, "loop").fold(fn(v) => json.as_boolean(v).fold(fn(b) => true, fn(issue) => false), fn(unit) => true);
    let label_ok = json.lookup(row, "label").fold(fn(v) => commands.non_blank(value.text(v)), fn(unit) => true);
    if !brush.stable_id(id) || !loop_ok || !label_ok || (has_repeat && (loop || repeats == 0 || repeats > 65535)) ||
        !commands.includes(["forward", "reverse", "ping-pong", "ping-pong-reverse"], direction) ||
        !value.only(row, ["id", "label", "start", "end", "direction", "loop", "repeat"]) {
        return Err("Playback tags need unique IDs and valid labels, directions and repeat settings");
    }
    let first = selection.named_slot(ids, value.text(value.get(row, "start")));
    let last = selection.named_slot(ids, value.text(value.get(row, "end")));
    if first >= length(ids) || last >= length(ids) || first > last {
        return Err(string_concat("Playback tag ", string_concat(id, " needs known start and end frames in timeline order")));
    }
    let reverse = direction == "reverse" || direction == "ping-pong-reverse";
    let bounce = first != last && (direction == "ping-pong" || direction == "ping-pong-reverse");
    let passes: u32 = if has_repeat { repeats } else { if bounce { 2 } else { 1 } };
    return render_tag(row, ids, durations, direction, Playback { first: first, last: last,
        reverse: reverse, bounce: bounce, loop: loop, passes: passes }, qualified);
}

fn exposure_pass(plan: Playback, pass: u32, order: Buffer<u32>) -> Buffer<u32> {
    let width = plan.last - plan.first + 1;
    let start: u32 = if plan.bounce && pass != 0 { 1 } else { 0 };
    let end = if plan.bounce && plan.loop && pass + 1 == plan.passes { width - 1 } else { width };
    let backward = plan.reverse != (plan.bounce && rem_or(pass, 2, 0) != 0);
    return repeat_until(end - start, order, fn(out) => false, fn(i) => fn(out) =>
        out.push(if backward { plan.last - i - start } else { plan.first + i + start }));
}

fn playback_duration(plan: Playback, durations: List<f64>) -> f64 {
    let width = plan.last - plan.first + 1;
    if !plan.bounce {
        let span = foldl(durations.drop(plan.first).take(width), 0.0f64, fn(n) => fn(sum) => sum + n);
        return span * f64_from_u32(plan.passes);
    }
    let reversed_last = plan.reverse != (rem_or(plan.passes - 1, 2, 0) != 0);
    let joined = quot_or(plan.passes, 2, 0);
    let other = quot_or(plan.passes - 1, 2, 0);
    let first_joins = if plan.reverse { joined } else { other };
    let last_joins = if plan.reverse { other } else { joined };
    let first = plan.passes - first_joins - (if plan.loop && reversed_last { 1 } else { 0 });
    let last = plan.passes - last_joins - (if plan.loop && !reversed_last { 1 } else { 0 });
    let middle = foldl(durations.drop(plan.first + 1).take(width - 2), 0.0f64, fn(n) => fn(sum) => sum + n);
    return middle * f64_from_u32(plan.passes) + durations.at_or(plan.first, 0.0f64) * f64_from_u32(first) +
        durations.at_or(plan.last, 0.0f64) * f64_from_u32(last);
}

fn render_tag(row: List<json.Member>, ids: List<String>, durations: List<f64>, direction: String, plan: Playback,
    validate_only: Bool) -> Result<json.Json, String> {
    let width = plan.last - plan.first + 1;
    let count = width * plan.passes - (if plan.bounce { plan.passes - 1 + (if plan.loop { 1 } else { 0 }) } else { 0 });
    let id = value.text(value.get(row, "id"));
    if value.has(row, "repeat") && count > 65536 {
        return Err(tag_error(id, "A finite playback tag can contain up to 65,536 frame exposures", validate_only));
    }
    let duration = playback_duration(plan, durations);
    if duration > 9007199254740991.0f64 {
        return Err(tag_error(id, "Playback steps need positive durations within the safe time range", validate_only));
    }
    if validate_only { return Ok(json.object(row)); }
    let start: Buffer<u32> = Buffer.empty();
    let order = repeat_until(plan.passes, start, fn(out) => false, fn(i) => fn(out) => exposure_pass(plan, i, out)).freeze();
    let fields = row.filter(fn(item) => item.key != "direction" && item.key != "loop");
    return Ok(json.object(fields.concat([history.member("direction", json.text(direction)), history.member("loop", json.boolean(plan.loop)),
        history.member("first", inspection.number(plan.first)), history.member("last", inspection.number(plan.last)),
        history.member("durationMs", number(duration)), history.member("order", json.array(order.map(fn(i) => json.text(ids.at_or(i, "")))))])));
}

fn append_tag(ids: List<String>, durations: List<f64>, raw: json.Json, progress: Result<List<json.Json>, String>, qualified: Bool)
    -> Result<List<json.Json>, String> {
    let before = progress?;
    let row = json.members(raw).map_err(fn(issue) => "Playback tags need unique IDs and valid labels, directions and repeat settings")?;
    let id = value.get(row, "id");
    if fold_until(before, false, fn(prior) => fn(found) => found,
        fn(prior) => fn(found) => value.get(value.fields(prior), "id") == id) {
        return Err("Playback tags need unique IDs and valid labels, directions and repeat settings");
    }
    let tag = planned(row, ids, durations, value.text(id), qualified)?;
    return Ok(before.concat([tag]));
}

fn describe_tags(doc: List<json.Member>, ids: List<String>, durations: List<f64>, qualified: Bool) -> Result<List<json.Json>, String> {
    if !value.has(doc, "tags") { return Ok([]); }
    let issue = "Use a list of up to 128 playback tags";
    let tags = json.elements(value.get(doc, "tags")).map_err(fn(error) => issue)?;
    if length(tags) > 128 { return Err(issue); }
    let initial: Result<List<json.Json>, String> = Ok([]);
    return foldl(tags, initial, fn(raw) => fn(out) => append_tag(ids, durations, raw, out, qualified));
}

fn indexed_cell(cels: List<frame.Cel>, origins: List<String>, id: String, spec: json.Json, index: u32) -> json.Json {
    return timeline_cell(id, cels.at_or(index, frame.no_cel()), origins.at_or(index, ""), spec);
}

fn append_layer(art: frame.Artwork, origins: List<String>, ordinal: u32, out: Rows) -> Rows {
    let row = art.layers.at_or(ordinal, frame.empty_layer());
    let spec = art.inputs.at_or(ordinal, json.null());
    let indices = art.frames.map(fn(id) => find_index(out.slots.get_or(cell_key(id, row.id), []), id, row.id));
    let cells = art.frames.map_indexed(fn(i) => fn(id) => indexed_cell(art.cels, origins, id, spec, indices.at_or(i, 4294967295)));
    return Rows { slots: out.slots, layers: out.layers.push(timeline_layer(art, ordinal, row, cells)) };
}

fn describe(source: json.Json, art: frame.Artwork, revision: String) -> Result<json.Json, String> {
    let doc = value.fields(source);
    let frames = value.items(value.get(doc, "frames"));
    let timing = foldl(frames, Time { elapsed: 0.0f64, rows: Buffer.empty() }, fn(row) => fn(out) => append_frame(row, out));
    if timing.elapsed > 9007199254740991.0f64 { return Err("Pixel timeline duration exceeds the safe millisecond range"); }
    let frame_rows = timing.rows.freeze();
    let durations = frames.map(fn(row) => value.number(value.get(value.fields(row), "durationMs")));
    let tags = describe_tags(doc, art.frames, durations, false)?;
    let origins = art.cels.map(fn(cel) => if value.has(cel.fields, "hold") { frame.resolved_cel(art.cels, cel).id } else { "" });
    let raster = art.layers.map_indexed(fn(i) => fn(row) => if row.kind == "group" { 4294967295 } else { i })
        .filter(fn(i) => i != 4294967295);
    let initial = Rows { slots: cells_index(art.cels), layers: Buffer.empty() };
    let rows = foldl(raster, initial, fn(ordinal) => fn(out) => append_layer(art, origins, ordinal, out));
    let layer_rows = rows.layers.freeze();
    let fields = [history.member("format", json.text("ink-studio/pixel-cel-timeline")), history.member("version", json.number("1")),
        history.member("revision", json.text(revision)), history.member("frames", json.array(frame_rows)),
        history.member("layers", json.array(layer_rows)), history.member("tags", json.array(tags))];
    return Ok(json.object(fields.concat(optional(doc, "directional")).concat([
        history.member("linkGroups", json.array(link_groups(art.cels, origins))), history.member("totalDurationMs", number(timing.elapsed))])));
}
