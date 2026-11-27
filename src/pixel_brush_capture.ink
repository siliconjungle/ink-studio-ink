module StudioPixelBrushCapture;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_paint.ink" as brush_paint;
import "pixel_drawing_grid.ink" as grid;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Bounds { left: u32, top: u32, right: u32, bottom: u32, }
record Area { box: mask.Rect, selected: List<u32>, rectangular: Bool, }
record Points { bounds: Bounds, words: Buffer<u32>, issue: String, }
record Pixel { slot: i32, color: u32, }
record Colors { slots: Buffer<i32>, palette: Buffer<brush.Swatch>, keys: Map<u32, i32>, issue: String, }
record Pigment { id: String, color: String, }
record Capture { width: u32, height: u32, anchor: Vec2<u32>, palette: List<Pigment>,
    slots: List<i32>, settings: json.Json, }
record Source { scope: frame.Scope, g: mask.Grid, ids: List<String>, colors: List<u32>, view: frame.PaintView, }

fn option(spec: List<json.Member>, key: String) -> Option<String> {
    return json.lookup(spec, key).fold(fn(raw) => Some(label(raw)), fn(unit) => None);
}

fn label(raw: json.Json) -> String {
    return json.as_text(raw).fold(fn(s) => s, fn(e) =>
        json.as_number(raw).fold(fn(s) => s, fn(e) =>
            json.as_boolean(raw).fold(fn(b) => if b { "true" } else { "false" },
                fn(e) => if raw == json.null() { "null" } else { "[object Object]" })));
}

fn active_frame(named: selection.Named, spec: List<json.Member>) -> Result<Option<String>, String> {
    let requested = option(spec, "frame");
    if !value.has(spec, "selection") { return Ok(requested); }
    let name = label(value.get(spec, "selection"));
    let index = selection.named_slot(named.ids, name);
    if index == 4294967295 { return Err(string_concat("Unknown pixel selection ", name)); }
    let scope = named.frames.at_or(index, "");
    if scope != "" && requested.fold(fn(id) => id != scope, fn(unit) => false) {
        return Err(string_concat("Pixel selection belongs to frame ", scope));
    }
    return Ok(requested.fold(fn(id) => Some(id), fn(unit) => frame.optional_scope(scope)));
}

fn capture(art: frame.Artwork, named: selection.Named, raw: json.Json, packed: List<u32>) -> Result<Capture, String> {
    let spec = value.fields(raw);
    let chosen = value.has(spec, "selection");
    let points = value.has(spec, "pixels");
    let rectangle = value.has(spec, "rect");
    let frame_count: u32 = (if chosen { 1 } else { 0 }) + (if points { 1 } else { 0 }) + (if rectangle { 1 } else { 0 });
    let layer = option(spec, "layer");
    let cel = option(spec, "cel");
    if frame_count != 1 || (value.has(spec, "layer") && value.has(spec, "cel")) {
        return Err("Choose one brush selection and, optionally, one source layer or cel");
    }
    let active = active_frame(named, spec)?;
    let resolved = frame.resolve(art, active, layer, cel)?;
    let view = frame.paint_view(art, resolved)?;
    if resolved.layer != "" && !view.captured.found {
        return Err(string_concat("Unknown brush source layer ", resolved.layer));
    }
    let source = Source { scope: resolved, g: art.grid, ids: art.ids, colors: art.colors, view: view };
    let area = selection_area(source, named, spec, packed)?;
    return capture_area(source, area, spec);
}

fn selection_area(source: Source, named: selection.Named, spec: List<json.Member>, packed: List<u32>) -> Result<Area, String> {
    let g = source.g;
    if value.has(spec, "rect") { return rectangle_area(g, value.items(value.get(spec, "rect"))); }
    if value.has(spec, "selection") {
        let choice = selection.recall_named(g, named, source.scope.frame, label(value.get(spec, "selection")));
        if choice.issue != "" { return Err(choice.issue); }
        let sites = mask.indices(choice.mask);
        if length(sites) == 0 { return Err("Brush capture needs at least one selected pixel"); }
        let box = rectangle_from_bounds(foldl(sites, empty_bounds(g), fn(p) => fn(b) =>
            include(b, rem_or(p, g.width, 0), quot_or(p, g.width, 0))));
        return Ok(Area { box: box, selected: choice.mask, rectangular: false });
    }
    let pixels = if length(packed) != 0 { packed } else {
        value.items(value.get(spec, "pixels")).map(fn(raw) => point_index(g, raw))
    };
    return points_area(g, pixels);
}

fn rectangle_area(g: mask.Grid, parts: List<json.Json>) -> Result<Area, String> {
    let x = value.word(parts.at_or(0, json.null()), g.width - 1);
    let y = value.word(parts.at_or(1, json.null()), g.height - 1);
    let issue = "Brush selection rectangle must be inside the canvas";
    if length(parts) != 4 || x >= g.width || y >= g.height { return Err(issue); }
    let w = value.word(parts.at_or(2, json.null()), g.width - x);
    let h = value.word(parts.at_or(3, json.null()), g.height - y);
    if w == 0 || h == 0 || w > g.width - x || h > g.height - y { return Err(issue); }
    return Ok(Area { box: mask.Rect { x: x, y: y, w: w, h: h }, selected: [], rectangular: true });
}

fn empty_bounds(g: mask.Grid) -> Bounds { return Bounds { left: g.width, top: g.height, right: 0, bottom: 0 }; }
fn maximum(a: u32, b: u32) -> u32 { return if a >= b { a } else { b }; }

fn include(b: Bounds, x: u32, y: u32) -> Bounds {
    return Bounds { left: mask.min(b.left, x), top: mask.min(b.top, y),
        right: maximum(b.right, x), bottom: maximum(b.bottom, y) };
}

fn rectangle_from_bounds(b: Bounds) -> mask.Rect {
    return mask.Rect { x: b.left, y: b.top, w: b.right - b.left + 1, h: b.bottom - b.top + 1 };
}

fn points_area(g: mask.Grid, coordinates: List<u32>) -> Result<Area, String> {
    if length(coordinates) == 0 || length(coordinates) > mask.size(g) {
        return Err("Brush capture needs at least one selected pixel");
    }
    let initial = Points { bounds: empty_bounds(g), words: mask.blank(g), issue: "" };
    let traced = repeat_until(length(coordinates), initial, fn(out) => out.issue != "", fn(i) => fn(out) =>
        add_point(g, coordinates.at_or(i, 4294967295), out));
    if traced.issue != "" { return Err(traced.issue); }
    return Ok(Area { box: rectangle_from_bounds(traced.bounds), selected: traced.words.freeze(), rectangular: false });
}

fn point_index(g: mask.Grid, raw: json.Json) -> u32 {
    let p = brush.upair(raw, vec2(g.width - 1, g.height - 1));
    return if p.x < g.width && p.y < g.height { mask.index(g, p) } else { 4294967295 };
}

fn add_point(g: mask.Grid, i: u32, out: Points) -> Points {
    if i >= mask.size(g) { return Points { ..out, issue: "Brush selection must be inside the canvas" }; }
    let x = rem_or(i, g.width, 0);
    let y = quot_or(i, g.width, 0);
    if word_and(out.words.at_or(mask.word_slot(i), 0), mask.word_bit(i)) != 0 {
        return Points { ..out, issue: "Brush selection repeats a pixel" };
    }
    return Points { bounds: include(out.bounds, x, y), words: mask.mark(out.words, i), issue: "" };
}

fn read(source: Source, p: u32) -> Pixel {
    if source.scope.layer != "" {
        let cap = source.view.captured;
        let slot = cap.slots.at_or(p, -1);
        let valid = slot >= 0 && cap.alpha.at_or(p, 255) != 0;
        return if valid { Pixel { slot: slot, color: source.colors.at_or(grid.unsigned(slot), 0) } }
            else { Pixel { slot: -1, color: 0 } };
    }
    let cell = source.view.pixels.at_or(p, frame.blank());
    return Pixel { slot: if cell.alpha == 0 { -1 } else { cell.slot }, color: cell.color };
}

fn capture_site(source: Source, area: Area, i: u32, out: Colors) -> Colors {
    let b = area.box;
    let p = (b.y + quot_or(i, b.w, 0)) * source.g.width + b.x + rem_or(i, b.w, 0);
    if !area.rectangular && !mask.selected(area.selected, p) { return Colors { ..out, slots: out.slots.push(-1) }; }
    let read = read(source, p);
    if read.slot < 0 { return Colors { ..out, slots: out.slots.push(-1) }; }
    return store_pixel(source, read, out);
}

fn store_pixel(source: Source, p: Pixel, out: Colors) -> Colors {
    let slot = grid.unsigned(p.slot);
    let indexed = source.colors.at_or(slot, 4294967295) == p.color;
    let key = p.color * 256 + (if indexed { slot + 1 } else { 0 });
    let existing = out.keys.get_or(key, -1);
    if existing >= 0 { return Colors { ..out, slots: out.slots.push(existing) }; }
    let n = out.palette.len();
    if n >= 255 { return Colors { ..out, issue: "A pixel brush needs a painted indexed shape and a native anchor" }; }
    let next = grid.signed(n);
    let id = if indexed { source.ids.at_or(slot, "") } else { "" };
    let swatch = brush.Swatch { id: id, color: p.color };
    return Colors { slots: out.slots.push(next), palette: out.palette.push(swatch), keys: out.keys.set(key, next), issue: "" };
}

fn bounds_size(w: u32, h: u32) -> json.Json {
    return json.array([json.number(frame.decimal(w)), json.number(frame.decimal(h))]);
}

fn member(key: String, raw: json.Json) -> json.Member { return json.Member { key: key, value: raw }; }

fn settings(w: u32, h: u32, raw: json.Json) -> json.Json {
    let fields = value.fields(raw);
    let defaults = [member("angle", json.number("0")), member("size", bounds_size(w, h)),
        member("swatch", json.object([member("mode", json.text("original"))]))];
    let primary = defaults.map(fn(row) =>
        json.lookup(fields, row.key).fold(fn(input) => member(row.key, input), fn(unit) => row));
    let extra = fields.filter(fn(row) => row.key != "angle" && row.key != "size" && row.key != "swatch");
    return json.object(primary.concat(extra));
}

fn capture_area(source: Source, area: Area, spec: List<json.Member>) -> Result<Capture, String> {
    let b = area.box;
    let initial = Colors { slots: Buffer.empty(), palette: Buffer.empty(), keys: Map.empty(), issue: "" };
    let captured = repeat_until(b.w * b.h, initial, fn(out) => out.issue != "", fn(i) => fn(out) =>
        capture_site(source, area, i, out));
    let pin = value.get(spec, "anchor");
    let anchor: Vec2<u32> = if pin == json.null() { vec2(quot_or(b.w - 1, 2, 0), quot_or(b.h - 1, 2, 0)) }
        else { brush.upair(pin, vec2(b.w - 1, b.h - 1)) };
    if captured.issue != "" || captured.palette.len() == 0 || anchor.x >= b.w || anchor.y >= b.h {
        return Err("A pixel brush needs a painted indexed shape and a native anchor");
    }
    let raw_settings = value.get(spec, "settings");
    if value.text(raw_settings) != "" || length(value.items(raw_settings)) != 0 { return Err("A pixel brush needs a finite angle, a bounded size and original or tint swatch settings"); }
    let authored = settings(b.w, b.h, raw_settings);
    let palette = captured.palette.freeze().map(fn(entry) =>
        Pigment { id: entry.id, color: brush_paint.color_text(entry.color) });
    let slots = captured.slots.freeze();
    let checked = brush.decode_settings(authored)?;
    return Ok(Capture { width: b.w, height: b.h, anchor: anchor, slots: slots, palette: palette, settings: authored });
}

