module StudioPixelPaletteExtract;

import "std:json" as json;
import "pixel_asset_export.ink" as assets;
import "pixel_brush_paint.ink" as colors;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_palette_edit.ink" as palette;
import "pixel_png_input.ink" as png;
import "pixel_values.ink" as value;

record Settings { size: u32, mode: String, }
record Histogram { counts: Map<u32, u32>, colors: Buffer<u32>, }
record Range { start: u32, end: u32, count: u32, color: u32, axis: u32, score: f64, }
record Moment { sum: f64, square: f64, }
record Stats { count: u32, red: Moment, green: Moment, blue: Moment, }
record Groups { colors: Buffer<u64>, ranges: List<Range>, }
record Measured { points: Buffer<u64>, range: Range, }
record Cut { mass: u32, distance: u32, bin: u32, }

fn options(raw: json.Json) -> Result<Settings, String> {
    let fields = value.fields(raw);
    let size = json.lookup(fields, "size").fold(fn(n) => value.word(n, 256), fn(unit) => 32);
    if size == 0 || size > 256 { return Err("Reference palette size must be an integer from 1 to 256"); }
    let mode = json.lookup(fields, "alpha").fold(fn(a) => value.text(a), fn(unit) => "visible");
    if mode != "all" && mode != "visible" && mode != "opaque" { return Err("Reference alpha mode must be visible, opaque or all"); }
    return Ok(Settings { size: size, mode: mode });
}

fn included(mode: String, opacity: u32) -> Bool {
    return mode == "all" || mode == "visible" && opacity != 0 || mode == "opaque" && opacity == 255;
}

fn add_color(pixel: u32, mode: String, hist: Histogram) -> Histogram {
    if !included(mode, word_and(pixel, 255)) { return hist; }
    let rgb = wrapping_shr(pixel, 8);
    let count = hist.counts.get_or(rgb, 0);
    return Histogram { counts: hist.counts.set(rgb, count + 1),
        colors: if count == 0 { hist.colors.push(rgb) } else { hist.colors } };
}

fn color_channel(rgb: u32, axis: u32) -> u32 {
    return word_and(wrapping_shr(rgb, 16 - axis * 8), 255);
}

fn add_channel(prior: Moment, sample: u32, count: f64) -> Moment {
    let n = f64_from_u32(sample);
    return Moment { sum: prior.sum + n * count, square: prior.square + (n * n) * count };
}

fn add_stats(color: u32, count: u32, total: Stats) -> Stats {
    let weight = f64_from_u32(count);
    return Stats { count: total.count + count, red: add_channel(total.red, color_channel(color, 0), weight),
        green: add_channel(total.green, color_channel(color, 1), weight),
        blue: add_channel(total.blue, color_channel(color, 2), weight) };
}

fn pigment(rgb: u32, count: u32) -> u64 {
    return wrapping_shl(word_widen_u32_to_u64(rgb), 32) | word_widen_u32_to_u64(count);
}

fn packed_color(packed: u64) -> u32 { return word_narrow_u64_to_u32(wrapping_shr(packed, 32)); }

fn summarize(points: Buffer<u64>, start: u32, end: u32) -> Measured {
    let zero = Moment { sum: 0.0f64, square: 0.0f64 };
    let initial = Stats { count: 0, red: zero, green: zero, blue: zero };
    let result = points.borrow_range(start, end - start, fn(view) =>
        repeat_until(view.len(), initial, fn(total) => false, fn(i) => fn(total) =>
            accumulate(view.at_or(i, 0), total)));
    return Measured { points: points, range: summarize_stats(result, start, end) };
}

fn accumulate(packed: u64, total: Stats) -> Stats {
    return add_stats(packed_color(packed), word_narrow_u64_to_u32(packed), total);
}

fn summarize_stats(total: Stats, start: u32, end: u32) -> Range {
    let mass = f64_from_u32(total.count);
    let red = variance(total.red, mass, 0.30f64);
    let green = variance(total.green, mass, 0.55f64);
    let blue = variance(total.blue, mass, 0.15f64);
    let axis: u32 = if red >= green && red >= blue { 0 } else { if green >= blue { 1 } else { 2 } };
    let score = if axis == 0 { red } else { if axis == 1 { green } else { blue } };
    let rgb = value.round_byte(total.red.sum / mass) * 65536 +
        value.round_byte(total.green.sum / mass) * 256 + value.round_byte(total.blue.sum / mass);
    return Range { start: start, end: end, count: total.count, color: rgb, axis: axis, score: score };
}

fn variance(moment: Moment, mass: f64, weight: f64) -> f64 {
    return weight * (moment.square - moment.sum * moment.sum / mass);
}

fn add_band(packed: u64, axis: u32, bins: Buffer<u32>) -> Buffer<u32> {
    let bin = color_channel(packed_color(packed), axis);
    let prior = bins.at_or(bin, 0);
    return bins.set(bin, prior + word_narrow_u64_to_u32(packed));
}

fn choose_cut(bins: List<u32>, count: u32) -> u32 {
    let initial = Cut { mass: 0, distance: 4294967295, bin: 0 };
    let chosen = repeat_until(255, initial, fn(cut) => cut.mass >= count, fn(i) => fn(cut) =>
        try_cut(cut, bins.at_or(i, 0), count, i));
    return chosen.bin;
}

fn try_cut(cut: Cut, frequency: u32, count: u32, i: u32) -> Cut {
    if frequency == 0 { return cut; }
    let mass = cut.mass + frequency;
    if mass >= count { return Cut { ..cut, mass: mass }; }
    let distance = png.distance(count, mass * 2);
    return if distance < cut.distance { Cut { mass: mass, distance: distance, bin: i } } else { Cut { ..cut, mass: mass } };
}

fn next_group(groups: List<Range>) -> u32 {
    let absent: u32 = 4294967295;
    return repeat_until(length(groups), absent, fn(index) => false, fn(i) => fn(best) => better_group(groups, i, best));
}

fn empty_range() -> Range {
    return Range { start: 0, end: 0, count: 0, color: 0, axis: 0, score: -1.0f64 };
}

fn better_group(groups: List<Range>, i: u32, best: u32) -> u32 {
    let row = groups.at_or(i, empty_range());
    if row.end - row.start <= 1 { return best; }
    return if best == 4294967295 || row.score > groups.at_or(best, empty_range()).score { i } else { best };
}

record Partition { points: Buffer<u64>, split: u32, }

fn swap_before(old: Partition, index: u32, axis: u32, cut: u32) -> Partition {
    let rgb = old.points.at_or(index, 0);
    if color_channel(packed_color(rgb), axis) > cut { return old; }
    let prior = old.points.at_or(old.split, 0);
    if index == old.split { return Partition { ..old, split: old.split + 1 }; }
    return Partition { points: old.points.set(old.split, rgb).set(index, prior), split: old.split + 1 };
}

fn empty_bins() -> Buffer<u32> { return buffer_fill(256, 0); }

fn divide(out: Groups) -> Groups {
    let index = next_group(out.ranges);
    if index == 4294967295 { return out; }
    let range = out.ranges.at_or(index, empty_range());
    let span = range.end - range.start;
    let bins = out.colors.borrow_range(range.start, span, fn(view) =>
        repeat_until(view.len(), empty_bins(), fn(bands) => false, fn(i) => fn(bands) =>
            add_band(view.at_or(i, 0), range.axis, bands)).freeze());
    let cut = choose_cut(bins, range.count);
    let initial = Partition { points: out.colors, split: range.start };
    let partition = repeat_until(span, initial, fn(change) => false, fn(i) => fn(change) =>
        swap_before(change, range.start + i, range.axis, cut));
    return merge_groups(out.ranges, partition, index, range);
}

fn merge_groups(groups: List<Range>, part: Partition, index: u32, range: Range) -> Groups {
    let a = summarize(part.points, range.start, part.split);
    let b = summarize(a.points, part.split, range.end);
    let rows = groups.map_indexed(fn(i) => fn(row) => if i == index { a.range } else { row });
    return Groups { colors: b.points, ranges: rows.concat([b.range]) };
}

fn sorted_key(rgb: u32, count: u32) -> u64 {
    return word_widen_u32_to_u64(16777216 - count) * 16777216 + word_widen_u32_to_u64(rgb);
}

fn swatch(rgb: u32, suffix: String) -> json.Json {
    let id = string_concat("extracted-", string_concat(colors.color_digits(rgb), suffix));
    return json.object([history.member("id", json.text(id)), history.member("color", json.text(colors.color_text(rgb)))]);
}

fn reduce(points: Buffer<u64>, size: u32) -> List<u64> {
    let limit = points.len();
    let first = summarize(points, 0, limit);
    let initial = Groups { colors: first.points, ranges: [first.range] };
    let result = repeat_until(size - 1, initial, fn(out) => false, fn(i) => fn(out) => divide(out));
    return result.ranges.map(fn(row) => sorted_key(row.color, row.count));
}

fn quantize(hist: Histogram, size: u32) -> List<json.Json> {
    let weighted = hist.colors.freeze().map(fn(rgb) => pigment(rgb, hist.counts.get_or(rgb, 0)));
    let keys = if length(weighted) <= size {
        weighted.map(fn(row) => sorted_key(packed_color(row), word_narrow_u64_to_u32(row)))
    } else { reduce(buffer(weighted), size) };
    return keys.sort().map(fn(key) => swatch(word_narrow_u64_to_u32(key & 16777215), ""));
}

fn export_colors(rows: List<json.Json>, indexed: Bool) -> Result<json.Json, String> {
    if indexed && length(rows) == 0 { return Err("No pixels match the palette extraction alpha mode"); }
    let data = palette.Palette { swatches: rows, ramps: [] };
    let checked = palette.validate(data).map_err(fn(issue) => value.text(value.get(value.fields(issue), "message")))?;
    return Ok(palette.asset(checked));
}

fn rgba(pixels: List<u32>, settings: Settings) -> Result<json.Json, String> {
    let initial = Histogram { counts: Map.empty(), colors: Buffer.empty() };
    let histogram = foldl(pixels, initial, fn(pixel) => fn(out) => add_color(pixel, settings.mode, out));
    return export_colors(quantize(histogram, settings.size), false);
}

fn indexed_swatch(h: png.Layout, counts: List<u32>, mode: String, i: u32, rows: Buffer<json.Json>) -> Buffer<json.Json> {
    if counts.at_or(i, 0) == 0 || !included(mode, h.transparency.at_or(i, 255)) { return rows; }
    return rows.push(swatch(h.palette.at_or(i, 0), string_concat("-slot-", frame.decimal(i))));
}

fn reference(h: png.Layout, samples: png.Samples, raw: json.Json) -> Result<json.Json, String> {
    let settings = options(raw)?;
    if h.color != 3 { return rgba(samples.pixels, settings); }
    let initial: Buffer<json.Json> = Buffer.empty();
    let rows = repeat_until(length(h.palette), initial, fn(out) => false, fn(i) => fn(out) =>
        indexed_swatch(h, samples.indices, settings.mode, i, out));
    return export_colors(rows.freeze(), true);
}

fn stamped_pixel(raster: assets.IndexedRaster, slot: i32, i: u32) -> u32 {
    if slot < 0 { return 0; }
    return frame.color_at(raster.colors, slot) * 256 + raster.raster.alpha.at_or(i, 255);
}

fn document(source: json.Json, art: frame.Artwork, raw: json.Json) -> Result<json.Json, String> {
    let fields = value.fields(raw);
    let scope_fields = fields.filter(fn(row) => row.key == "frame" || row.key == "layer");
    let scope = assets.export_scope(art, scope_fields)?;
    let selected = assets.scoped_raster(source, art, scope_fields, scope, false)?;
    let settings = options(raw)?;
    return rgba(selected.raster.slots.map_indexed(fn(i) => fn(slot) => stamped_pixel(selected, slot, i)), settings);
}
