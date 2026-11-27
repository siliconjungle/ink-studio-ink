module StudioPixelDocument;

import "std:json" as json;
import "pixel_selection.ink" as selection;
import "pixel_mask.ink" as mask;
import "pixel_labels.ink" as labels;

record Layer { id: String, kind: String, parent: String, }
record Cel { id: String, hold: String, }
record Frame { id: String, duration: u64, cels: List<Cel>, }
record Identifier { name: String, slot: u32, }
record NameIndex { buckets: Map<u64, List<Identifier>>, duplicate: String, }
record Visits { seen: Map<u32, u32>, issue: String, }
record HoldWalk { visits: Visits, path: Buffer<u32>, current: u32, }
record Opened { document: json.Json, legacy: Bool, }

pub fn select_pixel_indices(query: List<json.Json>, width: u32, height: u32, rgba: List<u32>, saved: json.Json) -> Result<List<u32>, String> {
    let selected = selection.select(width, height, query, rgba, saved, [], false, false, mask.no_palette())?;
    return Ok(mask.indices(selected));
}

pub fn select_pixel_words(query: List<json.Json>, width: u32, height: u32, rgba: List<u32>, saved: json.Json,
    literal_runs: List<List<u32>>, large: Bool) -> Result<List<u32>, String> {
    return selection.select(width, height, query, rgba, saved, literal_runs, true, large, mask.no_palette());
}

pub fn select_pixel_words_from_raster(query: List<json.Json>, width: u32, height: u32, rgba: List<u32>,
    saved: json.Json, literal_runs: List<List<u32>>, large: Bool, slots: List<i32>, alpha: List<u32>,
    clipping: List<u32>, ids: List<String>) -> Result<List<u32>, String> {
    let palette = mask.PaletteRaster { slots: slots, alpha: alpha, clipping: clipping, ids: ids };
    return selection.select(width, height, query, rgba, saved, literal_runs, true, large, palette);
}

// Assemble the standard JSON value from already parsed native components.
pub fn pixel_json_value(kind: u32, scalar: String, flag: Bool, values: List<json.Json>, keys: List<String>) -> json.Json {
    if kind == 0 { return json.null(); }
    if kind == 1 { return json.boolean(flag); }
    if kind == 2 { return json.number(scalar); }
    if kind == 3 { return json.text(scalar); }
    if kind == 4 { return json.array(values); }
    return json.object(values.map_indexed(fn(i) => fn(value) => member(keys.at_or(i, ""), value)));
}

fn field(items: List<json.Member>, key: String) -> json.Json {
    return json.lookup(items, key).fold(fn(value) => value, fn(unit) => json.null());
}

fn has(items: List<json.Member>, key: String) -> Bool {
    return foldl(items, false, fn(item) => fn(found) => found || item.key == key);
}

fn allowed(items: List<json.Member>, keys: List<String>) -> Bool {
    return foldl(items, true, fn(item) => fn(valid) =>
        valid && foldl(keys, false, fn(key) => fn(found) => found || key == item.key));
}

fn object(value: json.Json, error: String) -> Result<List<json.Member>, String> {
    return json.members(value).fold(fn(items) => Ok(items), fn(reason) => Err(error));
}

fn text(value: json.Json) -> String { return json.as_text(value).fold(fn(s) => s, fn(reason) => ""); }
fn token(value: json.Json) -> String { return json.as_number(value).fold(fn(s) => s, fn(reason) => ""); }
fn byte(value: String, offset: u32) -> u32 { return string_byte_at(value, offset).fold(fn(n) => n, fn(unit) => 0); }
fn slice(value: String, first: u32, end: u32) -> String {
    return string_slice(value, first, end).fold(fn(text) => text, fn(unit) => "");
}
fn digit(c: u32) -> Bool { return c >= 48 && c <= 57; }
fn letter(c: u32) -> Bool { return c >= 97 && c <= 122; }
fn max_integer() -> u64 { return 9007199254740991; }

// The file adapters supply the decimal spelling of an ECMAScript Number.
fn unsigned(value: String, max: u64) -> Option<u64> {
    if value == "-0" { return Some(0); }
    let size = string_byte_len(value);
    if size == 0 || size > 16 { return None; }
    var result: u64 = 0;
    var i: u32 = 0;
    var valid: Bool = true;
    for unused in buffer_fill(size, 0).freeze() {
        let c = byte(value, i);
        valid = valid && digit(c);
        result = result * 10 + (if digit(c) { word_widen_u32_to_u64(c - 48) } else { 0 });
        i = i + 1;
    }
    return if valid && result <= max { Some(result) } else { None };
}

fn positive(value: json.Json, limit: u64) -> u64 {
    return unsigned(token(value), limit).fold(fn(n) => n, fn(unit) => 0);
}

fn stable_id(value: String) -> Bool {
    let size = string_byte_len(value);
    if size == 0 || size > 64 || !letter(byte(value, 0)) { return false; }
    var i: u32 = 1;
    var valid: Bool = true;
    for unused in buffer_fill(size - 1, 0).freeze() {
        let c = byte(value, i);
        valid = valid && (letter(c) || digit(c) || c == 45);
        i = i + 1;
    }
    return valid;
}

fn cel_id(value: String) -> Bool {
    return string_find(value, "/", 0).fold(fn(slash) =>
        stable_id(slice(value, 0, slash)) && stable_id(slice(value, slash + 1, string_byte_len(value))),
        fn(unit) => stable_id(value));
}

fn label(value: json.Json) -> Bool {
    return labels.present(text(value));
}

fn optional_label(items: List<json.Member>) -> Bool {
    return json.lookup(items, "label").fold(fn(value) => label(value), fn(unit) => true);
}

fn is_bool(value: json.Json) -> Bool { return json.as_boolean(value).fold(fn(b) => true, fn(reason) => false); }

fn optional_bool(items: List<json.Member>, key: String) -> Bool {
    return json.lookup(items, key).fold(fn(value) => is_bool(value), fn(unit) => true);
}

fn pair(value: json.Json) -> List<json.Json> {
    return json.elements(value).fold(fn(items) => items, fn(reason) => []);
}

fn offset_word(value: json.Json) -> Bool {
    let s = token(value);
    let number = if byte(s, 0) == 45 { slice(s, 1, string_byte_len(s)) } else { s };
    return unsigned(number, 1000000).fold(fn(count) => true, fn(unit) => false);
}

fn valid_offset(value: json.Json) -> Bool {
    let xy = pair(value);
    return length(xy) == 2 && length(xy.filter(fn(v) => !offset_word(v))) == 0;
}

fn unit_opacity(value: json.Json) -> Bool {
    let s = token(value);
    let c = byte(s, 0);
    return s == "0" || s == "-0" || s == "1" || (c == 48 && byte(s, 1) == 46) ||
        (c >= 49 && c <= 57 && string_find(s, "e-", 0).fold(fn(offset) => true, fn(unit) => false));
}

fn rgb(value: String) -> Bool {
    if string_byte_len(value) != 7 || byte(value, 0) != 35 { return false; }
    var i: u32 = 1;
    var valid: Bool = true;
    for unused in [0, 0, 0, 0, 0, 0] {
        let c = byte(value, i);
        valid = valid && (digit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102));
        i = i + 1;
    }
    return valid;
}

fn swatch(item: json.Member, legacy: Bool) -> Bool {
    if !stable_id(item.key) { return false; }
    if rgb(text(item.value)) { return true; }
    if legacy { return false; }
    let spec = json.members(item.value).fold(fn(fields) => fields, fn(reason) => []);
    return allowed(spec, ["color", "label", "locked"]) && rgb(text(field(spec, "color"))) &&
        optional_label(spec) && optional_bool(spec, "locked");
}

fn valid_palette(items: List<json.Member>, legacy: Bool) -> Bool {
    return length(items) > 0 && length(items) <= 255 &&
        foldl(items, true, fn(item) => fn(valid) => valid && swatch(item, legacy));
}

fn find_layer(known: List<Layer>, id: String) -> Layer {
    return foldl(known, Layer { id: "", kind: "", parent: "" }, fn(layer) => fn(found) =>
        if layer.id == id { layer } else { found });
}

fn layer_structure(items: List<json.Member>, known: List<Layer>, legacy: Bool) -> Result<Layer, String> {
    let id = text(field(items, "id"));
    let kind = json.lookup(items, "kind").fold(fn(value) => text(value), fn(unit) => "paint");
    let keys = if legacy { ["id", "clip", "protect", "marks", "slots"] } else {
        ["id", "label", "kind", "parent", "clip", "visible", "locked", "opacity", "blend", "protect", "destination", "offset"]
    };
    let valid_keys = allowed(items, keys);
    if !valid_keys && legacy { return Err("Legacy layers need a unique ID, marks and optional clipping or protection"); }
    let blend = json.lookup(items, "blend").fold(fn(value) => text(value), fn(unit) => "normal");
    if !valid_keys || !stable_id(id) || find_layer(known, id).id != "" ||
        !(kind == "paint" || kind == "mask" || kind == "reference" || kind == "group" || kind == "surface") ||
        !(blend == "normal" || blend == "multiply" || blend == "screen" || blend == "overlay" || blend == "add") ||
        !optional_label(items) || !optional_bool(items, "protect") || !optional_bool(items, "visible") || !optional_bool(items, "locked") ||
        !json.lookup(items, "opacity").fold(fn(value) => unit_opacity(value), fn(unit) => true) ||
        !json.lookup(items, "offset").fold(fn(value) => kind != "group" && valid_offset(value), fn(unit) => true) {
        return Err("Pixel layers need unique IDs, known kinds and valid visibility, opacity and blend settings");
    }
    let parent = text(field(items, "parent"));
    let clip = text(field(items, "clip"));
    if has(items, "parent") && find_layer(known, parent).kind != "group" {
        return Err(string_concat(string_concat("Layer ", id), " needs an earlier parent group"));
    }
    let sibling = find_layer(known, clip);
    if has(items, "clip") && (sibling.kind == "" || sibling.parent != parent ||
        (sibling.kind == "reference" && kind != "reference")) {
        return Err(string_concat(string_concat("Layer ", id), " must clip to an earlier compatible sibling"));
    }
    if (kind == "surface" && !stable_id(text(field(items, "destination")))) ||
        (kind != "surface" && has(items, "destination")) {
        return Err("A surface layer needs a named scene destination");
    }
    return Ok(Layer { id: id, kind: kind, parent: parent });
}

fn add_layer(layer: json.Json, known: List<Layer>, legacy: Bool) -> Result<List<Layer>, String> {
    let items = object(layer, "Pixel layers need unique IDs, known kinds and valid visibility, opacity and blend settings")?;
    let spec = layer_structure(items, known, legacy)?;
    if legacy && !json.elements(field(items, "marks")).fold(fn(marks) => true, fn(reason) => false) {
        return Err("Pixel layers need marks");
    }
    return Ok(known.concat([spec]));
}

fn validate_layers(layers: List<json.Json>, legacy: Bool) -> Result<List<Layer>, String> {
    let empty: List<Layer> = [];
    return foldl(layers, Ok(empty), fn(layer) => fn(acc) =>
        acc.fold(fn(known) => add_layer(layer, known, legacy), fn(error) => Err(error)));
}

fn cel_structure(value: json.Json, frame: String, layer: String, known: List<Layer>) -> Result<Cel, String> {
    let default_id = string_concat(string_concat(frame, "/"), layer);
    let error = string_concat(string_concat("Pixel cel ", default_id), " needs a known layer and valid marks or hold, ID and offset");
    let items = object(value, error)?;
    let id = json.lookup(items, "id").fold(fn(v) => text(v), fn(unit) => default_id);
    let hold = text(field(items, "hold"));
    let marks_ok = if has(items, "hold") {
        cel_id(hold) && !has(items, "marks") && !has(items, "slots")
    } else { json.elements(field(items, "marks")).fold(fn(marks) => true, fn(reason) => false) };
    let layer_kind = find_layer(known, layer).kind;
    if layer_kind == "" || layer_kind == "group" ||
        !allowed(items, ["id", "label", "marks", "slots", "offset", "opacity", "hold"]) ||
        !optional_label(items) || !marks_ok || !cel_id(id) ||
        !json.lookup(items, "offset").fold(fn(v) => valid_offset(v), fn(unit) => true) ||
        !json.lookup(items, "opacity").fold(fn(v) => unsigned(token(v), 255).fold(fn(n) => true, fn(unit) => false), fn(unit) => true) {
        return Err(error);
    }
    return Ok(Cel { id: id, hold: hold });
}

fn frame_structure(frame: json.Json, layers: List<Layer>) -> Result<Frame, String> {
    let error = "Pixel frames need unique IDs, positive integer durations in milliseconds and cels";
    let items = object(frame, error)?;
    let id = text(field(items, "id"));
    let ms = positive(field(items, "durationMs"), max_integer());
    let drawings = object(field(items, "cels"), error)?;
    if !allowed(items, ["id", "label", "durationMs", "cels"]) || !stable_id(id) ||
        !optional_label(items) || ms == 0 { return Err(error); }
    let parsed = drawings.map(fn(row) => cel_structure(row.value, id, row.key, layers));
    let issue = foldl(parsed, "", fn(result) => fn(previous) =>
        if previous != "" { previous } else { result.fold(fn(cel) => "", fn(problem) => problem) });
    if issue != "" { return Err(issue); }
    let cels = parsed.map(fn(result) => result.fold(fn(cel) => cel, fn(problem) => Cel { id: "", hold: "" }));
    return Ok(Frame { id: id, duration: ms, cels: cels });
}

// The hash selects a bucket. Exact names decide identity, including on collision.
fn id_hash(name: String) -> u64 {
    let size = string_byte_len(name);
    return repeat_until(size, 14695981039346656037, fn(hash) => false, fn(i) => fn(hash) =>
        (hash ^ word_widen_u32_to_u64(byte(name, i))) * 1099511628211);
}

fn find_slot(bucket: List<Identifier>, name: String) -> u32 {
    return foldl(bucket, 0, fn(row) => fn(slot) => if row.name == name { row.slot } else { slot });
}

fn index_names(names: List<String>) -> NameIndex {
    var buckets: Map<u64, List<Identifier>> = Map.empty();
    var duplicate: String = "";
    var slot: u32 = 1;
    for name in names {
        if duplicate == "" {
            let key = id_hash(name);
            let bucket = buckets.get_or(key, []);
            if find_slot(bucket, name) != 0 { duplicate = name; }
            else { buckets = buckets.set(key, bucket.concat([Identifier { name: name, slot: slot }])); }
            slot = slot + 1;
        }
    }
    return NameIndex { buckets: buckets, duplicate: duplicate };
}

fn visit_hold(walk: HoldWalk, stamp: u32, targets: List<u32>, cels: List<Cel>) -> HoldWalk {
    let src = walk.current;
    let marker = walk.visits.seen.get_or(src, 0);
    if marker == 4294967295 { return HoldWalk { ..walk, current: 0 }; }
    let cel = cels.at_or(src - 1, Cel { id: "", hold: "" });
    let next = targets.at_or(src - 1, 0);
    let issue = if marker == stamp { string_concat("Pixel cel holds contain a cycle at ", cel.id) }
        else { if next == 4294967295 { string_concat("Unknown hold source cel ", cel.hold) } else { "" } };
    let visits = Visits { seen: walk.visits.seen.set(src, stamp), issue: issue };
    return HoldWalk { visits: visits, current: next, path: walk.path.push(src) };
}

fn trace_hold(targets: List<u32>, cels: List<Cel>, start: u32, visits: Visits) -> Visits {
    if visits.issue != "" { return visits; }
    let origin = HoldWalk { visits: visits, current: start, path: Buffer.empty() };
    let walk = repeat_until(length(cels) + 1, origin, fn(w) => w.current == 0 || w.visits.issue != "",
        fn(i) => fn(w) => visit_hold(w, start, targets, cels));
    let seen = foldl(walk.path.freeze(), walk.visits.seen, fn(id) => fn(map) => map.set(id, 4294967295));
    return Visits { issue: walk.visits.issue, seen: seen };
}

fn validate_holds(cels: List<Cel>) -> Result<Unit, String> {
    let index = index_names(cels.map(fn(cel) => cel.id));
    if index.duplicate != "" { return Err(string_concat("Duplicate pixel cel ID ", index.duplicate)); }
    var targets: Buffer<u32> = Buffer.empty();
    for cel in cels {
        let found = if cel.hold == "" { 0 } else { find_slot(index.buckets.get_or(id_hash(cel.hold), []), cel.hold) };
        let slot = if cel.hold != "" && found == 0 { 4294967295 } else { found };
        targets = targets.push(slot);
    }
    let destinations = targets.freeze();
    let visits = repeat_until(length(cels), Visits { seen: Map.empty(), issue: "" },
        fn(v) => v.issue != "", fn(i) => fn(v) => trace_hold(destinations, cels, i + 1, v));
    return if visits.issue == "" { Ok(()) } else { Err(visits.issue) };
}

fn validate_timeline(frames: List<json.Json>, layers: List<Layer>) -> Result<Unit, String> {
    let parsed = frames.map(fn(frame) => frame_structure(frame, layers));
    let issue = foldl(parsed, "", fn(result) => fn(previous) =>
        if previous != "" { previous } else { result.fold(fn(frame) => "", fn(problem) => problem) });
    if issue != "" { return Err(issue); }
    let ready = parsed.map(fn(result) => result.fold(fn(frame) => frame,
        fn(problem) => Frame { id: "", duration: 0, cels: [] }));
    let names = index_names(ready.map(fn(frame) => frame.id));
    if names.duplicate != "" { return Err("Pixel frames need unique IDs, positive integer durations in milliseconds and cels"); }
    let duration = foldl(ready, 0, fn(frame) => fn(total) =>
        if total > max_integer() { total } else { total + frame.duration });
    if duration > max_integer() { return Err("Pixel timeline duration exceeds the safe millisecond range"); }
    let empty: Buffer<Cel> = Buffer.empty();
    let cels = foldl(ready, empty, fn(frame) => fn(acc) =>
        foldl(frame.cels, acc, fn(cel) => fn(buf) => buf.push(cel)));
    return validate_holds(cels.freeze());
}

fn member(key: String, value: json.Json) -> json.Member { return json.Member { key: key, value: value }; }

fn upgrade_layer(layer: json.Json) -> json.Json {
    let items = json.members(layer).fold(fn(items) => items, fn(reason) => []);
    return json.object(items.filter(fn(item) => item.key != "marks" && item.key != "slots"));
}

fn legacy_cel(layer: json.Json) -> json.Member {
    let items = json.members(layer).fold(fn(items) => items, fn(reason) => []);
    let id = text(field(items, "id"));
    let drawing = [member("id", json.text(string_concat("artwork/", id))), member("marks", field(items, "marks"))];
    let slots = json.lookup(items, "slots").fold(fn(content) => [member("slots", content)], fn(unit) => []);
    return member(id, json.object(drawing.concat(slots)));
}

fn upgrade_legacy(items: List<json.Member>, layers: List<json.Json>) -> json.Json {
    let metadata = items.filter(fn(item) => item.key != "format" && item.key != "version" &&
        item.key != "width" && item.key != "height" && item.key != "palette" && item.key != "layers");
    let frame = json.object([member("id", json.text("artwork")), member("durationMs", json.number("100")),
        member("cels", json.object(layers.map(fn(layer) => legacy_cel(layer))))]);
    let normalized = [member("format", field(items, "format")), member("version", json.number("2")),
        member("width", field(items, "width")), member("height", field(items, "height")),
        member("pixelAspect", json.array([json.number("1"), json.number("1")])), member("palette", field(items, "palette")),
        member("layers", json.array(layers.map(fn(layer) => upgrade_layer(layer)))), member("frames", json.array([frame]))];
    let extras: List<json.Member> = if length(metadata) == 0 { [] } else { [member("legacyMetadata", json.object(metadata))] };
    return json.object(normalized.concat(extras));
}

fn validate_frames(items: List<json.Member>, known: List<Layer>) -> Result<Unit, String> {
    let frames = pair(field(items, "frames"));
    if length(frames) == 0 { return Err("Pixel documents need at least one frame"); }
    return validate_timeline(frames, known);
}

pub fn open_pixel_document(document: json.Json) -> Result<Opened, String> {
    let wrong_format = "Expected an Ink pixel-art document, version 1 or 2";
    let items = object(document, wrong_format)?;
    let version = token(field(items, "version"));
    if text(field(items, "format")) != "ink-studio/pixel-art" || !(version == "1" || version == "2") {
        return Err(wrong_format);
    }
    let legacy = version == "1";
    let grid_error = "Pixel art needs a native grid, a palette and up to 64 bounded layers";
    let width = positive(field(items, "width"), 512);
    let height = positive(field(items, "height"), 512);
    let layers = pair(field(items, "layers"));
    let palette = object(field(items, "palette"), grid_error)?;
    if width == 0 || height == 0 || length(layers) == 0 || length(layers) > 64 ||
        width * height * word_widen_u32_to_u64(length(layers)) > 4000000 { return Err(grid_error); }
    if !legacy {
        if !allowed(items, ["format", "version", "width", "height", "pixelAspect", "palette", "layers", "frames",
            "selections", "protectedDetails", "sceneBindings", "destinations", "guides", "ramps", "legacyMetadata",
            "artRules", "tags", "directional", "tilemap", "slices"]) { return Err("Unknown pixel document field"); }
        let aspect = pair(field(items, "pixelAspect"));
        if length(aspect) != 2 || length(aspect.filter(fn(v) => positive(v, max_integer()) == 0)) != 0 {
            return Err("Pixel aspect needs two positive integers [width,height]");
        }
        if !json.lookup(items, "legacyMetadata").fold(fn(v) => json.members(v).fold(fn(m) => true, fn(r) => false), fn(unit) => true) {
            return Err("Legacy pixel metadata must be an object");
        }
    }
    let known = validate_layers(layers, legacy)?;
    let frames: Result<Unit, String> = if legacy { Ok(()) } else { validate_frames(items, known) };
    let checked: Unit = frames?;
    if !valid_palette(palette, legacy) { return Err("Pixel palettes need 1–255 RGB swatches keyed by stable ID"); }
    return Ok(Opened { document: if legacy { upgrade_legacy(items, layers) } else { document }, legacy: legacy });
}
