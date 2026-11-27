module StudioPixelCelBatch;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_capture.ink" as labels;
import "pixel_cel_cleanup.ink" as cleanup;
import "pixel_drawing_grid.ink" as grid;
import "pixel_fault.ink" as fault;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_raster.ink" as raster;
import "pixel_rgba_edit.ink" as rgba;
import "pixel_selection.ink" as selection;
import "pixel_timeline.ink" as timeline;
import "pixel_values.ink" as value;

record Edit { source: json.Json, artwork: frame.Artwork, target: json.Json, changed: Bool, }
record Settings { kind: String, swap: List<i32>, x: i32, y: i32, erase: Bool, cleanup: List<json.Member>, }
record Explicit { cel: String, writes: List<rgba.Write>, }
record Target { frame: String, ordinal: u32, layers: List<frame.Layer>, selection: paint.Constraint, }
record FramePlan { target: json.Json, edited: List<frame.Cel>, count: u32, }
record LayerPlan { target: json.Json, edited: List<frame.Cel>, count: u32, }
record Partition { original: frame.Cel, drawing: frame.Cel, keeper: String, }
record Linked { edits: List<frame.Cel>, changes: List<json.Json>, }
record Group { before: rgba.Write, after: rgba.Write, first: u32, last: u32, }
record Groups { index: Map<u32, u32>, rows: Buffer<Group>, next: Buffer<u32>, ordinal: u32, }
record GroupSites { cursor: u32, sites: Buffer<u32>, }

fn member(key: String, raw: json.Json) -> json.Member { return history.member(key, raw); }
fn property(name: String, raw: String) -> json.Member { return member(name, json.text(raw)); }
fn problem(code: String, message: String, fields: List<json.Member>) -> json.Json {
    return history.problem(code, message, fields);
}
fn invalid(message: String) -> json.Json { return problem("invalid-edit", message, []); }
fn num(n: u32) -> json.Json { return timeline.number(f64_from_u32(n)); }
fn signed(n: i32) -> json.Json { return timeline.number(f64_from_i32(n)); }
fn at(g: mask.Grid, p: u32) -> json.Json {
    let point = fault.position(g, p);
    return json.array([num(point.x), num(point.y)]);
}
fn here(cel: frame.Cel) -> List<json.Member> {
    return [property("frame", cel.frame), property("layer", cel.layer), property("cel", cel.id)];
}
fn contextual(issue: json.Json, cel: frame.Cel) -> json.Json {
    let fields = value.fields(issue).filter(fn(row) => row.key != "frame" && row.key != "layer" && row.key != "cel");
    return json.object(fields.concat(here(cel)));
}
fn object(raw: json.Json, keys: List<String>, message: String) -> Result<List<json.Member>, json.Json> {
    let fields = json.members(raw).map_err(fn(issue) => invalid(message))?;
    if !value.only(fields, keys) { return Err(invalid(message)); }
    return Ok(fields);
}
fn text_in(fields: List<json.Member>, key: String) -> String { return value.text(value.get(fields, key)); }
fn cel_name(id: String) -> Bool {
    return string_find(id, "/", 0).fold(fn(p) =>
        brush.stable_id(slice(id, 0, p)) && brush.stable_id(slice(id, p + 1, string_byte_len(id))),
        fn(unit) => brush.stable_id(id));
}
fn distinct(rows: List<String>, cel: Bool) -> Bool {
    if length(rows) == 0 { return false; }
    let checked = rows.map_indexed(fn(i) => fn(id) => valid_unique(rows, id, i, cel));
    return foldl(checked, true, fn(valid) => fn(out) => out && valid);
}

fn valid_unique(ids: List<String>, id: String, i: u32, cel: Bool) -> Bool {
    let valid = if cel { cel_name(id) } else { brush.stable_id(id) };
    return valid && selection.named_slot(ids, id) == i;
}

fn blank_settings(kind: String) -> Settings { return Settings { kind: kind, swap: [], x: 0, y: 0, erase: false, cleanup: [] }; }

fn palette_swap(art: frame.Artwork, fields: List<json.Member>) -> Result<Settings, json.Json> {
    let map = value.fields(value.get(fields, "map"));
    if length(map) == 0 { return Err(invalid("Palette swap needs a map of existing swatch IDs")); }
    let checked = map.map(fn(row) => swap_pair(art.ids, row));
    if length(checked.filter(fn(row) => row.y < 0)) != 0 {
        return Err(invalid("Palette swap entries need two distinct existing swatches"));
    }
    let blank: Buffer<i32> = buffer_fill(length(art.ids), -1);
    let swaps = foldl(checked, blank, fn(row) => fn(out) => out.set(grid.unsigned(row.x), row.y)).freeze();
    return Ok(Settings { ..blank_settings("palette-swap"), swap: swaps });
}

fn swap_pair(ids: List<String>, row: json.Member) -> Vec2<i32> {
    let before = selection.find_swatch(ids, row.key);
    let after = selection.find_swatch(ids, value.text(row.value));
    return vec2(before, if before < 0 || before == after { -1 } else { after });
}

fn nudge_settings(fields: List<json.Member>) -> Result<Settings, json.Json> {
    let offset = value.items(value.get(fields, "offset"));
    let issue = invalid("Nudge needs a whole-pixel [x,y] offset within ±4096");
    if length(offset) != 2 { return Err(issue); }
    let x = value.integer(offset.at_or(0, json.null()), -4096, 4096);
    let y = value.integer(offset.at_or(1, json.null()), -4096, 4096);
    return x.fold(fn(dx) => y.fold(fn(dy) => Ok(Settings { ..blank_settings("nudge"), x: dx, y: dy }),
        fn(unit) => Err(issue)), fn(unit) => Err(issue));
}

fn settings(art: frame.Artwork, operation: List<json.Member>) -> Result<Settings, json.Json> {
    let message = "Choose a palette-swap, nudge, mask, or cleanup for the selected cels";
    let edit = value.fields(value.get(operation, "edit"));
    let kind = text_in(edit, "type");
    if !value.only(operation, ["type", "scope", "edit"]) { return Err(invalid(message)); }
    if kind == "palette-swap" && value.only(edit, ["type", "map"]) { return palette_swap(art, edit); }
    if kind == "nudge" && value.only(edit, ["type", "offset"]) { return nudge_settings(edit); }
    if kind == "cleanup" && value.only(edit, ["type", "kind", "mode", "at", "swatch", "maxChanges"]) {
        return Ok(Settings { ..blank_settings(kind), cleanup: edit });
    }
    if kind == "mask" && value.only(edit, ["type", "mode"]) {
        let mode = if value.has(edit, "mode") { text_in(edit, "mode") } else { "keep" };
        if mode != "keep" && mode != "erase" { return Err(invalid("Choose mask mode keep or erase")); }
        return Ok(Settings { ..blank_settings(kind), erase: mode == "erase" });
    }
    return Err(invalid(message));
}

fn write_row(g: mask.Grid, ids: List<String>, raw: json.Json) -> Result<rgba.Write, json.Json> {
    let message = "Cel pixels need a native coordinate and a known swatch or null";
    let row = object(raw, ["at", "swatch"], message)?;
    let xy = value.items(value.get(row, "at"));
    let x = value.word(xy.at_or(0, json.null()), g.width - 1);
    let y = value.word(xy.at_or(1, json.null()), g.height - 1);
    let swatch = value.get(row, "swatch");
    let slot = selection.find_swatch(ids, value.text(swatch));
    if length(xy) != 2 || x >= g.width || y >= g.height || !value.has(row, "swatch") || (slot < 0 && swatch != json.null()) {
        return Err(invalid(message));
    }
    return Ok(rgba.Write { pixel: y * g.width + x, slot: slot, alpha: 255 });
}

fn explicit_row(art: frame.Artwork, raw: json.Json, prior: List<String>) -> Result<Explicit, json.Json> {
    let message = "Cel writing needs a distinct cel ID and a native pixel list for each cel";
    let row = object(raw, ["cel", "pixels"], message)?;
    let id = text_in(row, "cel");
    let pixels = value.items(value.get(row, "pixels"));
    let size = art.grid.width * art.grid.height;
    if !cel_name(id) || frame.known_frame(prior, id) || length(pixels) == 0 || length(pixels) > size {
        return Err(invalid(message));
    }
    return explicit_pixels(art.grid, art.ids, id, pixels);
}

record Writes { slots: Map<u32, i32>, sites: Buffer<u32>, issue: json.Json, }

fn add_write(g: mask.Grid, ids: List<String>, raw: json.Json, out: Writes) -> Writes {
    if out.issue != json.null() { return out; }
    let found = write_row(g, ids, raw);
    let issue = found.fold(fn(row) => json.null(), fn(issue) => issue);
    if issue != json.null() { return Writes { ..out, issue: issue }; }
    return add_pixel(g, found.fold(fn(row) => row, fn(issue) => no_write()), out);
}

fn add_pixel(g: mask.Grid, row: rgba.Write, out: Writes) -> Writes {
    if out.slots.get_or(row.pixel, -3) != -3 {
        let xy = fault.position(g, row.pixel);
        let coords = string_concat(frame.decimal(xy.x), string_concat(",", frame.decimal(xy.y)));
        return Writes { ..out, issue: invalid(string_concat("Cel writing repeats a pixel at ", coords)) };
    }
    return Writes { slots: out.slots.set(row.pixel, row.slot), sites: out.sites.push(row.pixel), issue: json.null() };
}

fn explicit_pixels(g: mask.Grid, ids: List<String>, id: String, pixels: List<json.Json>) -> Result<Explicit, json.Json> {
    let blank = Writes { slots: Map.empty(), sites: Buffer.empty(), issue: json.null() };
    let parsed = foldl(pixels, blank, fn(raw) => fn(out) => add_write(g, ids, raw, out));
    if parsed.issue != json.null() { return Err(parsed.issue); }
    let slots = parsed.slots;
    return Ok(Explicit { cel: id, writes: parsed.sites.freeze().sort()
        .map(fn(p) => rgba.Write { pixel: p, slot: slots.get_or(p, -1), alpha: 255 }) });
}

fn explicit(art: frame.Artwork, operation: List<json.Member>) -> Result<List<Explicit>, json.Json> {
    let rows = value.items(value.get(operation, "cels"));
    if !value.only(operation, ["type", "cels"]) || length(rows) == 0 {
        return Err(invalid("Cel writing needs a list of edited cels"));
    }
    let initial: Result<List<Explicit>, json.Json> = Ok([]);
    return foldl(rows, initial, fn(raw) => fn(out) => next_explicit(art, raw, out));
}

fn next_explicit(art: frame.Artwork, raw: json.Json, before: Result<List<Explicit>, json.Json>) -> Result<List<Explicit>, json.Json> {
    let rows = before?;
    let row = explicit_row(art, raw, rows.map(fn(row) => row.cel))?;
    return Ok(rows.concat([row]));
}

fn target_frame(id: String, ordinal: u32, layers: List<frame.Layer>) -> Target {
    return Target { frame: id, ordinal: ordinal, layers: layers, selection: paint.Constraint { limited: false, words: [] } };
}

fn by_id(art: frame.Artwork, rows: List<json.Member>) -> Result<List<Target>, json.Json> {
    let ids = value.items(value.get(rows, "cels")).map(fn(raw) => value.text(raw));
    if value.has(rows, "frames") || value.has(rows, "tag") || value.has(rows, "layers") || !distinct(ids, true) {
        return Err(invalid("Use unique cel IDs or a frame range and layers"));
    }
    let sites = ids.map(fn(id) => frame.location(art.locations, id));
    let missing: u32 = repeat_until(length(sites), 4294967295, fn(i) => i != 4294967295,
        fn(i) => fn(found) => if sites.at_or(i, frame.Location { id: "", frame: "", layer: "" }).id == "" { i } else { found });
    if missing != 4294967295 {
        let id = ids.at_or(missing, "");
        return Err(problem("missing-cel", string_concat("Unknown pixel cel ", id), [property("cel", id)]));
    }
    return Ok(art.frames.map_indexed(fn(i) => fn(id) => target_frame(id, i, layers_in_frame(id, art.layers, sites)))
        .filter(fn(row) => length(row.layers) != 0));
}

fn layers_in_frame(id: String, layers: List<frame.Layer>, sites: List<frame.Location>) -> List<frame.Layer> {
    return layers.filter(fn(layer) =>
        fold_until(sites, false, fn(row) => fn(found) => found, fn(row) => fn(found) => found || (row.frame == id && row.layer == layer.id)));
}

fn endpoints(source: json.Json, rows: List<json.Member>) -> Result<List<String>, json.Json> {
    if !value.has(rows, "tag") { return Ok(value.items(value.get(rows, "frames")).map(fn(raw) => value.text(raw))); }
    let tag = value.get(rows, "tag");
    let id = value.text(tag);
    let tags = value.items(value.get(value.fields(source), "tags"));
    let found = fold_until(tags, json.null(), fn(row) => fn(found) => found != json.null(),
        fn(row) => fn(found) => if found == json.null() && text_in(value.fields(row), "id") == id { row } else { found });
    if found == json.null() {
        let missing = labels.label(tag);
        return Err(problem("missing-tag", string_concat("Unknown playback tag ", missing), [member("tag", tag)]));
    }
    let spec = value.fields(found);
    return Ok([text_in(spec, "start"), text_in(spec, "end")]);
}

fn by_range(source: json.Json, art: frame.Artwork, rows: List<json.Member>) -> Result<List<Target>, json.Json> {
    let names = value.items(value.get(rows, "layers")).map(fn(raw) => value.text(raw));
    if value.has(rows, "frames") == value.has(rows, "tag") || !distinct(names, false) {
        return Err(invalid("Use an inclusive frame range or playback tag and a list of unique layers"));
    }
    let invalid_layer = fold_until(names, "", fn(id) => fn(out) => out != "", fn(id) => fn(out) => if out == "" { bad_layer(art.layers, id) } else { out });
    if invalid_layer != "" {
        return Err(problem("missing-layer", "Choose a layer that can contain cels", [property("layer", invalid_layer)]));
    }
    let ends = endpoints(source, rows)?;
    let a = ends.at_or(0, "");
    let b = ends.at_or(1, "");
    if length(ends) != 2 || !brush.stable_id(a) || !brush.stable_id(b) { return Err(invalid("A frame range needs two frame IDs")); }
    let first = selection.named_slot(art.frames, a);
    let last = selection.named_slot(art.frames, b);
    if first >= length(art.frames) || last >= length(art.frames) || first > last {
        return Err(invalid("Frame range endpoints must exist in timeline order"));
    }
    let layers = art.layers.filter(fn(layer) => frame.known_frame(names, layer.id));
    return Ok(art.frames.drop(first).take(last - first + 1).map_indexed(fn(i) => fn(id) => target_frame(id, first + i, layers)));
}

fn bad_layer(layers: List<frame.Layer>, id: String) -> String {
    let row = paint.find_layer(layers, id);
    return if row.id == "" || row.kind == "group" { id } else { "" };
}

fn select(source: json.Json, art: frame.Artwork, named: selection.Named, raw: json.Json, kind: String) -> Result<List<Target>, json.Json> {
    let message = "Use a cel scope and an optional shared selection or per-frame selections";
    let rows = object(raw, ["cels", "frames", "tag", "layers", "selection", "selections"], message)?;
    let shared = text_in(rows, "selection");
    let per_frame = value.get(rows, "selections");
    let has_shared = value.has(rows, "selection");
    let has_per_frame = value.has(rows, "selections");
    if has_shared && (has_per_frame || !brush.stable_id(shared)) { return Err(invalid(message)); }
    let names: Result<List<json.Member>, json.Json> = if has_per_frame {
        json.members(per_frame).map_err(fn(issue) => invalid(message))
    } else { Ok([]) };
    let chosen = names?;
    if length(chosen.filter(fn(row) => !brush.stable_id(value.text(row.value)))) != 0 { return Err(invalid(message)); }
    let targets = if value.has(rows, "cels") { by_id(art, rows) } else { by_range(source, art, rows) };
    let selected = targets?;
    if !has_shared && !has_per_frame {
        if kind == "mask" || kind == "cleanup" { return Err(invalid("Mask and cleanup need a saved selection for each target frame")); }
        return Ok(selected);
    }
    let selected_ids = selected.map(fn(row) => row.frame);
    if length(chosen.filter(fn(row) => !frame.known_frame(selected_ids, row.key))) != 0 {
        return Err(invalid("Per-frame selections must belong to frames in the cel scope"));
    }
    return foldl(selected, Ok([]), fn(row) => fn(acc) => choose_mask(art.grid, named, row, shared, chosen, acc));
}

fn choose_mask(g: mask.Grid, named: selection.Named, row: Target, shared: String,
    names: List<json.Member>, acc: Result<List<Target>, json.Json>) -> Result<List<Target>, json.Json> {
    let rows = acc?;
    let name = if shared == "" { text_in(names, row.frame) } else { shared };
    let saved = selection.recall_named(g, named, row.frame, name);
    if saved.issue != "" {
        return Err(problem("missing-selection", string_concat("Choose a saved selection for frame ", row.frame),
            [property("frame", row.frame), member("selection", nullable(name))]));
    }
    return Ok(rows.concat([Target { ..row, selection: paint.Constraint { limited: true, words: saved.mask } }]));
}

fn nullable(id: String) -> json.Json { return if id == "" { json.null() } else { json.text(id) }; }
fn coverage(before: frame.Captured, p: u32, slot: i32) -> u32 {
    return if slot < 0 { 255 } else { before.alpha.at_or(p, 255) };
}
fn original(before: frame.Captured, p: u32) -> rgba.Write {
    let slot = before.slots.at_or(p, -1);
    return rgba.Write { pixel: p, slot: slot, alpha: coverage(before, p, slot) };
}
fn changed(before: frame.Captured, row: rgba.Write) -> Bool {
    let was = original(before, row.pixel);
    return was.slot != row.slot || was.alpha != row.alpha;
}
fn no_write() -> rgba.Write { return rgba.Write { pixel: 0, slot: -3, alpha: 255 }; }

fn moved_at(g: mask.Grid, spec: Settings, p: u32, forward: Bool) -> Vec2<i32> {
    let point = fault.position(g, p);
    let dir: i32 = if forward { 1 } else { -1 };
    return vec2(grid.signed(point.x) + dir * spec.x, grid.signed(point.y) + dir * spec.y);
}
fn native(g: mask.Grid, point: Vec2<i32>) -> Bool {
    return point.x >= 0 && point.y >= 0 && grid.unsigned(point.x) < g.width && grid.unsigned(point.y) < g.height;
}
fn is_moving(before: frame.Captured, limit: paint.Constraint, p: u32) -> Bool {
    return before.slots.at_or(p, -1) != -1 && paint.selected(p, limit);
}
fn nudge(g: mask.Grid, before: frame.Captured, limit: paint.Constraint, spec: Settings) -> Result<List<rgba.Write>, json.Json> {
    if spec.x == 0 && spec.y == 0 { return Ok([]); }
    let moving = mask.indices(limit.words);
    let size = g.width * g.height;
    let used = if limit.limited { moving.filter(fn(p) => is_moving(before, limit, p)) }
        else { mask.indices(mask.full(g)).filter(fn(p) => is_moving(before, limit, p)) };
    let denied = fold_until(used, size, fn(p) => fn(out) => out < size,
        fn(p) => fn(out) => if out < size || native(g, moved_at(g, spec, p, true)) { out } else { p });
    if denied < size {
        let dst = moved_at(g, spec, denied, true);
        return Err(problem("outside-canvas", "Nudge would move artwork outside the native canvas",
            [member("at", at(g, denied)), member("to", json.array([signed(dst.x), signed(dst.y)]))]));
    }
    let arrivals = used.map(fn(p) => pixel(g, moved_at(g, spec, p, true)));
    let sites = used.concat(arrivals).sort();
    let unique = sites.map_indexed(fn(i) => fn(p) => if i == 0 || p != sites.at_or(i - 1, size) { p } else { size }).filter(fn(p) => p != size);
    return Ok(unique.map(fn(p) => moved_write(g, before, limit, spec, p)).filter(fn(row) => changed(before, row)));
}
fn pixel(g: mask.Grid, p: Vec2<i32>) -> u32 { return grid.unsigned(p.y) * g.width + grid.unsigned(p.x); }
fn moved_write(g: mask.Grid, before: frame.Captured, limit: paint.Constraint, spec: Settings, p: u32) -> rgba.Write {
    let src = moved_at(g, spec, p, false);
    if native(g, src) {
        let from = pixel(g, src);
        if is_moving(before, limit, from) { return rgba.Write { ..original(before, from), pixel: p }; }
    }
    return rgba.Write { pixel: p, slot: -1, alpha: 255 };
}
fn pixel_edit(before: frame.Captured, limit: paint.Constraint, spec: Settings, p: u32) -> rgba.Write {
    let slot = before.slots.at_or(p, -1);
    if spec.kind == "mask" {
        if slot != -1 && mask.selected(limit.words, p) == spec.erase { return rgba.Write { pixel: p, slot: -1, alpha: 255 }; }
    } else {
        if slot >= 0 && paint.selected(p, limit) {
            let to = spec.swap.at_or(grid.unsigned(slot), -1);
            if to >= 0 { return rgba.Write { pixel: p, slot: to, alpha: coverage(before, p, slot) }; }
        }
    }
    return no_write();
}
fn edits(g: mask.Grid, doc: frame.Captured, limit: paint.Constraint, spec: Settings,
    explicit: List<Explicit>, cel: String) -> Result<List<rgba.Write>, json.Json> {
    if spec.kind == "pixels" {
        let empty = Explicit { cel: "", writes: [] };
        let row = fold_until(explicit, empty, fn(row) => fn(out) => out.cel != "",
            fn(row) => fn(out) => if row.cel == cel { row } else { out });
        return Ok(row.writes.filter(fn(row) => changed(doc, row)));
    }
    if spec.kind == "nudge" { return nudge(g, doc, limit, spec); }
    let pixels = if limit.limited && (spec.kind == "palette-swap" || spec.erase) { mask.indices(limit.words) }
        else { mask.indices(mask.full(g)) };
    return Ok(pixels.map(fn(p) => pixel_edit(doc, limit, spec, p)).filter(fn(row) => row.slot != -3));
}

fn pigment_key(row: rgba.Write) -> u32 {
    if row.slot < 0 { return grid.unsigned(row.slot + 2); }
    return grid.unsigned(row.slot) * 256 + row.alpha + 2;
}

fn group_key(a: rgba.Write, b: rgba.Write) -> u32 {
    return word_or(wrapping_shl(pigment_key(a), 16), pigment_key(b));
}

fn group_write(before: frame.Captured, row: rgba.Write, out: Groups) -> Groups {
    let previous = original(before, row.pixel);
    let key = group_key(previous, row);
    let size = out.rows.len();
    let found = out.index.get_or(key, size);
    let initial = Group { before: previous, after: row, first: out.ordinal, last: out.ordinal };
    if found == size {
        return Groups { ..out, index: out.index.set(key, size), rows: out.rows.push(initial), ordinal: out.ordinal + 1 };
    }
    let group = out.rows.at_or(found, initial);
    return Groups { ..out, rows: out.rows.set(found, Group { ..group, last: out.ordinal }),
        next: out.next.set(group.last, out.ordinal), ordinal: out.ordinal + 1 };
}

fn swatch(art: frame.Artwork, row: rgba.Write) -> json.Json {
    let state = if row.slot == -2 { "knockout" } else { if row.slot < 0 { "clear" } else { "paint" } };
    let name = if row.slot < 0 { json.null() } else { json.text(art.ids.at_or(grid.unsigned(row.slot), "")) };
    return json.object([property("state", state), member("swatch", name),
        member("alpha", if row.slot < 0 { json.null() } else { num(row.alpha) })]);
}

fn span_value(span: Vec3<u32>) -> json.Json { return json.array([num(span.x), num(span.y), num(span.z)]); }

fn report_group(art: frame.Artwork, row: Group, sites: List<u32>) -> json.Json {
    return json.object([member("before", swatch(art, row.before)), member("after", swatch(art, row.after)),
        member("runs", json.array(paint.runs(art.grid, sites).map(fn(span) => span_value(span))))]);
}

fn next_site(next: List<u32>, writes: List<rgba.Write>, found: GroupSites) -> GroupSites {
    let row = writes.at_or(found.cursor, no_write());
    return GroupSites { cursor: next.at_or(found.cursor, length(writes)), sites: found.sites.push(row.pixel) };
}

fn report_sites(art: frame.Artwork, group: Group, next: List<u32>, writes: List<rgba.Write>) -> json.Json {
    let initial = GroupSites { cursor: group.first, sites: Buffer.empty() };
    let collected = repeat_until(length(writes), initial, fn(found) => found.cursor == length(writes),
        fn(i) => fn(out) => next_site(next, writes, out));
    return report_group(art, group, collected.sites.freeze());
}

fn report_changes(art: frame.Artwork, before: frame.Captured, writes: List<rgba.Write>) -> List<json.Json> {
    let init = Groups { index: Map.empty(), rows: Buffer.empty(), next: buffer_fill(length(writes), length(writes)), ordinal: 0 };
    let all = foldl(writes, init, fn(row) => fn(out) => group_write(before, row, out));
    let groups = all.rows.freeze();
    let next = all.next.freeze();
    return groups.map(fn(group) => report_sites(art, group, next, writes));
}

fn append(art: frame.Artwork, cel: frame.Cel, marks: List<raster.RunMark>) -> Result<frame.Cel, json.Json> {
    let scope = frame.Scope { frame: cel.frame, layer: cel.layer };
    let applied = paint.append_marks(art, scope, marks, cel.id).map_err(fn(issue) => shifted(art, cel, marks, issue))?;
    return Ok(with_drawing(cel, applied));
}

fn with_drawing(cel: frame.Cel, drawing: paint.Appended) -> frame.Cel {
    return frame.Cel { ..cel, fields: drawing.fields, runs: drawing.runs,
        prepared: drawing.prepared, plane: drawing.plane, run_plane: drawing.run_plane };
}

fn shifted(art: frame.Artwork, cel: frame.Cel, marks: List<raster.RunMark>, message: String) -> json.Json {
    let scope = frame.Scope { frame: cel.frame, layer: cel.layer };
    let issue = paint.shifted_fault(art, scope, marks, message);
    let fields = issue.at.fold(fn(point) => [member("at", json.array([num(point.x), num(point.y)]))], fn(unit) => []);
    return problem(issue.code, issue.message, fields);
}

fn protected_write(g: mask.Grid, drawn: frame.PaintView, locked: List<u32>, rows: List<rgba.Write>) -> Result<Unit, json.Json> {
    let size = mask.size(g);
    let p = fold_until(rows, size, fn(row) => fn(p) => p < size,
        fn(row) => fn(p) => if p < size || frame.can_paint(drawn, locked, row.pixel) { p } else { row.pixel });
    if p == size { return Ok(()); }
    let issue = fault.blocked(g, drawn, locked, "", p, "Cel edit cannot change this pixel");
    return Err(problem(issue.code, issue.message, [member("at", at(g, p))]));
}

fn layer_plan(art: frame.Artwork, cel: frame.Cel, layer: frame.Layer, drawn: frame.PaintView,
    locked: List<u32>, limit: paint.Constraint, spec: Settings, explicit: List<Explicit>) -> Result<LayerPlan, json.Json> {
    if paint.locked_layer(art.layers, layer) {
        let issue = fault.locked(layer.id);
        return Err(problem(issue.code, issue.message, []));
    }
    let checked = if spec.kind == "cleanup" { cleanup.plan(art, drawn, limit.words, locked, spec.cleanup) }
        else { edits(art.grid, drawn.captured, limit, spec, explicit, cel.id) };
    let rows = checked?;
    let guard = protected_write(art.grid, drawn, locked, rows)?;
    let plan = paint.write_changes(art.grid, drawn.captured, rows, [], true);
    let revised: Result<List<frame.Cel>, json.Json> = if length(rows) == 0 { Ok([]) }
        else { append(art, cel, plan.marks).map(fn(row) => [row]) };
    let next = revised?;
    return Ok(LayerPlan { edited: next, count: length(rows), target: json.object([
        property("cel", cel.id), property("layer", cel.layer), member("pixelCount", num(length(rows))),
        member("changes", json.array(report_changes(art, drawn.captured, rows)))]) });
}

fn captured(art: frame.Artwork, drawing: frame.ExportView, layer: String) -> frame.PaintView {
    let ordinal = frame.clip_index(art.layers, layer, length(art.layers)) + 1;
    let source = fold_until(drawing.sources, frame.no_capture(), fn(row) => fn(out) => out.found,
        fn(row) => fn(out) => if row.owner == ordinal { row.view } else { out });
    return frame.PaintView { captured: source, pixels: drawing.pixels };
}

record FrameContext { draw: frame.ExportView, locked: List<u32>, target: Target, }
record FrameLayers { revised: List<frame.Cel>, cels: List<json.Json>, missing: List<json.Json>, count: u32, }

fn frame_layer(art: frame.Artwork, scene: FrameContext, spec: Settings, explicit: List<Explicit>,
    layer: frame.Layer, input: Result<FrameLayers, json.Json>) -> Result<FrameLayers, json.Json> {
    let out = input?;
    let cel = frame.active_cel(art.cels, scene.target.frame, layer.id);
    if cel.id == "" { return Ok(FrameLayers { ..out, missing: out.missing.concat([json.text(layer.id)]) }); }
    let rendered = captured(art, scene.draw, layer.id);
    let planned = layer_plan(art, cel, layer, rendered, scene.locked, scene.target.selection, spec, explicit)
        .map_err(fn(issue) => contextual(issue, cel))?;
    return Ok(FrameLayers { revised: out.revised.concat(planned.edited), cels: out.cels.concat([planned.target]),
        missing: out.missing, count: out.count + planned.count });
}

fn frame_plan(art: frame.Artwork, protected: List<paint.Detail>, target: Target,
    spec: Settings, explicit: List<Explicit>) -> Result<FramePlan, json.Json> {
    let scope = frame.Scope { frame: target.frame, layer: "" };
    let draw = frame.export_view(art, scope, false, true).map_err(fn(issue) => invalid(issue))?;
    let active = paint.active_details(protected, target.ordinal);
    let issue = paint.gap_issue(art.grid, active, draw.pixels);
    if issue != "" { return Err(invalid(issue)); }
    let ctx = FrameContext { draw: draw, locked: paint.locked_pixels(art.grid, active), target: target };
    let blank: Result<FrameLayers, json.Json> = Ok(FrameLayers { revised: [], cels: [], missing: [], count: 0 });
    let layers = foldl(target.layers, blank, fn(row) => fn(out) => frame_layer(art, ctx, spec, explicit, row, out))?;
    return Ok(FramePlan { edited: layers.revised, count: layers.count, target: json.object([
        property("frame", target.frame), member("pixelCount", num(layers.count)),
        member("cels", json.array(layers.cels)), member("missingLayers", json.array(layers.missing))]) });
}

fn collect(art: frame.Artwork, protected: List<paint.Detail>, spec: Settings, explicit: List<Explicit>,
    targets: List<Target>) -> Result<List<FramePlan>, json.Json> {
    let init: Result<List<FramePlan>, json.Json> = Ok([]);
    return foldl(targets, init, fn(target) => fn(old) => collect_frame(art, protected, spec, explicit, target, old));
}

fn collect_frame(art: frame.Artwork, protected: List<paint.Detail>, spec: Settings, explicit: List<Explicit>,
    target: Target, old: Result<List<FramePlan>, json.Json>) -> Result<List<FramePlan>, json.Json> {
    let rows = old?;
    let row = frame_plan(art, protected, target, spec, explicit)?;
    return Ok(rows.concat([row]));
}

fn holds(cel: frame.Cel) -> String { return text_in(cel.fields, "hold"); }

fn same_drawing(a: frame.Cel, b: frame.Cel) -> Bool {
    // Candidates in one group share the base marks and slots of the original root.
    return a.runs == b.runs;
}

fn choose_keeper(rows: List<Partition>, drawing: frame.Cel, id: String) -> String {
    return fold_until(rows, id, fn(row) => fn(out) => out != id,
        fn(row) => fn(out) => if same_drawing(row.drawing, drawing) { row.keeper } else { out });
}

fn partition_edits(root: frame.Cel, members: List<frame.Cel>, edits: List<frame.Cel>) -> List<Partition> {
    let initial: List<Partition> = [];
    return foldl(members, initial, fn(cel) => fn(rows) => partition_member(root, cel, edits, rows));
}

fn partition_member(root: frame.Cel, cel: frame.Cel, edits: List<frame.Cel>, rows: List<Partition>) -> List<Partition> {
    let candidate = frame.find_cel(edits, cel.id);
    let sketch = if candidate.id == "" { root } else { candidate };
    let keeper = choose_keeper(rows, sketch, cel.id);
    return rows.concat([Partition { original: cel, drawing: sketch, keeper: keeper }]);
}

fn keeper_of(rows: List<Partition>, id: String) -> String {
    return fold_until(rows, "", fn(row) => fn(out) => out != "",
        fn(row) => fn(out) => if row.original.id == id { row.keeper } else { out });
}

fn relink(cel: frame.Cel, hold: String) -> frame.Cel {
    let fields = cel.fields.filter(fn(row) => row.key != "marks" && row.key != "slots" && row.key != "hold");
    return frame.Cel { ..cel, fields: fields.concat([property("hold", hold)]), runs: [], prepared: [], plane: 0, run_plane: 0 };
}

fn persist_partition(art: frame.Artwork, edits: List<frame.Cel>, partitions: List<Partition>, row: Partition, out: Linked) -> Linked {
    let cel = row.original;
    let before = holds(cel);
    let after = if row.keeper == cel.id { "" }
        else { if keeper_of(partitions, before) == row.keeper { before } else { row.keeper } };
    if before == after {
        if before != "" { return out; }
        let edit = frame.find_cel(edits, cel.id);
        return if edit.id == "" { out } else { Linked { ..out, edits: out.edits.concat([edit]) } };
    }
    let replacement = if after != "" { relink(cel, after) }
        else { independent(art, cel, edits) };
    let change = json.object([property("cel", cel.id), property("frame", cel.frame), property("layer", cel.layer),
        member("before", nullable(before)), member("after", nullable(after))]);
    return Linked { edits: out.edits.concat([replacement]), changes: out.changes.concat([change]) };
}

fn independent(art: frame.Artwork, cel: frame.Cel, edits: List<frame.Cel>) -> frame.Cel {
    let edit = frame.find_cel(edits, cel.id);
    if edit.id != "" { return edit; }
    let scope = frame.Scope { frame: cel.frame, layer: cel.layer };
    return with_drawing(cel, paint.append_local_marks(art, scope, cel, [], cel.id));
}

record Held { cel: frame.Cel, root: String, }

fn group_links(art: frame.Artwork, roots: List<Held>, id: String, previous: Linked) -> Linked {
    let root = frame.find_cel(art.cels, id);
    let members = [root].concat(roots.filter(fn(row) => row.root == id).map(fn(row) => row.cel));
    let member_ids = members.map(fn(cel) => cel.id);
    let touched = previous.edits.filter(fn(cel) => frame.known_frame(member_ids, cel.id));
    if length(touched) == 0 { return previous; }
    let partitions = partition_edits(root, members, touched);
    let retained = previous.edits.filter(fn(cel) => !frame.known_frame(member_ids, cel.id));
    return foldl(partitions, Linked { ..previous, edits: retained },
        fn(row) => fn(out) => persist_partition(art, touched, partitions, row, out));
}

fn preserve(art: frame.Artwork, edited: List<frame.Cel>) -> Linked {
    let initial = Linked { edits: edited, changes: [] };
    if length(edited) == 0 { return initial; }
    let held = art.cels.filter(fn(cel) => holds(cel) != "")
        .map(fn(cel) => Held { cel: cel, root: frame.resolved_cel(art.cels, cel).id });
    let initial_roots: List<String> = [];
    let roots = foldl(held, initial_roots, fn(row) => fn(out) => if frame.known_frame(out, row.root) { out } else { out.concat([row.root]) });
    return foldl(roots, initial, fn(id) => fn(out) => group_links(art, held, id, out));
}

fn updated(cel: frame.Cel, edits: List<frame.Cel>) -> frame.Cel {
    let found = frame.find_cel(edits, cel.id);
    return if found.id == "" { cel } else { found };
}

fn finish(source: json.Json, art: frame.Artwork, tool: String, scope: json.Json, kind: String, rows: List<FramePlan>) -> Edit {
    let count: u64 = foldl(rows, 0, fn(row) => fn(n) => n + word_widen_u32_to_u64(row.count));
    let initial_cels: List<frame.Cel> = [];
    let candidates = foldl(rows, initial_cels, fn(row) => fn(out) => out.concat(row.edited));
    let linked = preserve(art, candidates);
    let parts = [property("destination", "timeline"), property("kind", "timeline"), property("tool", tool),
        property("edit", kind), member("scope", scope), member("frames", json.array(rows.map(fn(row) => row.target))),
        member("pixelCount", timeline.number(f64_from_u64(count)))];
    let details = if length(linked.changes) == 0 { parts } else { parts.concat([member("links", json.array(linked.changes))]) };
    let changed = length(linked.edits) != 0;
    let next = if changed { frame.Artwork { ..art, cels: art.cels.map(fn(cel) => updated(cel, linked.edits)) } } else { art };
    return Edit { source: paint.authored_cels(source, linked.edits), artwork: next, target: json.object(details), changed: changed };
}

fn apply(source: json.Json, art: frame.Artwork, named: selection.Named, tool: String, op: List<json.Member>) -> Result<Edit, json.Json> {
    let writes: Result<List<Explicit>, json.Json> = if tool == "write-cels" { explicit(art, op) } else { Ok([]) };
    let pixels = writes?;
    let opts: Result<Settings, json.Json> = if tool == "write-cels" { Ok(blank_settings("pixels")) } else { settings(art, op) };
    let spec = opts?;
    let scope = if tool == "write-cels" { json.object([member("cels", json.array(pixels.map(fn(row) => json.text(row.cel))))]) }
        else { value.get(op, "scope") };
    let targets = select(source, art, named, scope, spec.kind)?;
    let protections = paint.protections(source, art).map_err(fn(issue) => invalid(issue))?;
    let rows = collect(art, protections, spec, pixels, targets)?;
    return Ok(finish(source, art, tool, scope, spec.kind, rows));
}
