module StudioPixelPngImport;

import "std:json" as json;
import "pixel_values.ink" as value;
import "pixel_labels.ink" as labels;
import "pixel_frame.ink" as frame;
import "pixel_brush_paint.ink" as color;
import "pixel_paint.ink" as paint;
import "pixel_asset_export.ink" as assets;
import "pixel_png.ink" as png;
import "pixel_png_input.ink" as input;
import "pixel_run_words.ink" as run_words;

record Palette { entries: List<json.Member>, colors: List<u32>, ids: List<String>, ramps: List<json.Json>, }
record Decoded { palette: Palette, slots: List<i32>, alpha: List<u32>, knockouts: List<u32>, }
record Colors { seen: Map<u32, i32>, palette: Buffer<u32>, slots: Buffer<i32>, full: Bool, }
record Mark { alpha: u32, first: u32, length: u32, }
record Document { template: json.Json, slots: List<i32>, marks: List<Mark>, spans: List<u32>, }
record PackedMarks { marks: List<Mark>, spans: List<u32>, }
record Span { start: u32, length: u32, key: u32, }
record Runs { pending: Span, words: Buffer<u32>, keys: Buffer<u32>, order: Buffer<u32>, counts: Buffer<u32>, }
record Groups { offsets: Buffer<u32>, marks: Buffer<Mark>, next: u32, }
record Scatter { offsets: Buffer<u32>, words: Buffer<u32>, }
record Names { seen: Map<u64, List<String>>, repeated: Bool, }

fn member(key: String, item: json.Json) -> json.Member { return json.Member { key: key, value: item }; }
fn num(n: u32) -> json.Json { return json.number(paint.number(n)); }
fn capacity_issue() -> String { return "Exact color editing needs at most 255 swatches"; }
fn raster_issue() -> String { return "Expected native indexed pixels, RGB swatches and optional alpha bytes"; }
fn slot_issue() -> String { return "Swatch IDs must be unique and match the palette order"; }
fn ramp_issue() -> String { return "Palette ramps need unique IDs and at least two distinct, existing swatches in order"; }
fn slot_word(slot: i32) -> u32 { return value.as_word(f64_from_i32(slot)); }
fn signed(slot: u32) -> i32 { return i32_from_f64(f64_from_u32(slot)).fold(fn(n) => n, fn(unit) => -3); }

fn whole_list(raw: json.Json) -> Bool { return json.elements(raw).fold(fn(rows) => true, fn(issue) => false); }
fn whole_object(raw: json.Json) -> Bool { return json.members(raw).fold(fn(rows) => true, fn(issue) => false); }
fn included(ids: List<String>, key: String) -> Bool {
    return fold_until(ids, false, fn(id) => fn(found) => found, fn(id) => fn(found) => found || id == key);
}

fn insert_name(id: String, out: Names) -> Names {
    if out.repeated { return out; }
    let hash = labels.id_hash(id);
    let bucket: List<String> = out.seen.get_or(hash, []);
    if included(bucket, id) { return Names { ..out, repeated: true }; }
    return Names { ..out, seen: out.seen.set(hash, bucket.concat([id])) };
}

fn distinct(ids: List<String>) -> Bool {
    let start = Names { seen: Map.empty(), repeated: false };
    let result: Names = fold_until(ids, start, fn(id) => fn(out) => out.repeated,
        fn(id) => fn(out) => insert_name(id, out));
    return !result.repeated;
}

fn valid_aliases(ids: List<String>, count: u32) -> Bool {
    return length(ids) == count && length(ids.filter(fn(id) => !labels.stable_id(id))) == 0 && distinct(ids);
}

fn make_ramp_ids(rows: List<json.Json>) -> List<String> {
    return rows.map(fn(row) => value.text(value.get(value.fields(row), "id")));
}

fn valid_ramp(row: json.Json, ids: List<String>) -> Bool {
    let spec = value.fields(row);
    let names = value.items(value.get(spec, "swatches")).map(fn(raw) => value.text(raw));
    return value.only(spec, ["id", "label", "swatches"]) && labels.stable_id(value.text(value.get(spec, "id")))
        && json.lookup(spec, "label").fold(fn(v) => labels.present(value.text(v)), fn(unit) => true)
        && length(names) >= 2 && distinct(names)
        && length(names.filter(fn(id) => !included(ids, id))) == 0;
}

fn decorate(id: String, rgb: json.Json, names: List<json.Member>, locks: List<String>) -> json.Member {
    let named = json.lookup(names, id);
    let locked = included(locks, id);
    let extra = named.fold(fn(label) => [member("label", label)], fn(unit) => []);
    let fields = [member("color", rgb)].concat(extra).concat(if locked { [member("locked", json.boolean(true))] } else { [] });
    return member(id, if locked || length(extra) != 0 { json.object(fields) } else { rgb });
}

fn metadata_palette(raw: List<json.Json>, ids: List<String>, spec: List<json.Member>) -> Result<Palette, String> {
    let placeholder = json.object([]);
    let labels_json = json.lookup(spec, "swatchLabels").fold(fn(v) => v, fn(unit) => placeholder);
    let locks_json = json.lookup(spec, "lockedSwatches").fold(fn(v) => v, fn(unit) => json.array([]));
    let names = value.fields(labels_json);
    let locks = value.items(locks_json).map(fn(v) => value.text(v));
    if !whole_object(labels_json) || !whole_list(locks_json) || !distinct(locks)
        || length(names.filter(fn(row) => !included(ids, row.key))) != 0
        || length(locks.filter(fn(id) => !included(ids, id))) != 0 {
        return Err("Stamp palette names and locks must refer to existing swatch IDs");
    }
    if length(names.filter(fn(row) => !labels.present(value.text(row.value)))) != 0 {
        return Err("A pixel palette needs 1–255 ordered RGB swatches with IDs, optional names and locks");
    }
    let ramps_json = json.lookup(spec, "ramps").fold(fn(v) => v, fn(unit) => json.array([]));
    let ramps = value.items(ramps_json);
    if !whole_list(ramps_json) || length(ramps) > 255 || length(ramps.filter(fn(row) => !valid_ramp(row, ids))) != 0
        || !distinct(make_ramp_ids(ramps)) { return Err(ramp_issue()); }
    return Ok(Palette { entries: raw.map_indexed(fn(i) => fn(rgb) => decorate(ids.at_or(i, ""), rgb, names, locks)),
        colors: raw.map(fn(rgb) => frame.palette_color(rgb)), ids: ids, ramps: ramps });
}

fn generated_palette(colors: List<u32>, indexed: Bool) -> Palette {
    let ids = colors.map_indexed(fn(i) => fn(rgb) =>
        if indexed { string_concat("slot-", paint.number(i)) } else { string_concat("rgb-", color.color_digits(rgb)) });
    return Palette { entries: colors.map_indexed(fn(i) => fn(rgb) => member(ids.at_or(i, ""), json.text(color.color_text(rgb)))),
        colors: colors, ids: ids, ramps: [] };
}

fn discover_rgb(rgba: u32, old: Colors) -> Colors {
    if rgba == 0 { return Colors { ..old, slots: old.slots.push(-1) }; }
    let rgb = wrapping_shr(rgba, 8);
    let known = old.seen.get_or(rgb, -1);
    if known >= 0 { return Colors { ..old, slots: old.slots.push(known) }; }
    let n = old.palette.len();
    if n == 255 { return Colors { ..old, full: true }; }
    let slot = signed(n);
    return Colors { seen: old.seen.set(rgb, slot), palette: old.palette.push(rgb),
        slots: old.slots.push(slot), full: false };
}

fn foreign(layout: input.Layout, samples: input.Samples) -> Result<Decoded, String> {
    let alpha = samples.pixels.map(fn(pixel) => word_and(pixel, 255));
    if layout.color == 3 {
        if length(layout.palette) > 255 { return Err(capacity_issue()); }
        return Ok(Decoded { palette: generated_palette(layout.palette, true),
            slots: samples.indices.map(fn(i) => signed(i)), alpha: alpha, knockouts: [] });
    }
    let start = Colors { seen: Map.empty(), palette: Buffer.empty(), slots: Buffer.empty(), full: false };
    let found: Colors = fold_until(samples.pixels, start, fn(pixel) => fn(out) => out.full,
        fn(pixel) => fn(out) => if out.full { out } else { discover_rgb(pixel, out) });
    if found.full { return Err(capacity_issue()); }
    let colors: List<u32> = if found.palette.len() == 0 { [0] } else { found.palette.freeze() };
    return Ok(Decoded { palette: generated_palette(colors, false), slots: found.slots.freeze(), alpha: alpha, knockouts: [] });
}

fn slots_valid(slots: List<i32>, size: u32, count: u32) -> Bool {
    let last = if count == 0 { -1 } else {
        i32_from_f64(f64_from_u32(count - 1)).fold(fn(slot) => slot, fn(unit) => 2147483647)
    };
    return length(slots) == size && fold_until(slots, true, fn(slot) => fn(ok) => !ok,
        fn(slot) => fn(ok) => slot >= -1 && slot <= last);
}

fn alpha_valid(alpha: List<u32>, size: u32) -> Bool {
    return length(alpha) == size && fold_until(alpha, true, fn(a) => fn(ok) => !ok,
        fn(a) => fn(ok) => ok && a <= 255);
}

fn knockouts_valid(knockouts: List<u32>, slots: List<i32>) -> Bool {
    return repeat_until(length(knockouts), true, fn(ok) => !ok, fn(i) => fn(ok) =>
        slots.at_or(knockouts.at_or(i, 4294967295), -3) == -1 &&
        (i == 0 || knockouts.at_or(i, 0) > knockouts.at_or(i - 1, 0)));
}

fn matches_sample(slots: List<i32>, colors: List<u32>, pixels: List<u32>, p: u32) -> Bool {
    let slot = slots.at_or(p, -1);
    let rgba = pixels.at_or(p, 0);
    return if slot == -1 { rgba == 0 } else { wrapping_shr(rgba, 8) == colors.at_or(slot_word(slot), 0) };
}

fn matches_indices(raster: assets.Raster, palette: Palette, samples: input.Samples) -> Bool {
    let indexed = png.index(raster, palette.colors);
    return !indexed.full && indexed.pixels.freeze() == samples.indices;
}

fn editable(layout: input.Layout, samples: input.Samples, metadata: json.Json, slots: List<i32>,
    asserted_alpha: List<u32>, knockouts: List<u32>) -> Result<Decoded, String> {
    let spec = value.fields(metadata);
    if value.number(value.get(spec, "version")) != 1.0f64 { return Err("Unsupported Ink PNG palette metadata"); }
    let raw = value.items(value.get(spec, "palette"));
    let count = length(raw);
    let size = layout.width * layout.height;
    if count == 0 || count > size + 255 || length(raw.filter(fn(rgb) => !labels.rgb(value.text(rgb)))) != 0
        || !slots_valid(slots, size, count) || !json.lookup(spec, "alpha").fold(
            fn(v) => whole_list(v) && alpha_valid(asserted_alpha, size), fn(unit) => true) { return Err(raster_issue()); }
    if !json.lookup(spec, "knockouts").fold(fn(v) => whole_list(v) && knockouts_valid(knockouts, slots), fn(unit) => true) {
        return Err("Knockouts must be sorted locations of transparent pixels");
    }
    let ids = json.lookup(spec, "swatchIds").fold(fn(v) => value.items(v).map(fn(id) => value.text(id)),
        fn(unit) => raw.map_indexed(fn(i) => fn(rgb) => string_concat("slot-", paint.number(i))));
    if !valid_aliases(ids, count) { return Err(slot_issue()); }
    let palette = metadata_palette(raw, ids, spec)?;
    if count > 255 { return Err(capacity_issue()); }
    if !repeat_until(size, true, fn(ok) => !ok, fn(p) => fn(ok) => matches_sample(slots, palette.colors, samples.pixels, p)) {
        return Err("Ink PNG palette metadata does not match its pixels");
    }
    let alpha = samples.pixels.map_indexed(fn(p) => fn(pixel) =>
        if slots.at_or(p, -1) < 0 { 255 } else { word_and(pixel, 255) });
    let raster = assets.Raster { slots: slots, alpha: alpha, knockouts: knockouts };
    if layout.color == 3 && !matches_indices(raster, palette, samples) {
        return Err("Ink PNG palette metadata does not match its indices");
    }
    return Ok(Decoded { palette: palette, slots: slots, alpha: alpha, knockouts: knockouts });
}

fn append_span(width: u32, span: Span, out: Runs) -> Runs {
    if span.length == 0 { return out; }
    let x = rem_or(span.start, width, 0);
    let y = quot_or(span.start, width, 0);
    let word = run_words.pack(y, x, span.length);
    let n = out.counts.at_or(span.key, 0);
    return Runs { ..out, words: out.words.push(word), keys: out.keys.push(span.key),
        order: if n == 0 { out.order.push(span.key) } else { out.order }, counts: out.counts.set(span.key, n + 1) };
}

fn range_cell(width: u32, p: u32, key: u32, out: Runs) -> Runs {
    let span = out.pending;
    if key < 256 && span.length != 0 && key == span.key && p == span.start + span.length && rem_or(p, width, 0) != 0 {
        return Runs { ..out, pending: Span { ..span, length: span.length + 1 } };
    }
    let next = append_span(width, span, out);
    return Runs { ..next, pending: Span { start: p, length: if key < 256 { 1 } else { 0 }, key: key } };
}

fn alpha_range(width: u32, slots: List<i32>, opacity: List<u32>, i: u32, out: Runs) -> Runs {
    let alpha = opacity.at_or(i, 255);
    let key: u32 = if alpha != 255 && slots.at_or(i, -1) >= 0 { alpha } else { 256 };
    return range_cell(width, i, key, out);
}

fn flush_span(width: u32, out: Runs) -> Runs {
    return range_cell(width, 0, 256, out);
}

fn describe_group(counts: List<u32>, key: u32, out: Groups) -> Groups {
    let n = counts.at_or(key, 0);
    return Groups { offsets: out.offsets.set(key, out.next),
        marks: out.marks.push(Mark { alpha: key, first: out.next, length: n }), next: out.next + n };
}

fn place_span(keys: List<u32>, words: List<u32>, i: u32, out: Scatter) -> Scatter {
    let key = keys.at_or(i, 0);
    let slot = out.offsets.at_or(key, 0);
    return Scatter { offsets: out.offsets.set(key, slot + 1), words: out.words.set(slot, words.at_or(i, 0)) };
}

fn packed_marks(width: u32, slots: List<i32>, alpha: List<u32>, knockouts: List<u32>) -> PackedMarks {
    let count = if length(alpha) < length(slots) { length(alpha) } else { length(slots) };
    if count == 0 && length(knockouts) == 0 { return PackedMarks { marks: [], spans: [] }; }
    let start = Runs { pending: Span { start: 0, length: 0, key: 256 }, words: Buffer.empty(), keys: Buffer.empty(),
        order: Buffer.empty(), counts: buffer_fill(256, 0) };
    let alpha_runs: Runs = repeat_until(count, start, fn(out) => false, fn(i) => fn(out) =>
        alpha_range(width, slots, alpha, i, out));
    let finished = foldl(knockouts, flush_span(width, alpha_runs), fn(p) => fn(out) => range_cell(width, p, 255, out));
    let ranges = flush_span(width, finished);
    let counts = ranges.counts.freeze();
    let order = ranges.order.freeze();
    let grouped: Groups = foldl(order, Groups { offsets: buffer_fill(256, 0), marks: Buffer.empty(), next: 0 },
        fn(key) => fn(out) => describe_group(counts, key, out));
    let words = ranges.words.freeze();
    let keys = ranges.keys.freeze();
    let scatter = Scatter { offsets: grouped.offsets, words: buffer_fill(length(words), 0) };
    let organized: Scatter = repeat_until(length(words), scatter, fn(out) => false, fn(i) => fn(out) => place_span(keys, words, i, out));
    return PackedMarks { marks: grouped.marks.freeze(), spans: organized.words.freeze() };
}

fn make_document(layout: input.Layout, decoded: Decoded) -> Document {
    let width = layout.width;
    let packed = packed_marks(width, decoded.slots, decoded.alpha, decoded.knockouts);
    let palette = decoded.palette;
    let ramps: List<json.Member> = if length(palette.ramps) == 0 { [] } else { [member("ramps", json.array(palette.ramps))] };
    let drawing = json.object([member("slots", json.array([])), member("marks", json.array([]))]);
    let layer = json.object([member("id", json.text("image"))]);
    let first = json.object([member("id", json.text("artwork")), member("durationMs", num(100)),
        member("cels", json.object([member("image", drawing)]))]);
    let document = [member("format", json.text("ink-studio/pixel-art")), member("version", num(2)),
        member("width", num(width)), member("height", num(layout.height)), member("pixelAspect", json.array([num(1), num(1)])),
        member("palette", json.object(palette.entries))].concat(ramps).concat(
        [member("layers", json.array([layer])), member("frames", json.array([first]))]);
    return Document { template: json.object(document), slots: decoded.slots,
        marks: packed.marks, spans: packed.spans };
}

fn restore(layout: input.Layout, samples: input.Samples, metadata: json.Json, slots: List<i32>,
    alpha: List<u32>, knockouts: List<u32>) -> Result<Document, String> {
    let decoded: Result<Decoded, String> = if layout.annotation.start == 0 { foreign(layout, samples) }
        else { editable(layout, samples, metadata, slots, alpha, knockouts) };
    let ready = decoded?;
    return Ok(make_document(layout, ready));
}
