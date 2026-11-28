module StudioPixelWorkshopStamp;

import "std:json" as json;
import "pixel_values.ink" as value;
import "pixel_labels.ink" as labels;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_raster.ink" as raster;
import "pixel_frame.ink" as frame;
import "pixel_asset_export.ink" as assets;
import "pixel_png_import.ink" as png;
import "pixel_run_words.ink" as runs;
import "pixel_paint.ink" as paint;
import "pixel_timeline.ink" as timeline;

record Stamp { grid: mask.Grid, deck: Bool, animation: Bool, fps: f64,
    spec: List<json.Member>, frames: List<json.Json>, ids: List<String>, }
record Rows { values: Buffer<json.Json>, issue: String, }
record Members { values: Buffer<json.Member>, issue: String, }
record Names { ids: List<String>, rows: Buffer<json.Json>, }

fn member(key: String, raw: json.Json) -> json.Member { return history.member(key, raw); }
fn num(n: u32) -> json.Json { return json.number(paint.number(n)); }
fn object(raw: json.Json) -> Bool { return json.members(raw).fold(fn(items) => true, fn(issue) => false); }
fn array(raw: json.Json) -> Bool { return json.elements(raw).fold(fn(items) => true, fn(issue) => false); }
fn accepted(fields: List<json.Member>, keys: List<String>) -> List<json.Member> {
    return fields.filter(fn(row) => length(keys.filter(fn(key) => row.key == key)) != 0);
}
fn without(fields: List<json.Member>, keys: List<String>) -> List<json.Member> {
    return fields.filter(fn(row) => length(keys.filter(fn(key) => row.key == key)) == 0);
}

fn parse(source: json.Json) -> Result<Stamp, String> {
    let spec = value.fields(source);
    let width = value.word(value.get(spec, "width"), 512);
    let height = value.word(value.get(spec, "height"), 512);
    let animation = value.has(spec, "frames");
    let deck = value.text(value.get(spec, "format")) == "ink-studio/pixel-layer-deck";
    let raw = value.get(spec, "frames");
    let frames = if animation { value.items(raw) } else { [source] };
    if width == 0 || width > 512 || height == 0 || height > 512 || length(frames) == 0 ||
        length(frames) > 2048 || width * height * length(frames) > 1048576 {
        return Err("Open a stamp up to 512 × 512 within the animation pixel budget");
    }
    if animation && (!array(raw) || length(accepted(spec, ["slots", "rows", "strokes", "alpha", "selections"])) != 0) {
        return Err("Save pixels and masks on their own stamp frames");
    }
    if !animation && length(accepted(spec, ["slots", "rows", "strokes"])) == 0 {
        return Err("A still stamp needs texels or paint strokes");
    }
    if deck && (!animation || value.word(value.get(spec, "version"), 1) != 1) ||
        !deck && (value.has(spec, "layers") || value.has(spec, "tilemap")) {
        return Err("Layered artwork and tilemaps need a version 1 layer deck");
    }
    let grid = mask.Grid { width: width, height: height };
    if deck && !fits_deck(spec, frames, grid) { return Err("Layer deck exceeds the native pixel budget"); }
    let stamp = Stamp { grid: grid, deck: deck, animation: animation, fps: 12.0f64, spec: spec, frames: frames, ids: [] };
    return play_settings(stamp);
}

fn fits_deck(spec: List<json.Member>, frames: List<json.Json>, grid: mask.Grid) -> Bool {
    let layers = value.items(value.get(spec, "layers"));
    let zero: u32 = 0;
    let budget: u32 = 4000000;
    let cells = foldl(frames, zero, fn(row) => fn(count) => count + length(value.fields(value.get(value.fields(row), "cels"))));
    let cell_budget = quot_or(budget, mask.size(grid), 0);
    return length(layers) != 0 && length(layers) <= 64 && cells <= cell_budget && length(layers) <= cell_budget;
}

fn play_settings(stamp: Stamp) -> Result<Stamp, String> {
    let fps = json.lookup(stamp.spec, "fps").fold(fn(raw) => value.number(raw), fn(unit) => 12.0f64);
    let phase = json.lookup(stamp.spec, "phase").fold(fn(raw) => value.number(raw), fn(unit) => 0.0f64);
    let playback = json.lookup(stamp.spec, "playback").fold(fn(raw) => value.text(raw), fn(unit) => "loop");
    if !is_finite(fps) || fps <= 0.0f64 || !is_finite(phase) || !(playback == "loop" || playback == "once") {
        return Err("Stamp playback needs a positive frame rate and a finite phase");
    }
    if length(stamp.frames.filter(fn(row) => !object(row))) != 0 { return Err("Expected stamp frame objects"); }
    let ids = frame_ids(stamp)?;
    return Ok(Stamp { ..stamp, fps: fps, ids: ids });
}

fn frame_ids(stamp: Stamp) -> Result<List<String>, String> {
    let supplied = stamp.frames.filter(fn(row) => stamp.animation && value.has(value.fields(row), "id"))
        .map(fn(row) => frame.frame_name(row));
    if (stamp.deck || length(value.items(value.get(stamp.spec, "tags"))) != 0) &&
        !png.valid_aliases(supplied, length(supplied)) {
        return Err("Tagged animations and layer decks need stable, unique frame IDs");
    }
    let reserved = supplied.filter(fn(id) => labels.stable_id(id));
    return Ok(repeat_until(length(stamp.frames), [], fn(ids) => false, fn(i) => fn(ids) =>
        ids.concat([frame_id(stamp, reserved, ids, i)])));
}

fn frame_id(stamp: Stamp, reserved: List<String>, seen: List<String>, i: u32) -> String {
    let supplied = if stamp.animation { frame.frame_name(stamp.frames.at_or(i, json.null())) } else { "" };
    if labels.stable_id(supplied) && !png.included(seen, supplied) { return supplied; }
    return unique(reserved.concat(seen), string_concat("frame-", paint.number(i + 1)));
}

fn unique(ids: List<String>, stem: String) -> String {
    if !png.included(ids, stem) { return stem; }
    return repeat_until(length(ids), "", fn(found) => found != "", fn(i) => fn(found) =>
        unused(ids, string_concat(stem, string_concat("-", paint.number(i + 2)))));
}
fn unused(ids: List<String>, id: String) -> String {
    return if png.included(ids, id) { "" } else { id };
}

fn palette(stamp: Stamp) -> Result<png.Palette, String> {
    let colors = value.items(value.get(stamp.spec, "palette"));
    if length(colors) == 0 || length(colors) > 255 ||
        length(colors.filter(fn(raw) => !labels.rgb(value.text(raw)))) != 0 {
        return Err("The Workshop needs 1–255 hex swatches");
    }
    let ids = json.lookup(stamp.spec, "swatchIds").fold(fn(raw) => value.items(raw).map(fn(id) => value.text(id)),
        fn(unit) => colors.map_indexed(fn(i) => fn(color) => string_concat("slot-", paint.number(i))));
    if !png.valid_aliases(ids, length(colors)) { return Err("Swatch IDs must be unique and match the palette order"); }
    return png.metadata_palette(colors, ids, stamp.spec);
}

fn read_slot(raw: json.Json) -> i32 {
    return if raw == json.null() { -1 } else { value.integer(raw, 0, 16777213).fold(fn(n) => n, fn(unit) => -3) };
}
fn row_slot(code: u32) -> i32 {
    if code == 46 { return -1; }
    if code >= 48 && code <= 57 { return raster.signed_slot(code - 48); }
    if code >= 65 && code <= 90 { return raster.signed_slot(code - 55); }
    if code >= 97 && code <= 122 { return raster.signed_slot(code - 61); }
    return -3;
}
fn read_rows(g: mask.Grid, raw: json.Json) -> List<i32> {
    let rows = value.items(raw).map(fn(row) => value.text(row));
    if length(rows) != g.height || length(rows.filter(fn(row) => string_byte_len(row) != g.width)) != 0 { return []; }
    let start: Buffer<i32> = Buffer.empty();
    return repeat_until(mask.size(g), start, fn(out) => false, fn(p) => fn(out) =>
        out.push(slot_at(rows, g.width, p))).freeze();
}
fn slot_at(rows: List<String>, width: u32, p: u32) -> i32 {
    let row = rows.at_or(quot_or(p, width, 0), "");
    return row_slot(string_byte_at(row, rem_or(p, width, 0)).fold(fn(byte) => byte, fn(unit) => 0));
}

fn spans(words: List<u32>, group: png.Mark) -> json.Json {
    let start: Buffer<json.Json> = Buffer.empty();
    let rows = repeat_until(group.length, start, fn(out) => false, fn(i) => fn(out) =>
        out.push(span(words.at_or(group.first + i, 0))));
    return json.array(rows.freeze());
}
fn span(word: u32) -> json.Json {
    let at = runs.unpack(word);
    return json.array([num(at.x), num(at.y), num(at.z)]);
}
fn mark(words: List<u32>, group: png.Mark) -> json.Json {
    let channel = if group.alpha == 255 { member("swatch", json.null()) } else { member("alpha", num(group.alpha)) };
    return json.object([channel, member("runs", spans(words, group))]);
}

fn read_pixels(g: mask.Grid, spec: List<json.Member>) -> Result<List<i32>, String> {
    let size = mask.size(g);
    let by_row = value.has(spec, "rows");
    let by_slot = value.has(spec, "slots");
    if by_row && by_slot { return Err("A stamp cel needs slots or rows"); }
    let base = if by_row { read_rows(g, value.get(spec, "rows")) } else {
        if by_slot { value.items(value.get(spec, "slots")).map(fn(raw) => read_slot(raw)) }
        else { buffer_fill(size, -1).freeze() }
    };
    if length(base) != size || length(base.filter(fn(slot) => slot == -3)) != 0 {
        return Err("Stamp rows and slots need one valid index or transparent cell per pixel");
    }
    let strokes = value.get(spec, "strokes");
    let shapes = value.items(strokes);
    if value.has(spec, "strokes") && (!array(strokes) || length(shapes) > 4096) {
        return Err("A stamp cel supports at most 4096 ordered strokes");
    }
    return raster.stamp_slots(g, base, shapes);
}

fn authored(g: mask.Grid, ids: List<String>, raw: json.Json, deck: Bool) -> Result<json.Json, String> {
    if !object(raw) { return Err("Expected an indexed stamp cel"); }
    let spec = value.fields(raw);
    let slots = read_pixels(g, spec)?;
    if !png.slots_valid(slots, mask.size(g), length(ids)) { return Err("Stamp slots must refer to the ordered palette"); }
    let marks = cel_marks(g, spec, slots)?;
    let colors = slots.map(fn(slot) => if slot < 0 { json.null() } else { json.text(ids.at_or(png.slot_word(slot), "")) });
    let own: List<json.Member> = if deck { accepted(spec, ["id", "label", "opacity"]) } else { [] };
    return Ok(json.object(own.concat([member("slots", json.array(colors)), member("marks", json.array(marks))])));
}

fn cel_marks(g: mask.Grid, spec: List<json.Member>, slots: List<i32>) -> Result<List<json.Json>, String> {
    let size = mask.size(g);
    let alpha = value.items(value.get(spec, "alpha")).map(fn(a) => value.word(a, 255));
    if value.has(spec, "alpha") && !png.alpha_valid(alpha, size) { return Err("Stamp alpha needs one byte per texel"); }
    let erased = value.get(spec, "knockouts");
    let knockouts = value.items(erased).map(fn(p) => value.word(p, size - 1));
    if value.has(spec, "knockouts") && (!array(erased) || !png.knockouts_valid(knockouts, slots)) {
        return Err("Knockouts must be sorted locations of transparent pixels");
    }
    let marks = png.packed_marks(g.width, slots, alpha, knockouts);
    return Ok(marks.marks.map(fn(row) => mark(marks.spans, row)));
}

fn collect(row: Result<json.Json, String>, out: Rows) -> Rows {
    return match row {
        Ok(raw) => Rows { ..out, values: out.values.push(raw) },
        Err(issue) => Rows { ..out, issue: issue },
    };
}
fn collect_member(key: String, row: Result<json.Json, String>, out: Members) -> Members {
    return match row {
        Ok(raw) => Members { ..out, values: out.values.push(member(key, raw)) },
        Err(issue) => Members { ..out, issue: issue },
    };
}
fn new_rows() -> Rows { return Rows { values: Buffer.empty(), issue: "" }; }
fn new_members() -> Members { return Members { values: Buffer.empty(), issue: "" }; }

fn authored_frame(stamp: Stamp, ids: List<String>, i: u32) -> Result<json.Json, String> {
    let raw = stamp.frames.at_or(i, json.null());
    let spec = value.fields(raw);
    let time = if stamp.animation { json.lookup(spec, "duration").fold(fn(raw) => value.number(raw), fn(unit) => 1.0f64 / stamp.fps) }
        else { 1.0f64 / stamp.fps };
    let millis = time * 1000.0f64;
    if !is_finite(millis) || time <= 0.0f64 || millis > 9007199254740991.0f64 {
        return Err("Stamp frame durations must be positive and fit the editable timeline");
    }
    let cels = value.get(spec, "cels");
    if stamp.deck && value.has(spec, "cels") && !object(cels) { return Err("A deck frame needs an object of cels"); }
    let layers = if stamp.deck { value.fields(cels) } else { [member("image", raw)] };
    let made = fold_until(layers, new_members(), fn(row) => fn(out) => out.issue != "", fn(row) => fn(out) =>
        if out.issue != "" { out } else { collect_member(row.key, authored(stamp.grid, ids, row.value, stamp.deck), out) });
    if made.issue != "" { return Err(made.issue); }
    let label = if stamp.animation { accepted(spec, ["label"]) } else { [] };
    return Ok(json.object([member("id", json.text(stamp.ids.at_or(i, ""))),
        member("durationMs", timeline.number(value.max(1.0f64, floor(millis + 0.5f64)))),
        member("cels", json.object(made.values.freeze()))].concat(label)));
}

fn scope(raw: json.Json, id: String) -> json.Json {
    return json.object(without(value.fields(raw), ["frame"]).concat([member("frame", json.text(id))]));
}
fn scoped_assets(stamp: Stamp, key: String, shared: String) -> List<json.Json> {
    let all = value.items(value.get(stamp.spec, shared));
    return repeat_until(length(stamp.frames), all, fn(out) => false, fn(i) => fn(out) =>
        out.concat(value.items(value.get(value.fields(stamp.frames.at_or(i, json.null())), key)).map(fn(row) =>
            scope(row, stamp.ids.at_or(i, "")))));
}
fn save_name(raw: json.Json, reserved: List<String>, i: u32, out: Names) -> Names {
    let fields = value.fields(raw);
    let id = value.text(value.get(fields, "id"));
    if !png.included(out.ids, id) { return Names { ids: out.ids.concat([id]), rows: out.rows.push(raw) }; }
    let alias = unique(reserved, string_concat("stamp-mask-", paint.number(i + 1)));
    return Names { ids: out.ids.concat([alias]), rows: out.rows.push(json.object(paint.replace(fields, "id", json.text(alias)))) };
}
fn masks(stamp: Stamp) -> List<json.Json> {
    let rows = scoped_assets(stamp, "selections", "sharedSelections");
    let reserved = rows.map(fn(raw) => frame.frame_name(raw));
    let initial = Names { ids: [], rows: Buffer.empty() };
    let named = repeat_until(length(rows), initial, fn(out) => false, fn(i) => fn(out) =>
        save_name(rows.at_or(i, json.null()), reserved, i, out));
    return named.rows.freeze();
}
fn optional_rows(key: String, rows: List<json.Json>) -> List<json.Member> {
    return if length(rows) == 0 { [] } else { [member(key, json.array(rows))] };
}

fn mask_scope(raw: json.Json) -> Bool {
    let fields = value.fields(raw);
    return value.only(fields, ["id", "pixels"]) && array(value.get(fields, "pixels"));
}
fn valid_masks(spec: List<json.Member>, key: String) -> Bool {
    if !value.has(spec, key) { return true; }
    let raw = value.get(spec, key);
    let rows = value.items(raw);
    return array(raw) && length(rows.filter(fn(row) => !mask_scope(row))) == 0 &&
        png.valid_aliases(rows.map(fn(row) => frame.frame_name(row)), length(rows));
}
fn metadata(stamp: Stamp, colors: png.Palette) -> List<json.Member> {
    let own = accepted(stamp.spec, ["width", "height", "sceneBindings", "destinations", "protectedDetails",
        "legacyMetadata", "artRules", "tags", "directional", "tilemap", "slices"]);
    let aspect = json.lookup(stamp.spec, "pixelAspect").fold(fn(raw) => raw, fn(unit) => json.array([num(1), num(1)]));
    let layers = if stamp.deck { value.get(stamp.spec, "layers") }
        else { json.array([json.object([member("id", json.text("image"))])]) };
    let guides = if stamp.animation { scoped_assets(stamp, "guides", "guides") } else { value.items(value.get(stamp.spec, "guides")) };
    return [member("format", json.text("ink-studio/pixel-art")), member("version", num(2)),
        member("pixelAspect", aspect), member("palette", json.object(colors.entries)), member("layers", layers)]
        .concat(own).concat(optional_rows("guides", guides)).concat(optional_rows("selections", masks(stamp)))
        .concat(optional_rows("ramps", colors.ramps));
}

fn import_stamp(source: json.Json) -> Result<json.Json, String> {
    let stamp = parse(source)?;
    if !valid_masks(stamp.spec, "sharedSelections") ||
        length(stamp.frames.filter(fn(row) => !valid_masks(value.fields(row), "selections"))) != 0 {
        return Err("Saved stamp masks need unique IDs in their scope and native pixels");
    }
    let colors = palette(stamp)?;
    let rows = repeat_until(length(stamp.ids), new_rows(), fn(out) => out.issue != "",
        fn(i) => fn(out) => collect(authored_frame(stamp, colors.ids, i), out));
    if rows.issue != "" { return Err(rows.issue); }
    return Ok(json.object(metadata(stamp, colors).concat([member("frames", json.array(rows.values.freeze()))])));
}

fn raster_fields(g: mask.Grid, art: frame.Artwork, id: String, layer: String,
    original: List<json.Member>) -> Result<List<json.Member>, String> {
    let cel = frame.active_cel(art.cels, id, layer);
    let raw = frame.cel_raster(art, cel, raster.untouched());
    if raw.issue != "" { return Err(raw.issue); }
    let result = assets.raw(frame.Captured { found: true, slots: raw.slots, alpha: raw.alpha, clipping: [] });
    let slots = result.slots.map(fn(slot) => if slot < 0 { json.null() } else { num(png.slot_word(slot)) });
    let keep_alpha = value.has(original, "alpha") || length(result.alpha.filter(fn(a) => a != 255)) != 0;
    let alpha = if keep_alpha { alpha_fields(g, result.alpha) } else { [] };
    let cleared: List<json.Json> = result.knockouts.map(fn(p) => num(p));
    let keep = without(original, ["slots", "rows", "strokes", "alpha", "knockouts"]);
    return Ok(keep.concat([member("slots", json.array(slots))]).concat(alpha).concat(optional_rows("knockouts", cleared)));
}

fn alpha_fields(g: mask.Grid, opacity: List<u32>) -> List<json.Member> {
    let opaque: u32 = 255;
    let bytes = if length(opacity) == 0 { buffer_fill(mask.size(g), opaque).freeze() } else { opacity };
    return [member("alpha", json.array(bytes.map(fn(a) => num(a))))];
}

fn saved_cel(g: mask.Grid, art: frame.Artwork, id: String, layer: String, old: json.Json,
    now: json.Json, original: json.Json) -> Result<json.Json, String> {
    if now == old { return Ok(original); }
    let source = value.fields(original);
    let metadata_keys: List<String> = ["slots", "marks"];
    let old_fields = without(value.fields(old), metadata_keys);
    let current_fields = without(value.fields(now), metadata_keys);
    if now == json.null() || (old != json.null() && old_fields != current_fields) ||
        (old == json.null() && length(without(current_fields, ["id", "label", "opacity"])) != 0) {
        return Err("A Workshop stamp export only accepts raster changes to its cels");
    }
    let info = if original == json.null() { current_fields } else { source };
    let updated = raster_fields(g, art, id, layer, info)?;
    return Ok(json.object(updated));
}

fn saved_frame(stamp: Stamp, art: frame.Artwork, i: u32, old: json.Json, now: json.Json) -> Result<json.Json, String> {
    let source = stamp.frames.at_or(i, json.null());
    if old == now { return Ok(source); }
    let prior = value.fields(old);
    let edited = value.fields(now);
    if without(prior, ["cels"]) != without(edited, ["cels"]) {
        return Err("A Workshop stamp export only accepts raster changes within its original timeline");
    }
    let id = frame.frame_name(now);
    let previous = value.fields(value.get(prior, "cels"));
    let current = value.fields(value.get(edited, "cels"));
    if length(previous.filter(fn(row) => !value.has(current, row.key))) != 0 { return Err("A Workshop stamp export cannot delete its original cels"); }
    if !stamp.deck { return saved_cel(stamp.grid, art, id, "image", value.get(previous, "image"), value.get(current, "image"), source); }
    let original = value.fields(value.get(value.fields(source), "cels"));
    let rebuilt = fold_until(current, new_members(), fn(cel) => fn(out) => out.issue != "", fn(cel) => fn(out) =>
        if out.issue != "" { out } else { collect_member(cel.key, saved_cel(stamp.grid, art, id, cel.key,
            value.get(previous, cel.key), cel.value, value.get(original, cel.key)), out) });
    if rebuilt.issue != "" { return Err(rebuilt.issue); }
    return Ok(json.object(paint.replace(value.fields(source), "cels", json.object(rebuilt.values.freeze()))));
}

fn export_stamp(source: json.Json, baseline: json.Json, document: json.Json) -> Result<json.Json, String> {
    let stamp = parse(source)?;
    let original = value.fields(baseline);
    let current = value.fields(document);
    let frames = value.items(value.get(current, "frames"));
    let prior = value.items(value.get(original, "frames"));
    if length(frames) != length(stamp.frames) || length(prior) != length(frames) ||
        without(original, ["frames"]) != without(current, ["frames"]) {
        return Err("A Workshop stamp export only accepts raster changes to the imported document");
    }
    if baseline == document { return Ok(source); }
    let art = frame.prepare(document);
    let saved = repeat_until(length(frames), new_rows(), fn(out) => out.issue != "", fn(i) => fn(out) =>
        collect(saved_frame(stamp, art, i, prior.at_or(i, json.null()), frames.at_or(i, json.null())), out));
    if saved.issue != "" { return Err(saved.issue); }
    let rest = saved.values.freeze();
    return Ok(if stamp.animation { json.object(paint.replace(stamp.spec, "frames", json.array(rest))) }
        else { rest.at_or(0, source) });
}
