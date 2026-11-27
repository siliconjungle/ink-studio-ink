module StudioPixelDocument;

import "std:json" as json;
import "pixel_selection.ink" as selection;
import "pixel_mask.ink" as mask;
import "pixel_labels.ink" as labels;
import "pixel_frame.ink" as frame_raster;
import "pixel_paint.ink" as paint;
import "pixel_fault.ink" as fault;
import "pixel_brush_capture.ink" as brushes;
import "pixel_transform.ink" as transforms;
import "pixel_history.ink" as history;
import "pixel_preview.ink" as preview;
import "pixel_commands.ink" as commands;
import "pixel_batch.ink" as batch;
import "pixel_session.ink" as session;
import "pixel_palette_edit.ink" as palette_edits;
import "pixel_asset_export.ink" as assets;
import "pixel_png.ink" as png;
import "pixel_png_input.ink" as png_input;
import "pixel_png_import.ink" as png_import;
import "pixel_guarded_edit.ink" as guarded;
import "pixel_inspect.ink" as inspection;

record Layer { id: String, kind: String, parent: String, }
record Cel { id: String, hold: String, }
record Frame { id: String, duration: u64, cels: List<Cel>, }
record Identifier { name: String, slot: u32, }
record NameIndex { buckets: Map<u64, List<Identifier>>, duplicate: String, }
record Visits { seen: Map<u32, u32>, issue: String, }
record HoldWalk { visits: Visits, path: Buffer<u32>, current: u32, }
record Opened { document: json.Json, legacy: Bool, }
record FrameRaster { width: u32, height: u32, frame: String, slots: List<i32>, alpha: List<u32>,
    clipping: List<u32>, ids: List<String>, rgba: List<u32>, }

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

pub fn rasterize_pixel_frame(document: json.Json, frame: String, layer: String, cel: String) -> Result<FrameRaster, String> {
    return rasterize_packed_pixel_frame(document, [], frame, layer, cel);
}

pub fn rasterize_packed_pixel_frame(document: json.Json, planes: List<frame_raster.SlotPlane>, frame: String,
    layer: String, cel: String) -> Result<FrameRaster, String> {
    return rasterize_compact_pixel_frame(document, planes, [], frame, layer, cel);
}

pub fn rasterize_compact_pixel_frame(document: json.Json, planes: List<frame_raster.SlotPlane>,
    runs: List<frame_raster.RunPlane>, frame: String, layer: String, cel: String) -> Result<FrameRaster, String> {
    let opened = open_pixel_document(document)?;
    let raster = frame_raster.compile(opened.document, planes, runs, frame, layer, cel)?;
    let palette = raster.image.palette;
    return Ok(FrameRaster { width: raster.width, height: raster.height, frame: raster.frame,
        slots: palette.slots, alpha: palette.alpha, clipping: palette.clipping, ids: palette.ids, rgba: raster.image.rgba });
}

pub fn pixel_slot_plane(frame: String, layer: String, pixels: List<i32>) -> frame_raster.SlotPlane {
    return frame_raster.SlotPlane { frame: frame, layer: layer, pixels: pixels };
}

pub fn pixel_run_plane(frame: String, layer: String, marks: List<List<u32>>) -> frame_raster.RunPlane {
    return frame_raster.RunPlane { frame: frame, layer: layer, marks: marks };
}

pub fn inspect_pixel_png(words: List<u32>, size: u32) -> Result<png_input.Layout, String> {
    return png_input.inspect(words, size);
}

pub fn decode_pixel_png(layout: png_input.Layout, words: List<u32>, size: u32) -> Result<png_input.Samples, String> {
    return png_input.decode(layout, words, size);
}

pub fn restore_pixel_png(layout: png_input.Layout, samples: png_input.Samples, metadata: json.Json, slots: List<i32>,
    alpha: List<u32>, knockouts: List<u32>) -> Result<png_import.Document, String> {
    return png_import.restore(layout, samples, metadata, slots, alpha, knockouts);
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

fn stable_id(value: String) -> Bool { return labels.stable_id(value); }

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

fn rgb(value: String) -> Bool { return labels.rgb(value); }

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

fn find_slot(bucket: List<Identifier>, name: String) -> u32 {
    return foldl(bucket, 0, fn(row) => fn(slot) => if row.name == name { row.slot } else { slot });
}

fn index_names(names: List<String>) -> NameIndex {
    var buckets: Map<u64, List<Identifier>> = Map.empty();
    var duplicate: String = "";
    var slot: u32 = 1;
    for name in names {
        if duplicate == "" {
            let key = labels.id_hash(name);
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
        let found = if cel.hold == "" { 0 } else { find_slot(index.buckets.get_or(labels.id_hash(cel.hold), []), cel.hold) };
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

record EditorDocument { source: json.Json, artwork: frame_raster.Artwork, named: selection.Named, }
record EditorSelection { frame: String, grid: mask.Grid, words: List<u32>, }
record EditorSnapshot { document: json.Json, positions: List<List<u32>>, edits: List<paint.SnapshotCel>,
    slot_owners: List<frame_raster.SlotOwner>, slot_planes: List<List<i32>>,
    run_owners: List<frame_raster.SlotOwner>, run_planes: List<List<List<u32>>>, }
record NamedBuild { ids: Buffer<String>, frames: Buffer<String>, packed: Buffer<Bool>, pixels: Buffer<List<u32>>,
    seen: Map<u64, List<String>>, issue: String, }
record NamedPixels { seen: Buffer<u32>, indices: Buffer<u32>, packed: Bool, issue: String, }

state EditorArtwork: frame_raster.Artwork = frame_raster.empty_artwork();
state EditorNamed: selection.Named = selection.no_named();
state EditorScope: frame_raster.Scope = frame_raster.Scope { frame: "", layer: "" };
state EditorImage: Option<selection.Image> = None;
state EditorPaint: paint.CachedView = paint.empty_cache();
state EditorSource: json.Json = json.null();
state EditorPositions: List<List<u32>> = [];

fn empty_editor_image() -> selection.Image {
    return selection.Image { rgba: [], palette: mask.no_palette() };
}

fn prepare_editor(source: json.Json, positions: List<List<u32>>, planes: List<frame_raster.SlotPlane>,
    runs: List<frame_raster.RunPlane>) -> Result<EditorDocument, String> {
    let opened = open_pixel_document(source)?;
    let bound = frame_raster.attach_planes(frame_raster.prepare(opened.document), planes)?;
    let drawing = frame_raster.attach_run_planes(bound, runs)?;
    let art = frame_raster.plan_runs(drawing);
    let items = object(opened.document, "Expected a normalized pixel-art document")?;
    let named = json.lookup(items, "selections").fold(fn(rows) =>
        read_named(rows, art.grid, art.frames, positions), fn(unit) => Ok(selection.no_named()))?;
    return Ok(EditorDocument { source: opened.document, artwork: art, named: named });
}

fn read_named(raw: json.Json, g: mask.Grid, frames: List<String>, positions: List<List<u32>>) -> Result<selection.Named, String> {
    let decoded: Result<List<json.Json>, String> = json.elements(raw).fold(fn(items) => Ok(items),
        fn(issue) => Err("Pixel selections must be an array"));
    let rows = decoded?;
    let initial = NamedBuild { ids: Buffer.empty(), frames: Buffer.empty(), packed: Buffer.empty(),
        pixels: Buffer.empty(), seen: Map.empty(), issue: "" };
    let scanned = repeat_until(length(rows), initial, fn(old) => old.issue != "", fn(i) => fn(old) =>
        add_named(rows.at_or(i, json.null()), positions.at_or(i, []), g, frames, old));
    if scanned.issue != "" { return Err(scanned.issue); }
    return Ok(selection.Named { ids: scanned.ids.freeze(), frames: scanned.frames.freeze(),
        packed: scanned.packed.freeze(), pixels: scanned.pixels.freeze() });
}

fn add_named(raw: json.Json, positions: List<u32>, g: mask.Grid, frames: List<String>, old: NamedBuild) -> NamedBuild {
    let items = json.members(raw).fold(fn(items) => items, fn(issue) => []);
    let name = text(field(items, "id"));
    let frame = text(field(items, "frame"));
    let error = "Pixel selections needs unique IDs, pixel lists and optional known frames";
    if !allowed(items, ["id", "frame", "pixels"]) || !stable_id(name) ||
        (has(items, "frame") && !frame_raster.known_frame(frames, frame)) {
        return NamedBuild { ..old, issue: error };
    }
    let key = labels.id_hash(name);
    let bucket = old.seen.get_or(key, []);
    if selection.named_slot(bucket, name) != 4294967295 { return NamedBuild { ..old, issue: error }; }
    let points: Result<List<json.Json>, String> = json.elements(field(items, "pixels")).fold(fn(values) => Ok(values), fn(reason) => Err(error));
    return points.fold(fn(coords) => pack_named(g, if length(coords) == 0 { positions } else { coords.map(fn(row) => named_position(g, row)) },
        name, frame, key, bucket, old),
        fn(issue) => NamedBuild { ..old, issue: issue });
}

fn pack_named(g: mask.Grid, coords: List<u32>, name: String, frame: String, key: u64,
    bucket: List<String>, old: NamedBuild) -> NamedBuild {
    let empty: Buffer<u32> = Buffer.empty();
    let visited = if length(coords) == 0 { empty } else { mask.blank(g) };
    let packed = length(coords) >= mask.word_count(g);
    let initial = NamedPixels { seen: visited, indices: Buffer.empty(), packed: packed, issue: "" };
    let selected = foldl(coords, initial, fn(row) => fn(state) =>
        if state.issue != "" { state } else { append_named(g, name, row, state) });
    if selected.issue != "" { return NamedBuild { ..old, issue: selected.issue }; }
    let pixels = if packed { selected.seen.freeze() } else { selected.indices.freeze() };
    return NamedBuild { ids: old.ids.push(name), frames: old.frames.push(frame), packed: old.packed.push(packed),
        pixels: old.pixels.push(pixels), seen: old.seen.set(key, bucket.concat([name])), issue: "" };
}

fn named_position(g: mask.Grid, raw: json.Json) -> u32 {
    let at = selection.point(pair(raw), g);
    return if selection.inside(at, g) { mask.index(g, at) } else { 4294967295 };
}

fn append_named(g: mask.Grid, name: String, p: u32, state: NamedPixels) -> NamedPixels {
    if p >= mask.size(g) {
        return NamedPixels { ..state, issue: named_issue(name, " has a pixel outside the native grid") };
    }
    if word_and(state.seen.at_or(mask.word_slot(p), 0), mask.word_bit(p)) != 0 {
        let x = frame_raster.decimal(rem_or(p, g.width, 0));
        let y = frame_raster.decimal(quot_or(p, g.width, 0));
        let position = string_concat(x, string_concat(",", y));
        return NamedPixels { ..state, issue: named_issue(name, string_concat(" repeats pixel ", position)) };
    }
    let indices = if state.packed { state.indices } else { state.indices.push(p) };
    return NamedPixels { ..state, seen: mask.mark(state.seen, p), indices: indices };
}

fn named_issue(id: String, problem: String) -> String {
    return string_concat("Pixel selections ", string_concat(id, problem));
}

fn recall_default(query: json.Json, named: selection.Named, supplied: json.Json) -> Result<String, String> {
    let item = json.members(query).fold(fn(items) => items, fn(issue) => []);
    if text(field(item, "type")) != "recall" { return Ok(""); }
    let id = field(item, "id");
    let name = text(id);
    let overrides = json.members(supplied).fold(fn(rows) => rows, fn(issue) => []);
    if has(overrides, name) { return Ok(""); }
    let slot = selection.named_slot(named.ids, name);
    if slot != 4294967295 { return Ok(named.frames.at_or(slot, "")); }
    let label = if !has(item, "id") { "undefined" } else { recall_label(id) };
    return Err(string_concat("Unknown pixel selection ", label));
}

fn recall_label(raw: json.Json) -> String {
    return json.as_text(raw).fold(fn(value) => value, fn(issue) =>
        json.as_number(raw).fold(fn(value) => value, fn(issue) =>
            json.as_boolean(raw).fold(fn(value) => if value { "true" } else { "false" },
                fn(issue) => if raw == json.null() { "null" } else { "[object Object]" })));
}

fn resolve_editor_scope(art: frame_raster.Artwork, named: selection.Named, root: json.Json,
    supplied: json.Json, frame: Option<String>, layer: Option<String>, cel: Option<String>) -> Result<frame_raster.Scope, String> {
    if art.grid.width == 0 { return Err("Open a pixel document before selecting"); }
    if layer.fold(fn(id) => true, fn(unit) => false) && cel.fold(fn(id) => true, fn(unit) => false) {
        return Err("Select from the composite, a layer or a cel");
    }
    if frame.fold(fn(id) => true, fn(unit) => false) || cel.fold(fn(id) => true, fn(unit) => false) {
        return frame_raster.resolve(art, frame, layer, cel);
    }
    let active = recall_default(root, named, supplied)?;
    return frame_raster.resolve(art, frame_raster.optional_scope(active), layer, cel);
}

fn editor_selection(g: mask.Grid, scope: frame_raster.Scope, image: selection.Image,
    named: selection.Named, query: List<json.Json>, saved: json.Json, runs: List<List<u32>>) -> Result<EditorSelection, String> {
    let request = selection.request(g, query, saved, runs, true);
    let words = selection.evaluate(request, image, named, scope.frame)?;
    return Ok(EditorSelection { frame: scope.frame, grid: g, words: words });
}

fn first_query(query: List<json.Json>) -> json.Json { return query.at_or(0, json.null()); }

change load_pixel_editor(document: json.Json, positions: List<List<u32>>, planes: List<frame_raster.SlotPlane>,
    runs: List<frame_raster.RunPlane>) -> Result<mask.Grid, String>
    writes(EditorArtwork, EditorNamed, EditorScope, EditorImage, EditorPaint, EditorSource, EditorPositions) {
    let prepared = prepare_editor(document, positions, planes, runs)?;
    let grid = prepared.artwork.grid;
    EditorArtwork = prepared.artwork;
    EditorNamed = prepared.named;
    EditorScope = frame_raster.Scope { frame: "", layer: "" };
    EditorImage = None;
    EditorPaint = paint.empty_cache();
    EditorSource = prepared.source;
    EditorPositions = positions;
    return Ok(grid);
}

query pixel_editor_grid() -> mask.Grid reads(EditorArtwork) {
    return frame_raster.artwork_grid(EditorArtwork);
}

query snapshot_pixel_editor() -> EditorSnapshot reads(EditorSource, EditorArtwork, EditorPositions) {
    return snapshot_editor(EditorSource, EditorArtwork, EditorPositions);
}

fn snapshot_editor(source: json.Json, art: frame_raster.Artwork, positions: List<List<u32>>) -> EditorSnapshot {
    let snapshot = paint.snapshot(source, art);
    return EditorSnapshot { document: snapshot.source, positions: positions, edits: snapshot.edits,
        slot_owners: frame_raster.slot_owners(art), slot_planes: art.planes,
        run_owners: frame_raster.run_owners(art), run_planes: art.run_planes };
}

change paint_pixel_editor(operation: json.Json, slots: List<i32>, alpha: List<u32>, pixels: List<u32>, names: List<String>, frame: Option<String>, cel: Option<String>) -> Result<paint.Report, fault.Fault>
    reads(EditorSource, EditorArtwork, EditorNamed, EditorPositions, EditorPaint)
    writes(EditorSource, EditorArtwork, EditorImage, EditorNamed, EditorPositions, EditorPaint) {
    let rgba = paint.RgbaInput { pixels: pixels, names: names };
    let clipboard = transforms.PackedClip { slots: slots, alpha: alpha };
    let edit = paint.paint(EditorSource, EditorArtwork, EditorNamed, operation, clipboard, rgba, frame, cel, EditorPositions, EditorPaint)?;
    let grid = frame_raster.artwork_grid(EditorArtwork);
    if edit.report.pixelCount != 0 {
        EditorArtwork = edit.artwork;
        EditorImage = None;
        EditorPaint = edit.cache;
    }
    let mask_id = edit.result_mask.fold(fn(row) => row.id, fn(unit) => "");
    if edit.document != json.null() { EditorSource = edit.document; }
    if mask_id != "" {
        let words: List<u32> = edit.result_mask.fold(fn(row) => row.words, fn(unit) => []);
        let scope = frame_raster.Scope { frame: edit.report.frame, layer: edit.report.layer };
        let saved = persist_selection(EditorSource, EditorNamed, EditorPositions, grid, scope,
            EditorSelection { frame: scope.frame, grid: grid, words: words }, mask_id, edit.report.tool);
        EditorSource = saved.source;
        EditorNamed = saved.named;
        EditorPositions = saved.positions;
    }
    return Ok(edit.report);
}

pub fn pixel_guarded_input(point: Option<Vec2<u32>>, at: json.Json, layer: Option<json.Json>, from: Option<json.Json>,
    to: Option<json.Json>) -> guarded.Input {
    return guarded.Input { point: point, at: at, layer: layer, from: from, to: to };
}

change edit_pixel_editor_palette(operation: json.Json, scoped: Bool) -> Result<json.Json, json.Json>
    reads(EditorSource, EditorArtwork) writes(EditorSource, EditorArtwork, EditorImage, EditorPaint) {
    let edited = palette_edits.apply(EditorSource, EditorArtwork, operation, scoped)?;
    EditorSource = edited.source;
    EditorArtwork = edited.artwork;
    EditorImage = None;
    EditorPaint = paint.empty_cache();
    return Ok(edited.report);
}

change replace_guarded_pixels(id: String, frame: String, cel: Option<String>, edits: List<guarded.Input>, reuse_composites: Bool)
    -> Result<guarded.Target, List<json.Json>>
    reads(EditorSource, EditorArtwork) writes(EditorSource, EditorArtwork, EditorImage, EditorPaint, JournalPreviewPair) {
    let edit = guarded.apply(EditorSource, EditorArtwork, id, frame, cel, edits, reuse_composites)?;
    if edit.document != json.null() { EditorSource = edit.document; }
    EditorArtwork = edit.artwork;
    EditorImage = None;
    EditorPaint = edit.cache;
    JournalPreviewPair = edit.diff;
    return Ok(edit.target);
}

fn select_cached(g: mask.Grid, scope: frame_raster.Scope, image: Option<selection.Image>,
    named: selection.Named, query: List<json.Json>, saved: json.Json, runs: List<List<u32>>) -> Result<EditorSelection, String> {
    return image.fold(fn(found) => editor_selection(g, scope, found, named, query, saved, runs),
        fn(unit) => Err("Missing the active pixel selection raster"));
}

fn image_ready(image: Option<selection.Image>) -> Bool {
    return image.fold(fn(row) => true, fn(unit) => false);
}

change select_pixel_editor(query: List<json.Json>, saved: json.Json, runs: List<List<u32>>,
    frame: Option<String>, layer: Option<String>, cel: Option<String>) -> Result<EditorSelection, String>
    reads(EditorArtwork, EditorNamed, EditorScope, EditorImage, EditorPaint) writes(EditorScope, EditorImage) {
    let scope = resolve_editor_scope(EditorArtwork, EditorNamed, first_query(query), saved, frame, layer, cel)?;
    if scope != EditorScope || !image_ready(EditorImage) {
        let selected = paint.selection_image(EditorArtwork, EditorPaint, scope)?;
        EditorScope = scope;
        EditorImage = Some(selected);
    }
    return select_cached(frame_raster.artwork_grid(EditorArtwork), scope, EditorImage,
        EditorNamed, query, saved, runs);
}

query capture_pixel_editor_brush(options: json.Json, pixels: List<u32>) -> Result<brushes.Capture, String> reads(EditorArtwork, EditorNamed) {
    return brushes.capture(EditorArtwork, EditorNamed, options, pixels);
}

query copy_pixel_editor_selection(options: json.Json) -> Result<transforms.Copy, String> reads(EditorArtwork, EditorNamed, EditorSource) {
    return transforms.copy(EditorArtwork, EditorNamed, EditorSource, options);
}

record SavedSelectionReport { frame: String, selection: String, tool: String, pixelCount: u32, runs: List<Vec3<u32>>, }
record SavedSelection { source: json.Json, named: selection.Named, positions: List<List<u32>>, report: SavedSelectionReport, }

fn persist_selection(source: json.Json, named: selection.Named, packed: List<List<u32>>,
    g: mask.Grid, scope: frame_raster.Scope, chosen: EditorSelection, name: String, tool: String) -> SavedSelection {
    let sites = mask.indices(chosen.words);
    let compressed = length(sites) >= mask.word_count(g);
    let data = if compressed { chosen.words } else { sites };
    let position = selection.named_slot(named.ids, name);
    let new_row = position == 4294967295;
    let ids = if new_row { named.ids.concat([name]) } else { named.ids };
    let frames = if new_row { named.frames.concat([scope.frame]) }
        else { named.frames.map_indexed(fn(i) => fn(old) => if i == position { scope.frame } else { old }) };
    let formats = if new_row { named.packed.concat([compressed]) }
        else { named.packed.map_indexed(fn(i) => fn(old) => if i == position { compressed } else { old }) };
    let masks = if new_row { named.pixels.concat([data]) }
        else { named.pixels.map_indexed(fn(i) => fn(old) => if i == position { data } else { old }) };
    let prior = named.ids.map_indexed(fn(i) => fn(id) => if i == position { sites } else { packed.at_or(i, []) });
    let positions = if new_row { prior.concat([sites]) } else { prior };
    let document = json.members(source).fold(fn(rows) => rows, fn(e) => []);
    let rows = pair(field(document, "selections"));
    let row = json.object([member("id", json.text(name)), member("frame", json.text(scope.frame)), member("pixels", json.array([]))]);
    let saved = if new_row { rows.concat([row]) } else {
        rows.map_indexed(fn(i) => fn(old) => if i == position { row } else { old })
    };
    let report = SavedSelectionReport { frame: scope.frame, selection: name, tool: tool,
        pixelCount: length(sites), runs: paint.runs(g, sites) };
    return SavedSelection { source: json.object(paint.replace(document, "selections", json.array(saved))),
        named: selection.Named { ids: ids, frames: frames, packed: formats, pixels: masks },
        positions: positions, report: report };
}

fn save_mask_options(raw: json.Json) -> Result<List<json.Member>, String> {
    let issue = "A selection edit needs a stable selection ID and a query";
    let spec = object(raw, issue)?;
    if !allowed(spec, ["id", "query", "layer", "cel", "sources", "targetRevision"]) || !stable_id(text(field(spec, "id"))) {
        return Err(issue);
    }
    return Ok(spec);
}

change save_pixel_editor_selection(operation: json.Json, query: List<json.Json>, runs: List<List<u32>>,
    frame: Option<String>) -> Result<SavedSelectionReport, String>
    reads(EditorArtwork, EditorNamed, EditorScope, EditorImage, EditorPaint, EditorSource, EditorPositions)
    writes(EditorNamed, EditorSource, EditorPositions) {
    let spec = save_mask_options(operation)?;
    let layer = json.lookup(spec, "layer").fold(fn(raw) => Some(recall_label(raw)), fn(unit) => None);
    let cel = json.lookup(spec, "cel").fold(fn(raw) => Some(recall_label(raw)), fn(unit) => None);
    let scope = frame_raster.resolve(EditorArtwork, frame, layer, cel)?;
    let prepared: Result<selection.Image, String> = if scope == EditorScope && image_ready(EditorImage) {
        Ok(EditorImage.unwrap_or(empty_editor_image()))
    } else { paint.selection_image(EditorArtwork, EditorPaint, scope) };
    let image = prepared?;
    let g = frame_raster.artwork_grid(EditorArtwork);
    let chosen = editor_selection(g, scope, image, EditorNamed, query, json.object([]), runs)?;
    if has(spec, "targetRevision") { return Err("A target revision needs an intent query"); }
    if has(spec, "sources") && field(spec, "sources") != json.array([]) {
        return Err("Selection sources differ from the inspected sources");
    }
    let root = json.members(first_query(query)).fold(fn(rows) => rows, fn(e) => []);
    let saved = persist_selection(EditorSource, EditorNamed, EditorPositions, g, scope, chosen,
        text(field(spec, "id")), text(field(root, "type")));
    EditorSource = saved.source;
    EditorNamed = saved.named;
    EditorPositions = saved.positions;
    return Ok(saved.report);
}


state JournalCursor: history.Cursor = history.empty_cursor();
state JournalDraft: history.Entry = history.empty_entry();
state JournalPast: List<history.Entry> = [];
state JournalFuture: List<history.Entry> = [];
state JournalLimit: u32 = 100;
state JournalSerial: u32 = 0;
state JournalRevision: u64 = 0;
state JournalEditCels: List<frame_raster.Cel> = [];
state JournalVersions: Table<u32, history.Edition> = Table.empty();
state JournalCheckpointReceipts: List<u32> = [0];
state JournalPreview: preview.Page = preview.empty_page();
state JournalPreviewPair: Option<preview.Pair> = None;

record DraftPreview { changes: preview.Report, celLinks: Option<history.Links>, receipt: u32, }

change start_pixel_journal(revision: String, legacy: String, limit: u32) -> Result<Unit, String>
    reads(JournalCursor) writes(JournalCursor, JournalLimit) {
    if JournalCursor.revision != "" { return Err("Pixel edit history is already initialized"); }
    JournalCursor = history.Cursor { revision: revision, legacy: legacy, receipt: 0 };
    JournalLimit = limit;
    return Ok(());
}

query pixel_journal() -> history.View reads(JournalCursor, JournalDraft, JournalPast, JournalFuture) {
    return history.view(JournalCursor, JournalDraft, JournalPast, JournalFuture);
}

change begin_pixel_edit(label: String) -> Result<Unit, String>
    reads(JournalCursor, JournalDraft, JournalSerial, EditorSource, EditorArtwork, EditorNamed, EditorPositions)
    writes(JournalDraft, JournalSerial, JournalVersions) {
    if JournalDraft.id != 0 { return Err("A document transaction is already active"); }
    if JournalSerial == 4294967295 { return Err("Pixel edit history has reached its version limit"); }
    let id = JournalSerial + 1;
    let saved = history.Edition { authored: EditorSource, art: EditorArtwork, named: EditorNamed,
        positions: EditorPositions, cursor: JournalCursor };
    JournalVersions.put(id, saved);
    JournalDraft = history.Entry { id: id, label: if label == "" { "Edit" } else { label },
        receipt: JournalCursor.receipt };
    JournalSerial = id;
    return Ok(());
}

query pixel_checkpoint_layout() -> session.Layout
    reads(JournalRevision, JournalLimit, JournalCursor, JournalDraft, JournalPast, JournalFuture) {
    return session.Layout { revision: JournalRevision, limit: JournalLimit, cursor: JournalCursor,
        past: JournalPast, future: JournalFuture, draft: JournalDraft };
}

record CheckpointEdition { cursor: history.Cursor, snapshot: EditorSnapshot, }

query snapshot_pixel_checkpoint(id: u32) -> Result<CheckpointEdition, String>
    reads(JournalVersions, JournalCursor, EditorSource, EditorArtwork, EditorPositions) {
    if id == 0 {
        return Ok(CheckpointEdition { cursor: JournalCursor,
            snapshot: snapshot_editor(EditorSource, EditorArtwork, EditorPositions) });
    }
    let edition = JournalVersions.get(id).ok_or("Missing pixel session history version")?;
    return Ok(CheckpointEdition { cursor: edition.cursor,
        snapshot: snapshot_editor(edition.authored, edition.art, edition.positions) });
}

change stage_pixel_checkpoint(id: u32, revision: String, legacy: String, receipt: u32) -> Result<Unit, String>
    reads(JournalCursor, JournalCheckpointReceipts, EditorSource, EditorArtwork, EditorNamed, EditorPositions)
    writes(JournalVersions, JournalCheckpointReceipts) {
    if JournalCursor.revision != "" || id != session.receipt_count(JournalCheckpointReceipts) {
        return Err("Cannot stage a pixel checkpoint in an active journal");
    }
    let cursor = history.Cursor { revision: revision, legacy: legacy, receipt: receipt };
    JournalVersions.put(id, history.Edition { authored: EditorSource, art: EditorArtwork, named: EditorNamed,
        positions: EditorPositions, cursor: cursor });
    JournalCheckpointReceipts = session.append_receipt(JournalCheckpointReceipts, receipt);
    return Ok(());
}

change restore_pixel_checkpoint(revision: u64, limit: u32, undo: List<String>, redo: List<String>, draft: Option<String>)
    -> Result<mask.Grid, String> reads(JournalCursor, JournalVersions, JournalCheckpointReceipts)
    writes(JournalVersions, JournalCheckpointReceipts, JournalRevision, JournalLimit, JournalSerial, JournalCursor, JournalPast, JournalFuture,
        JournalDraft, EditorSource, EditorArtwork, EditorNamed, EditorPositions, EditorScope, EditorImage, EditorPaint) {
    let retained = session.count(undo, redo);
    if JournalCursor.revision != "" || !session.fits(retained, limit) || !session.safe_serial(revision) {
        return Err("Invalid authoring session or incompatible history limit");
    }
    let opened: history.Entry = session.saved_draft(draft, JournalCheckpointReceipts);
    let last = session.last_id(retained);
    let active = if opened.id == 0 { 1 } else { last + 1 };
    let serial = if opened.id == 0 { last } else { active };
    if session.receipt_count(JournalCheckpointReceipts) != serial + 1 {
        return Err("Missing pixel session history version");
    }
    let past = session.entries(JournalCheckpointReceipts, 2, undo);
    let future = session.entries(JournalCheckpointReceipts, session.future_id(undo), redo);
    let edition = JournalVersions.remove(active).ok_or("Missing pixel session history version")?;
    let grid = frame_raster.artwork_grid(edition.art);
    JournalRevision = revision;
    JournalLimit = limit;
    JournalSerial = serial;
    JournalCheckpointReceipts = [0];
    JournalCursor = edition.cursor;
    JournalPast = past;
    JournalFuture = future;
    JournalDraft = opened;
    EditorSource = edition.authored;
    EditorArtwork = edition.art;
    EditorNamed = edition.named;
    EditorPositions = edition.positions;
    EditorScope = frame_raster.Scope { frame: "", layer: "" };
    EditorImage = None;
    EditorPaint = paint.empty_cache();
    return Ok(grid);
}

pub fn pixel_checkpoint_identity(slot: String, legacy: json.Json, revision: u64) -> Result<u32, String> {
    return session.identity(slot, legacy, revision);
}

query resolve_pixel_edit(patch: json.Json) -> history.Command reads(EditorSource, EditorArtwork, JournalCursor) {
    return history.resolve(EditorSource, EditorArtwork, JournalCursor, patch);
}

query plan_pixel_command(command: json.Json) -> Result<commands.Plan, String> reads(EditorSource) {
    return commands.plan(EditorSource, command);
}

query plan_pixel_batch_step(command: json.Json) -> Result<commands.Plan, String> reads(EditorSource) {
    return commands.plan_batch_step(EditorSource, command);
}

query pixel_batch_draft() -> Result<batch.Draft, String> reads(JournalDraft, JournalVersions) {
    if JournalDraft.id == 0 { return Err("Open a pixel transaction before recording a batch"); }
    let base = JournalVersions.get(JournalDraft.id).ok_or("Missing pixel edit transaction")?;
    return Ok(batch.Draft { label: JournalDraft.label, receipt: base.cursor.receipt, anchor: batch.anchor(base.cursor) });
}

query pixel_batch_anchor() -> json.Json reads(JournalCursor) { return batch.anchor(JournalCursor); }

pub fn pixel_batch_plan(metadata: json.Json, length: u32) -> Result<String, String> {
    return batch.plan(metadata, length);
}

pub fn pixel_batch_count(length: u32) -> Result<Unit, String> { return batch.count(length); }

pub fn pixel_batch_receipt(receipt: json.Json) -> Result<Unit, String> { return batch.receipt(receipt); }

pub fn pixel_batch_input_changes(expected: json.Json, actual: json.Json) -> List<json.Json> {
    return batch.input_changes(expected, actual);
}

pub fn pixel_batch_same_target(before: json.Json, after: json.Json) -> Bool {
    return batch.same_target(before, after);
}

query describe_pixel_command_document() -> Result<json.Json, String> reads(EditorSource, EditorArtwork, JournalCursor) {
    return commands.describe(EditorSource, EditorArtwork, JournalCursor.revision);
}

query inspect_pixel_command(at: json.Json, options: json.Json) -> Result<inspection.Report, String>
    reads(EditorSource, EditorArtwork, JournalCursor) {
    return inspection.inspect(EditorSource, EditorArtwork, JournalCursor.revision, at, options);
}

query export_pixel_command_stamp(options: json.Json) -> Result<assets.Stamp, String> reads(EditorSource, EditorArtwork, EditorPositions) {
    return assets.stamp(EditorSource, EditorArtwork, EditorPositions, options);
}

query export_pixel_command_png(options: json.Json) -> Result<png.Image, String> reads(EditorSource, EditorArtwork) {
    return png.prepare(EditorSource, EditorArtwork, options);
}

query export_pixel_command_layer_deck() -> Result<assets.Deck, String> reads(EditorSource, EditorArtwork, EditorPositions) {
    return assets.deck(EditorSource, EditorArtwork, EditorPositions);
}

change observe_pixel_edit() -> Unit reads(EditorArtwork) writes(JournalEditCels) {
    JournalEditCels = history.affected_cels(EditorArtwork);
    return ();
}

query pixel_edit_links() -> Option<history.Links> reads(JournalEditCels, EditorArtwork) {
    return history.links(JournalEditCels, EditorArtwork.cels);
}

change observe_pixel_preview() -> Unit reads(EditorSource, EditorArtwork) writes(JournalPreview, JournalPreviewPair) {
    JournalPreview = preview.Page { source: EditorSource, art: EditorArtwork };
    JournalPreviewPair = None;
    return ();
}

query pixel_preview_diff(limit: u32, exact: Bool) -> Result<preview.Report, String>
    reads(JournalPreview, JournalPreviewPair, EditorSource, EditorArtwork) {
    if !exact {
        let saved = JournalPreviewPair.map(fn(pair) => preview.composite_diff(pair, limit));
        if saved.fold(fn(report) => true, fn(unit) => false) {
            return saved.ok_or("Missing the pixel edit preview");
        }
    }
    return preview.compare(JournalPreview.art, JournalPreview.source, EditorArtwork, EditorSource,
        preview.Settings { limit: limit, exact: exact });
}

query pixel_draft_diff(limit: u32, exact: Bool) -> Result<DraftPreview, String>
    reads(JournalDraft, JournalVersions, EditorSource, EditorArtwork) {
    if JournalDraft.id == 0 { return Err("No active transaction"); }
    let base = JournalVersions.get(JournalDraft.id).ok_or("Missing pixel edit transaction")?;
    let changes = preview.compare(base.art, base.authored, EditorArtwork, EditorSource,
        preview.Settings { limit: limit, exact: exact })?;
    return Ok(DraftPreview { changes: changes, receipt: JournalDraft.receipt,
        celLinks: history.links(history.affected_cels(base.art), EditorArtwork.cels) });
}

change accept_pixel_edit(revision: String, receipt: u32) -> Result<Unit, String>
    reads(JournalDraft, JournalCursor) writes(JournalCursor, JournalEditCels) {
    if JournalDraft.id == 0 { return Err("No active transaction"); }
    if receipt <= JournalCursor.receipt { return Err("Pixel edit receipt needs a new identity"); }
    JournalCursor = history.Cursor { revision: revision, legacy: "", receipt: receipt };
    JournalEditCels = [];
    return Ok(());
}

change commit_pixel_edit() -> Result<Bool, String>
    reads(JournalDraft, JournalCursor, JournalPast, JournalFuture, JournalLimit, JournalRevision)
    writes(JournalDraft, JournalPast, JournalFuture, JournalVersions, JournalRevision) {
    let draft = JournalDraft;
    if draft.id == 0 { return Err("No active transaction"); }
    JournalDraft = history.empty_entry();
    if draft.receipt == JournalCursor.receipt {
        JournalVersions.remove(draft.id);
        return Ok(false);
    }
    let next_revision = session.next_serial(JournalRevision)?;
    let rows = JournalPast.concat([draft]);
    let retain = mask.min(history.entry_count(rows), JournalLimit);
    let prune = history.entry_count(rows) - retain;
    JournalVersions.remove_many(history.retired(rows, prune, JournalFuture));
    JournalPast = history.kept(rows, prune);
    JournalFuture = [];
    JournalRevision = next_revision;
    return Ok(true);
}

change cancel_pixel_edit() -> Result<Bool, String>
    reads(JournalDraft, JournalVersions)
    writes(JournalDraft, JournalVersions, JournalCursor, EditorSource, EditorArtwork, EditorNamed, EditorPositions, EditorScope, EditorImage, EditorPaint) {
    let draft = JournalDraft;
    if draft.id == 0 { return Ok(false); }
    let prior = JournalVersions.remove(draft.id).ok_or("Missing pixel edit transaction")?;
    JournalCursor = prior.cursor;
    EditorSource = prior.authored;
    EditorArtwork = prior.art;
    EditorNamed = prior.named;
    EditorPositions = prior.positions;
    EditorScope = frame_raster.Scope { frame: "", layer: "" };
    EditorImage = None;
    EditorPaint = paint.empty_cache();
    JournalDraft = history.empty_entry();
    return Ok(true);
}

change travel_pixel_history(redo: Bool) -> Result<Bool, String>
    reads(JournalDraft, JournalPast, JournalFuture, JournalVersions, JournalCursor, JournalRevision, EditorSource, EditorArtwork, EditorNamed, EditorPositions)
    writes(JournalPast, JournalFuture, JournalVersions, JournalCursor, JournalRevision, EditorSource, EditorArtwork, EditorNamed, EditorPositions, EditorScope, EditorImage, EditorPaint) {
    if JournalDraft.id != 0 {
        return Err(if redo { "Finish the active transaction before redo" } else { "Finish the active transaction before undo" });
    }
    let rows = if redo { JournalFuture } else { JournalPast };
    if history.entry_count(rows) == 0 { return Ok(false); }
    let next_revision = session.next_serial(JournalRevision)?;
    let target = history.last(rows);
    let current = history.Edition { authored: EditorSource, art: EditorArtwork, named: EditorNamed,
        positions: EditorPositions, cursor: JournalCursor };
    let prior = JournalVersions.get(target.id).ok_or("Missing pixel edit history version")?;
    JournalVersions.put(target.id, current);
    let replacement = history.Entry { ..target, receipt: JournalCursor.receipt };
    if redo {
        JournalFuture = history.prefix(rows, history.entry_count(rows) - 1);
        JournalPast = JournalPast.concat([replacement]);
    } else {
        JournalPast = history.prefix(rows, history.entry_count(rows) - 1);
        JournalFuture = JournalFuture.concat([replacement]);
    }
    JournalCursor = prior.cursor;
    JournalRevision = next_revision;
    EditorSource = prior.authored;
    EditorArtwork = prior.art;
    EditorNamed = prior.named;
    EditorPositions = prior.positions;
    EditorScope = frame_raster.Scope { frame: "", layer: "" };
    EditorImage = None;
    EditorPaint = paint.empty_cache();
    return Ok(true);
}
