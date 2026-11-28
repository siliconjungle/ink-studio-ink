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
import "pixel_paint.ink" as paint;
import "pixel_timeline.ink" as timeline;

record Stamp { grid: mask.Grid, deck: Bool, animation: Bool, fps: f64,
    spec: List<json.Member>, frames: List<json.Json>, ids: List<String>, }
record Input { slots: List<i32>, alpha: List<u32>, knockouts: List<u32>, }
record Imported { document: json.Json, slots: List<frame.SlotPlane>, runs: List<frame.RunPlane>, }
record Cel { source: json.Member, slots: frame.SlotPlane, runs: frame.RunPlane, }
record Cels { values: Buffer<Cel>, issue: String, }
record Frame { source: json.Json, cels: List<Cel>, }
record Frames { values: Buffer<Frame>, issue: String, }
record Planes { slots: Buffer<frame.SlotPlane>, runs: Buffer<frame.RunPlane>, }
record Names { ids: List<String>, rows: Buffer<json.Json>, }
record Change { index: u32, layer: String, info: json.Json, pixels: assets.Raster, write_alpha: Bool, }
record Changes { rows: Buffer<Change>, issue: String, }
record Save { original: Stamp, baseline: frame.Artwork, edited: frame.Artwork, }

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

fn read_pixels(g: mask.Grid, spec: List<json.Member>, input: Input) -> Result<List<i32>, String> {
    let size = mask.size(g);
    let by_row = value.has(spec, "rows");
    let by_slot = value.has(spec, "slots");
    if by_row && by_slot { return Err("A stamp cel needs slots or rows"); }
    if by_slot && !array(value.get(spec, "slots")) {
        return Err("Stamp rows and slots need one valid index or transparent cell per pixel");
    }
    let base = if by_row { read_rows(g, value.get(spec, "rows")) } else {
        if by_slot { input.slots } else { buffer_fill(size, -1).freeze() }
    };
    if length(base) != size || fold_until(base, false, fn(slot) => fn(bad) => bad,
        fn(slot) => fn(bad) => bad || slot < -1 || slot > 16777213) {
        return Err("Stamp rows and slots need one valid index or transparent cell per pixel");
    }
    let strokes = value.get(spec, "strokes");
    let shapes = value.items(strokes);
    if value.has(spec, "strokes") && (!array(strokes) || length(shapes) > 4096) {
        return Err("A stamp cel supports at most 4096 ordered strokes");
    }
    return raster.stamp_slots(g, base, shapes);
}

fn span_group(words: List<u32>, group: png.Mark) -> List<u32> {
    let start: Buffer<u32> = Buffer.empty();
    return repeat_until(group.length, start, fn(out) => false, fn(i) => fn(out) =>
        out.push(words.at_or(group.first + i, 0))).freeze();
}

fn mark(group: png.Mark) -> json.Json {
    let channel = if group.alpha == 255 { member("swatch", json.null()) } else { member("alpha", num(group.alpha)) };
    return json.object([channel, member("runs", json.array([]))]);
}

fn cel_marks(g: mask.Grid, spec: List<json.Member>, slots: List<i32>, input: Input) -> Result<png.PackedMarks, String> {
    let size = mask.size(g);
    if value.has(spec, "alpha") && (!array(value.get(spec, "alpha")) || !png.alpha_valid(input.alpha, size)) {
        return Err("Stamp alpha needs one byte per texel");
    }
    if value.has(spec, "knockouts") && (!array(value.get(spec, "knockouts")) || !png.knockouts_valid(input.knockouts, slots)) {
        return Err("Knockouts must be sorted locations of transparent pixels");
    }
    return Ok(png.packed_marks(g.width, slots, input.alpha, input.knockouts));
}

fn authored(stamp: Stamp, count: u32, id: String, row: json.Member, input: Input) -> Result<Cel, String> {
    if !object(row.value) { return Err("Expected an indexed stamp cel"); }
    let spec = value.fields(row.value);
    let slots = read_pixels(stamp.grid, spec, input)?;
    if !png.slots_valid(slots, mask.size(stamp.grid), count) { return Err("Stamp slots must refer to the ordered palette"); }
    let marks = cel_marks(stamp.grid, spec, slots, input)?;
    let own: List<json.Member> = if stamp.deck { accepted(spec, ["id", "label", "opacity"]) } else { [] };
    let metadata = own.concat([member("slots", json.array([])), member("marks", json.array(marks.marks.map(fn(row) => mark(row))))]);
    let spans = marks.marks.map(fn(row) => span_group(marks.spans, row));
    return Ok(Cel { source: member(row.key, json.object(metadata)),
        slots: frame.SlotPlane { frame: id, layer: row.key, pixels: slots },
        runs: frame.RunPlane { frame: id, layer: row.key, marks: spans } });
}

fn collect_frame(row: Result<Frame, String>, out: Frames) -> Frames {
    return match row {
        Ok(ready) => Frames { ..out, values: out.values.push(ready) },
        Err(issue) => Frames { ..out, issue: issue },
    };
}
fn collect_cel(row: Result<Cel, String>, out: Cels) -> Cels {
    return match row {
        Ok(cel) => Cels { ..out, values: out.values.push(cel) },
        Err(issue) => Cels { ..out, issue: issue },
    };
}

fn layer_fields(stamp: Stamp, raw: json.Json) -> Result<List<json.Member>, String> {
    if !stamp.deck { return Ok([member("image", raw)]); }
    let spec = value.fields(raw);
    let cels = value.get(spec, "cels");
    if value.has(spec, "cels") && !object(cels) { return Err("A deck frame needs an object of cels"); }
    return Ok(value.fields(cels));
}

fn authored_frame(stamp: Stamp, count: u32, i: u32, input: List<Input>) -> Result<Frame, String> {
    let raw = stamp.frames.at_or(i, json.null());
    let spec = value.fields(raw);
    let time = if stamp.animation { json.lookup(spec, "duration").fold(fn(raw) => value.number(raw), fn(unit) => 1.0f64 / stamp.fps) }
        else { 1.0f64 / stamp.fps };
    let millis = time * 1000.0f64;
    if !is_finite(millis) || time <= 0.0f64 || millis > 9007199254740991.0f64 {
        return Err("Stamp frame durations must be positive and fit the editable timeline");
    }
    let layers = layer_fields(stamp, raw)?;
    if length(layers) != length(input) { return Err("Stamp raster planes do not match their frame"); }
    let id = stamp.ids.at_or(i, "");
    let start = Cels { values: Buffer.empty(), issue: "" };
    let made = repeat_until(length(layers), start, fn(out) => out.issue != "", fn(j) => fn(out) =>
        collect_cel(authored(stamp, count, id, layers.at_or(j, member("", json.null())),
            input.at_or(j, Input { slots: [], alpha: [], knockouts: [] })), out));
    if made.issue != "" { return Err(made.issue); }
    let cels = made.values.freeze();
    let label = if stamp.animation { accepted(spec, ["label"]) } else { [] };
    let metadata = [member("id", json.text(id)), member("durationMs", timeline.number(value.max(1.0f64, floor(millis + 0.5f64)))),
        member("cels", json.object(cels.map(fn(cel) => cel.source)))].concat(label);
    return Ok(Frame { source: json.object(metadata), cels: cels });
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

fn import_stamp(source: json.Json, input: List<List<Input>>) -> Result<Imported, String> {
    let stamp = parse(source)?;
    if !valid_masks(stamp.spec, "sharedSelections") ||
        length(stamp.frames.filter(fn(row) => !valid_masks(value.fields(row), "selections"))) != 0 {
        return Err("Saved stamp masks need unique IDs in their scope and native pixels");
    }
    if length(stamp.ids) != length(input) { return Err("Stamp raster planes do not match the timeline"); }
    let colors = palette(stamp)?;
    let start = Frames { values: Buffer.empty(), issue: "" };
    let rows = repeat_until(length(stamp.ids), start, fn(out) => out.issue != "", fn(i) => fn(out) =>
        collect_frame(authored_frame(stamp, length(colors.ids), i, input.at_or(i, [])), out));
    if rows.issue != "" { return Err(rows.issue); }
    let frames = rows.values.freeze();
    let document = json.object(metadata(stamp, colors).concat([member("frames", json.array(frames.map(fn(row) => row.source)))]));
    let empty = Planes { slots: Buffer.empty(), runs: Buffer.empty() };
    let planes = foldl(frames, empty, fn(row) => fn(out) => append_planes(row.cels, out));
    return Ok(Imported { document: document, slots: planes.slots.freeze(), runs: planes.runs.freeze() });
}

fn append_planes(cels: List<Cel>, out: Planes) -> Planes {
    return foldl(cels, out, fn(cel) => fn(next) =>
        Planes { slots: next.slots.push(cel.slots), runs: next.runs.push(cel.runs) });
}

fn raster_change(save: Save, index: u32, cel: frame.Cel, info: List<json.Member>) -> Result<Change, String> {
    let raw = frame.cel_raster(save.edited, cel, raster.untouched());
    if raw.issue != "" { return Err(raw.issue); }
    let result = assets.raw(frame.Captured { found: true, slots: raw.slots, alpha: raw.alpha, clipping: [] });
    let write_alpha = value.has(info, "alpha") || fold_until(result.alpha, false, fn(a) => fn(any) => any,
        fn(a) => fn(any) => any || a != 255);
    let keep = without(info, ["slots", "rows", "strokes", "alpha", "knockouts"]);
    return Ok(Change { index: index, layer: cel.layer, info: json.object(keep), pixels: result, write_alpha: write_alpha });
}

fn same_planes(save: Save, before: frame.Cel, now: frame.Cel) -> Bool {
    return packed_plane<i32>(save.baseline.planes, before.plane) == packed_plane<i32>(save.edited.planes, now.plane) &&
        packed_plane<List<u32>>(save.baseline.run_planes, before.run_plane) == packed_plane<List<u32>>(save.edited.run_planes, now.run_plane);
}

fn packed_plane<T>(planes: List<List<T>>, id: u32) -> List<T> {
    return if id == 0 { [] } else { planes.at_or(id - 1, []) };
}

fn saved_cel(save: Save, index: u32, id: String, row: json.Member, original: json.Json, out: Changes) -> Changes {
    if out.issue != "" { return out; }
    let before = frame.active_cel(save.baseline.cels, id, row.key);
    let now = frame.active_cel(save.edited.cels, id, row.key);
    let edited = value.fields(row.value);
    if edited == before.fields && before.runs == now.runs && same_planes(save, before, now) { return out; }
    let keys: List<String> = ["slots", "marks"];
    let old_fields = without(before.fields, keys);
    let current_fields = without(edited, keys);
    if (before.id != "" && old_fields != current_fields) ||
        (before.id == "" && length(without(current_fields, ["id", "label", "opacity"])) != 0) {
        return Changes { ..out, issue: "A Workshop stamp export only accepts raster changes to its cels" };
    }
    let info = if original == json.null() { current_fields } else { value.fields(original) };
    return match raster_change(save, index, now, info) {
        Ok(change) => Changes { ..out, rows: out.rows.push(change) },
        Err(issue) => Changes { ..out, issue: issue },
    };
}

fn saved_frame(save: Save, index: u32, old: json.Json, now: json.Json, out: Changes) -> Changes {
    let source = save.original.frames.at_or(index, json.null());
    let prior = value.fields(old);
    let edited = value.fields(now);
    if without(prior, ["cels"]) != without(edited, ["cels"]) {
        return Changes { ..out, issue: "A Workshop stamp export only accepts raster changes within its original timeline" };
    }
    let id = frame.frame_name(now);
    let previous = value.fields(value.get(prior, "cels"));
    let current = value.fields(value.get(edited, "cels"));
    if length(previous.filter(fn(row) => !value.has(current, row.key))) != 0 {
        return Changes { ..out, issue: "A Workshop stamp export cannot delete its original cels" };
    }
    let cels = if save.original.deck { value.fields(value.get(value.fields(source), "cels")) }
        else { [member("image", source)] };
    return fold_until(current, out, fn(row) => fn(next) => next.issue != "", fn(row) => fn(next) =>
        saved_cel(save, index, id, row, value.get(cels, row.key), next));
}

fn attach(document: json.Json, slots: List<frame.SlotPlane>, runs: List<frame.RunPlane>) -> Result<frame.Artwork, String> {
    let art = frame.attach_planes(frame.prepare(document), slots)?;
    return frame.attach_run_planes(art, runs);
}

fn export_stamp(source: json.Json, baseline: Imported, document: json.Json, slots: List<frame.SlotPlane>,
    runs: List<frame.RunPlane>) -> Result<List<Change>, String> {
    let before = attach(baseline.document, baseline.slots, baseline.runs)?;
    let after = attach(document, slots, runs)?;
    return export_art(source, baseline.document, before, document, after);
}

fn export_art(source: json.Json, before_document: json.Json, before: frame.Artwork,
    document: json.Json, after: frame.Artwork) -> Result<List<Change>, String> {
    let stamp = parse(source)?;
    let original = value.fields(before_document);
    let current = value.fields(document);
    let frames = value.items(value.get(current, "frames"));
    let prior = value.items(value.get(original, "frames"));
    if length(frames) != length(stamp.frames) || length(prior) != length(frames) ||
        without(original, ["frames"]) != without(current, ["frames"]) {
        return Err("A Workshop stamp export only accepts raster changes to the imported document");
    }
    if stamp.deck && !fits_deck(current, frames, stamp.grid) {
        return Err("Layer deck exceeds the native pixel budget");
    }
    let save = Save { original: stamp, baseline: before, edited: after };
    let start = Changes { rows: Buffer.empty(), issue: "" };
    let saved = repeat_until(length(frames), start, fn(out) => out.issue != "", fn(i) => fn(out) =>
        saved_frame(save, i, prior.at_or(i, json.null()), frames.at_or(i, json.null()), out));
    if saved.issue != "" { return Err(saved.issue); }
    return Ok(saved.rows.freeze());
}
