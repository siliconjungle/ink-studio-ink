module StudioPixelRgbaEdit;

import "pixel_brush.ink" as brush;
import "pixel_brush_paint.ink" as brush_paint;
import "pixel_drawing_grid.ink" as grid;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;

record Write { pixel: u32, slot: i32, alpha: u32, }
record ResultWrites { writes: List<Write>, added: List<brush.Swatch>, }
record Palette { rows: List<brush.Swatch>, by_rgb: Map<u32, i32>, added: List<brush.Swatch>, }
record Target { g: mask.Grid, view: frame.PaintView, protected: List<u32>, }
record Work { visited: Buffer<u32>, writes: Buffer<Write>, palette: Palette, issue: String, }
record Swatch { slot: i32, palette: Palette, issue: String, }

fn new_palette(art: frame.Artwork) -> Palette {
    let rows = art.ids.map_indexed(fn(i) => fn(id) => brush.Swatch { id: id, color: art.colors.at_or(i, 0) });
    let empty: Map<u32, i32> = Map.empty();
    let indexed = repeat_until(length(rows), empty, fn(map) => false, fn(i) => fn(map) =>
        index_color(map, art.colors.at_or(i, 0), grid.signed(i)));
    return Palette { rows: rows, by_rgb: indexed, added: [] };
}

fn index_color(index: Map<u32, i32>, rgb: u32, slot: i32) -> Map<u32, i32> {
    return if index.get_or(rgb, -1) < 0 { index.set(rgb, slot) } else { index };
}

fn known_slot(rows: List<brush.Swatch>, name: String) -> i32 {
    return repeat_until(length(rows), -1, fn(found) => found >= 0, fn(i) => fn(found) =>
        match_name(rows.at_or(i, brush.Swatch { id: "", color: 0 }), name, i));
}

fn match_name(row: brush.Swatch, id: String, i: u32) -> i32 {
    return if row.id == id { grid.signed(i) } else { -1 };
}

fn resolve(palette: Palette, color: u32, name: String, explicit: Bool, current: i32) -> Swatch {
    if explicit && !brush.stable_id(name) {
        return Swatch { slot: -1, palette: palette, issue: "Invalid RGB swatch" };
    }
    let preferred = if explicit { known_slot(palette.rows, name) } else { current };
    if preferred >= 0 && palette.rows.at_or(grid.unsigned(preferred), brush.Swatch { id: "", color: 4294967295 }).color == color {
        return Swatch { slot: preferred, palette: palette, issue: "" };
    }
    if explicit && preferred >= 0 {
        return Swatch { slot: -1, palette: palette, issue: string_concat("RGBA does not match swatch ", name) };
    }
    let existing = if explicit { -1 } else { palette.by_rgb.get_or(color, -1) };
    if existing >= 0 { return Swatch { slot: existing, palette: palette, issue: "" }; }
    let count = length(palette.rows);
    if count >= 255 {
        return Swatch { slot: -1, palette: palette, issue: "Exact color editing needs at most 255 swatches" };
    }
    let id = if explicit { name } else {
        brush_paint.available_id(palette.rows, string_concat("rgb-", brush_paint.color_digits(color)))
    };
    let entry = brush.Swatch { id: id, color: color };
    let slot = grid.signed(count);
    let index = index_color(palette.by_rgb, color, slot);
    return Swatch { slot: slot, palette: Palette { rows: palette.rows.concat([entry]), by_rgb: index,
        added: palette.added.concat([entry]) }, issue: "" };
}

fn position(g: mask.Grid, p: u32) -> String {
    return string_concat(frame.decimal(rem_or(p, g.width, 0)), string_concat(",", frame.decimal(quot_or(p, g.width, 0))));
}

fn apply_write(target: Target, p: u32, slot: i32, alpha: u32, old: Work) -> Work {
    let prior = target.view.captured.slots.at_or(p, -1);
    let byte = target.view.captured.alpha.at_or(p, 255);
    if slot == prior && (slot < 0 || alpha == byte) { return old; }
    if !frame.can_paint(target.view, target.protected, p) { return Work { ..old, issue: "RGBA edit cannot change this pixel" }; }
    return Work { ..old, writes: old.writes.push(Write { pixel: p, slot: slot, alpha: alpha }) };
}

fn visit(target: Target, encoded: u32, rgba: u32, name: u32, names: List<String>, old: Work) -> Work {
    // The high range is reserved for clear operations; all canvas positions fit in 18 bits.
    let p = word_and(encoded, 262143);
    if encoded >= 524288 || p >= mask.size(target.g) {
        return Work { ..old, issue: "An RGBA pixel needs an in-bounds coordinate, four bytes or null, and an optional swatch ID" };
    }
    if word_and(old.visited.at_or(mask.word_slot(p), 0), mask.word_bit(p)) != 0 {
        return Work { ..old, issue: string_concat("RGBA edit repeats a pixel at ", position(target.g, p)) };
    }
    let begun = Work { ..old, visited: mask.mark(old.visited, p) };
    if encoded >= 262144 { return apply_write(target, p, -1, 255, begun); }
    let previous = target.view.captured.slots.at_or(p, -1);
    let next = resolve(begun.palette, wrapping_shr(rgba, 8), names.at_or(name, ""), name != 4294967295, previous);
    let staged = Work { ..begun, palette: next.palette, issue: next.issue };
    if staged.issue != "" { return staged; }
    return apply_write(target, p, next.slot, word_and(rgba, 255), staged);
}

fn plan(art: frame.Artwork, view: frame.PaintView, protected: List<u32>, rows: List<u32>, names: List<String>) -> Result<ResultWrites, String> {
    let target = Target { g: art.grid, view: view, protected: protected };
    let initial = Work { visited: mask.blank(target.g), writes: Buffer.empty(), palette: new_palette(art), issue: "" };
    let visited = repeat_until(quot_or(length(rows), 3, 0), initial, fn(out) => out.issue != "",
        fn(i) => fn(out) => visit(target, rows.at_or(i * 3, 4294967295), rows.at_or(i * 3 + 1, 0),
            rows.at_or(i * 3 + 2, 4294967295), names, out));
    if visited.issue != "" { return Err(visited.issue); }
    return Ok(ResultWrites { writes: visited.writes.freeze(), added: visited.palette.added });
}

