module StudioPixelBrushPaint;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_drawing_grid.ink" as grid;
import "pixel_frame.ink" as frame;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Shading { mode: String, named: String, opacity: u32, ramp: List<i32>, }
record Colors { palette: List<brush.Swatch>, slots: List<i32>, added: List<brush.Swatch>, issue: String, }

fn unshaded() -> Shading { return Shading { mode: "", named: "", opacity: 255, ramp: [] }; }

fn read_shading(source: json.Json, ids: List<String>, raw: json.Json) -> Result<Shading, String> {
    if raw == json.null() { return Err("Cannot read properties of null (reading 'mode')"); }
    let items = value.fields(raw);
    let mode = value.text(value.get(items, "mode"));
    let defaults = unshaded();
    if mode == "recolor" && value.only(items, ["mode"]) { return Ok(Shading { ..defaults, mode: mode }); }
    if mode == "alpha" && value.only(items, ["mode", "value"]) {
        let opacity = value.word(value.get(items, "value"), 255);
        if opacity <= 255 { return Ok(Shading { ..defaults, mode: mode, opacity: opacity }); }
    }
    if mode != "ramp" { return Err("Brush shading needs recolor, a ramp with a nonzero step, or an alpha byte"); }
    return shade_ramp(source, ids, items);
}

fn find_ramp(source: json.Json, name: String) -> json.Json {
    let ramps = value.items(value.get(value.fields(source), "ramps"));
    return repeat_until(length(ramps), json.null(), fn(found) => found != json.null(), fn(i) => fn(found) =>
        match_ramp(ramps.at_or(i, json.null()), name));
}

fn match_ramp(raw: json.Json, name: String) -> json.Json {
    let items = value.fields(raw);
    if value.text(value.get(items, "id")) != name { return json.null(); }
    return value.get(items, "swatches");
}

fn shade_ramp(source: json.Json, ids: List<String>, spec: List<json.Member>) -> Result<Shading, String> {
    let raw = value.get(spec, "ramp");
    let name: Option<String> = json.as_text(raw).fold(fn(s) => Some(s), fn(e) => None);
    let named = name.fold(fn(s) => s, fn(unit) => "");
    let ramp = name.fold(fn(s) => find_ramp(source, s), fn(unit) => raw);
    if name.fold(fn(s) => ramp == json.null(), fn(unit) => false) { return Err(string_concat("Unknown palette ramp ", named)); }
    let rows = value.items(ramp);
    let step = value.integer(value.get(spec, "step"), -254, 254).fold(fn(i) => i, fn(unit) => 0);
    if !value.only(spec, ["mode", "ramp", "step"]) || length(rows) < 2 || length(rows) > 255 || step == 0 {
        return Err("Brush shading needs recolor, a ramp with a nonzero step, or an alpha byte");
    }
    let slots = rows.map(fn(id) => selection.find_swatch(ids, value.text(id)));
    if length(slots.filter(fn(i) => i < 0)) > 0 || repeated(slots) {
        return Err("A brush ramp needs distinct, existing target swatches");
    }
    let lookup = repeat_until(length(slots), buffer_fill(length(ids), -1), fn(out) => false,
        fn(i) => fn(out) => ramp_slot(slots, step, i, out)).freeze();
    let defaults = unshaded();
    return Ok(Shading { ..defaults, mode: "ramp", named: named, ramp: lookup });
}

fn repeated(slots: List<i32>) -> Bool {
    let ordered = slots.sort();
    return repeat_until(length(ordered) - 1, false, fn(found) => found, fn(i) => fn(found) =>
        ordered.at_or(i, -1) == ordered.at_or(i + 1, -2));
}

fn ramp_slot(slots: List<i32>, step: i32, i: u32, out: Buffer<i32>) -> Buffer<i32> {
    let start = slots.at_or(i, -1);
    let n = grid.min(grid.signed(length(slots) - 1), grid.max(0, grid.signed(i) + step));
    let next = slots.at_or(grid.unsigned(n), -1);
    return if next == start { out } else { out.set(grid.unsigned(start), next) };
}

fn shaded(stamp: brush.Stamp, captured: frame.Captured, shade: Shading) -> brush.Stamp {
    if shade.mode == "" { return stamp; }
    let before = captured.slots.at_or(stamp.pixel, -1);
    let alpha = captured.alpha.at_or(stamp.pixel, 255);
    let slot = if before < 0 { -1 } else { shade_slot(shade, stamp.slot, before, alpha) };
    return brush.Stamp { ..stamp, slot: slot };
}

fn shade_slot(shade: Shading, from: i32, target: i32, alpha: u32) -> i32 {
    if shade.mode == "alpha" { return if alpha == shade.opacity { -1 } else { grid.signed(shade.opacity) }; }
    if alpha == 0 { return -1; }
    if shade.mode == "recolor" { return from; }
    return shade.ramp.at_or(grid.unsigned(target), -1);
}

fn used_slots(stamps: List<brush.Stamp>, count: u32) -> List<Bool> {
    return foldl(stamps, buffer_fill(count, false), fn(row) => fn(out) => out.set(grid.unsigned(row.slot), true)).freeze();
}

fn palette(art: frame.Artwork, b: brush.Brush, stamps: List<brush.Stamp>, override: i32) -> Result<Colors, String> {
    let initial = Colors { palette: [], slots: [], added: [], issue: "" };
    if override >= 0 { return Ok(Colors { ..initial, slots: buffer_fill(length(b.palette), override).freeze() }); }
    let palette = art.ids.map_indexed(fn(i) => fn(id) => brush.Swatch { id: id, color: art.colors.at_or(i, 0) });
    let used = used_slots(stamps, length(b.palette));
    let out = repeat_until(length(b.palette), Colors { ..initial, palette: palette }, fn(out) => out.issue != "",
        fn(i) => fn(out) => map_swatch(b, used, i, out));
    if out.issue != "" { return Err(out.issue); }
    return Ok(out);
}

fn map_swatch(b: brush.Brush, used: List<Bool>, i: u32, out: Colors) -> Colors {
    if !used.at_or(i, false) { return Colors { ..out, slots: out.slots.concat([-1]) }; }
    let wanted = b.settings.tint.fold(fn(tint) => tint, fn(unit) => b.palette.at_or(i, brush.Swatch { id: "", color: 0 }));
    let slot = find_color(out.palette, wanted);
    if slot >= 0 { return Colors { ..out, slots: out.slots.concat([slot]) }; }
    let count = length(out.palette);
    if count >= 255 { return Colors { ..out, issue: "Brush colors exceed the target palette limit" }; }
    let stem = if wanted.id != "" && !id_used(out.palette, wanted.id) { wanted.id }
        else { string_concat("brush-", color_digits(wanted.color)) };
    let name = available_id(out.palette, stem);
    let entry = brush.Swatch { ..wanted, id: name };
    return Colors { palette: out.palette.concat([entry]), added: out.added.concat([entry]),
        slots: out.slots.concat([grid.signed(count)]), issue: "" };
}

fn prefer(row: brush.Swatch, wanted: brush.Swatch, i: u32, old: Vec2<i32>) -> Vec2<i32> {
    if row.color != wanted.color { return old; }
    let slot = grid.signed(i);
    return vec2(if old.x >= 0 { old.x } else { slot }, if row.id == wanted.id { slot } else { -1 });
}

fn find_color(rows: List<brush.Swatch>, wanted: brush.Swatch) -> i32 {
    let start: Vec2<i32> = vec2(-1, -1);
    let seen = repeat_until(length(rows), start, fn(out) => out.y >= 0, fn(i) => fn(out) =>
        prefer(rows.at_or(i, brush.Swatch { id: "", color: 4294967295 }), wanted, i, out));
    return if seen.y >= 0 { seen.y } else { seen.x };
}

fn id_used(rows: List<brush.Swatch>, name: String) -> Bool {
    return foldl(rows, false, fn(row) => fn(found) => found || row.id == name);
}

fn available_id(rows: List<brush.Swatch>, stem: String) -> String {
    if !id_used(rows, stem) { return stem; }
    return repeat_until(length(rows), "", fn(found) => found != "", fn(i) => fn(found) =>
        next_id(rows, string_concat(stem, string_concat("-", frame.decimal(i + 2)))));
}

fn next_id(rows: List<brush.Swatch>, name: String) -> String { return if id_used(rows, name) { "" } else { name }; }

fn color_digits(bits: u32) -> String {
    return repeat_until(6, "", fn(out) => false, fn(i) => fn(out) =>
        string_concat(out, hex_digit(word_and(wrapping_shr(bits, 4 * (5 - i)), 15))));
}

fn hex_digit(n: u32) -> String {
    return string_slice("0123456789abcdef", n, n + 1).fold(fn(c) => c, fn(unit) => "");
}

fn color_text(bits: u32) -> String { return string_concat("#", color_digits(bits)); }

