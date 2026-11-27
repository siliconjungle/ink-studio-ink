module StudioPixelTransform;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_capture.ink" as area;
import "pixel_brush_paint.ink" as palette_tools;
import "pixel_drawing_grid.ink" as grid;
import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;
import "pixel_rgba_edit.ink" as rgba;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Clip { version: u32, width: u32, height: u32, origin: Vec2<u32>,
    palette: List<brush.Swatch>, slots: List<i32>, alpha: List<u32>, }
record PackedClip { slots: List<i32>, alpha: List<u32>, }
record SlotCheck { painted: Bool, invalid: Bool, }
record ColorCapture { slots: Buffer<i32>, alpha: Buffer<u32>, indices: Buffer<i32>,
    palette: Buffer<brush.Swatch>, translucent: Bool, }
record Geometry { x: i32, y: i32, ow: u32, oh: u32, w: u32, h: u32, sx: f64, sy: f64,
    c: f64, s: f64, flip_x: Bool, flip_y: Bool, right_angle: Bool, refine: Bool, }
record Sampled { indices: Buffer<u32>, bounds: area.Bounds, found: Bool, }
record Sample { indices: List<u32>, region: mask.Rect, }
record Hit { pixel: u32, source: u32, slot: i32, alpha: u32, }
record Placed { mask: Buffer<u32>, hits: Buffer<Hit>, used: Buffer<Bool>, clipped: u32, }
record Palette { rows: List<brush.Swatch>, mapped: List<i32>, added: List<brush.Swatch>, issue: String, }
record Writes { slots: Buffer<i32>, alpha: Buffer<u32>, touched: Buffer<u32>, }
record Plan { mask: List<u32>, writes: List<rgba.Write>, added: List<brush.Swatch>, hits: List<Hit>,
    bounds: Vec4<i32>, clipped: u32, }
record Copy { width: u32, height: u32, origin: Vec2<u32>, palette: List<area.Pigment>, slots: List<i32>, alpha: List<u32>, }

fn clipboard(raw: json.Json, input: PackedClip) -> Result<Clip, String> {
    let fields = value.fields(raw);
    let error = "Invalid indexed pixel clipboard";
    let version = value.word(value.get(fields, "version"), 2);
    let w = value.word(value.get(fields, "width"), 512);
    let h = value.word(value.get(fields, "height"), 512);
    let origin = brush.upair(value.get(fields, "origin"), vec2(511, 511));
    if !value.only(fields, ["format", "version", "width", "height", "origin", "palette", "slots", "alpha"]) ||
        value.text(value.get(fields, "format")) != "ink-studio/pixel-clipboard" || version == 0 || version > 2 ||
        w == 0 || w > 512 || h == 0 || h > 512 || origin.x > 511 || origin.y > 511 { return Err(error); }
    let raw_palette = value.get(fields, "palette");
    let decoded: Result<List<json.Json>, String> = json.elements(raw_palette).fold(fn(rows) => Ok(rows), fn(e) => Err(error));
    let members = decoded?;
    if length(members) > 255 { return Err(error); }
    let palette = members.map(fn(row) => brush.swatch(value.fields(row), ["id", "color"]));
    let raw_slots = value.items(value.get(fields, "slots"));
    let slots = if length(input.slots) != 0 { input.slots } else {
        raw_slots.map(fn(raw) => if raw == json.null() { -3 } else {
            value.integer(raw, -2, grid.signed(length(palette)) - 1).fold(fn(n) => n, fn(unit) => -4)
        })
    };
    if length(slots) != w * h || !valid_slots(slots, grid.signed(length(palette))) ||
        length(palette.filter(fn(p) => p.color > 16777215)) != 0 { return Err(error); }
    let alpha: List<u32> = if !value.has(fields, "alpha") { [] } else {
        if length(input.alpha) == 0 { value.items(value.get(fields, "alpha")).map(fn(raw) => value.word(raw, 255)) } else { input.alpha }
    };
    if value.has(fields, "alpha") && (length(alpha) != length(slots) || length(alpha.filter(fn(n) => n > 255)) != 0) { return Err(error); }
    return Ok(Clip { version: version, width: w, height: h, origin: origin, palette: palette, slots: slots, alpha: alpha });
}

fn valid_slots(slots: List<i32>, limit: i32) -> Bool {
    let flags = repeat_until(length(slots), SlotCheck { painted: false, invalid: false }, fn(out) => out.invalid,
        fn(i) => fn(out) => check_slot(slots.at_or(i, -4), limit, out.painted));
    return flags.painted && !flags.invalid;
}

fn check_slot(slot: i32, limit: i32, painted: Bool) -> SlotCheck {
    return SlotCheck { painted: painted || slot != -3, invalid: slot < -3 || slot >= limit };
}

fn art_palette(art: frame.Artwork) -> List<brush.Swatch> {
    return art.ids.map_indexed(fn(i) => fn(id) => brush.Swatch { id: id, color: art.colors.at_or(i, 0) });
}

fn selection_bounds(g: mask.Grid, words: List<u32>) -> Result<mask.Rect, String> {
    let sites = mask.indices(words);
    if length(sites) == 0 { return Err("Select at least one pixel to capture"); }
    let b = foldl(sites, area.empty_bounds(g), fn(p) => fn(old) =>
        area.include(old, rem_or(p, g.width, 0), quot_or(p, g.width, 0)));
    return Ok(area.rectangle_from_bounds(b));
}

fn capture(art: frame.Artwork, current: frame.Captured, words: List<u32>) -> Result<Clip, String> {
    let palette = art_palette(art);
    let region = selection_bounds(art.grid, words)?;
    let init = ColorCapture { slots: Buffer.empty(), alpha: Buffer.empty(), indices: buffer_fill(length(palette), -1),
        palette: Buffer.empty(), translucent: false };
    let state = repeat_until(region.w * region.h, init, fn(out) => false, fn(i) => fn(out) =>
        capture_site(art.grid.width, current, palette, words, region, i, out));
    let slots = state.slots.freeze();
    let alpha = state.alpha.freeze();
    return Ok(Clip { version: 2, width: region.w, height: region.h,
        origin: vec2(region.x, region.y), palette: state.palette.freeze(), slots: slots,
        alpha: if state.translucent { alpha } else { [] } });
}

fn capture_site(width: u32, current: frame.Captured, palette: List<brush.Swatch>, words: List<u32>,
    b: mask.Rect, i: u32, old: ColorCapture) -> ColorCapture {
    let p = (b.y + quot_or(i, b.w, 0)) * width + b.x + rem_or(i, b.w, 0);
    let slot: i32 = if mask.selected(words, p) { current.slots.at_or(p, -1) } else { -3 };
    let opacity = if slot >= 0 { current.alpha.at_or(p, 255) } else { 255 };
    let alpha = if length(current.alpha) == 0 { old.alpha } else { old.alpha.push(opacity) };
    if slot < 0 { return ColorCapture { ..old, slots: old.slots.push(slot), alpha: alpha }; }
    let original = grid.unsigned(slot);
    let previous = old.indices.at_or(original, -1);
    let id = if previous >= 0 { previous } else { grid.signed(old.palette.len()) };
    let recent = ColorCapture { ..old, slots: old.slots.push(id), alpha: alpha,
        translucent: old.translucent || opacity != 255 };
    if previous >= 0 { return recent; }
    return ColorCapture { ..recent, palette: recent.palette.push(palette.at_or(original, brush.Swatch { id: "", color: 0 })),
        indices: recent.indices.set(original, id) };
}

fn normalized_angle(angle: f64) -> f64 { return brush.modulo(brush.modulo(angle, 360.0f64) + 360.0f64, 360.0f64); }

fn pair(raw: json.Json, lo: i32, hi: i32, otherwise: grid.Point) -> grid.Point {
    let xy = value.items(raw);
    if length(xy) != 2 { return otherwise; }
    let x = value.integer(xy.at_or(0, json.null()), lo, hi).fold(fn(n) => n, fn(unit) => otherwise.x);
    let y = value.integer(xy.at_or(1, json.null()), lo, hi).fold(fn(n) => n, fn(unit) => otherwise.y);
    return grid.Point { x: x, y: y };
}

fn absolute(x: f64) -> f64 { return if x < 0.0f64 { -x } else { x }; }

fn extent(measure: f64, base: u32, right: Bool) -> u32 {
    let n = value.as_word(ceil(measure));
    return if right || word_and(n, 1) == word_and(base, 1) { n } else { n + 1 };
}

fn geometry(clip: Clip, raw: json.Json) -> Result<Geometry, String> {
    let failure = "Invalid pixel transform settings";
    let read: Result<List<json.Member>, String> = json.members(raw).fold(fn(rows) => Ok(rows), fn(e) => Err(failure));
    let fields = read?;
    if !value.only(fields, ["at", "offset", "angle", "size", "flipX", "flipY", "rotation"]) { return Err(failure); }
    let invalid = grid.absent();
    let at = json.lookup(fields, "at").fold(fn(raw) => pair(raw, -4096, 4096, invalid), fn(unit) => grid.Point { x: 0, y: 0 });
    let offset = json.lookup(fields, "offset").fold(fn(raw) => pair(raw, -4096, 4096, invalid), fn(unit) => grid.Point { x: 0, y: 0 });
    let size: Vec2<u32> = json.lookup(fields, "size").fold(fn(raw) => brush.upair(raw, vec2(512, 512)),
        fn(unit) => vec2(clip.width, clip.height));
    let rotation = json.lookup(fields, "rotation").fold(fn(raw) => value.text(raw), fn(unit) => "nearest");
    let angle = json.lookup(fields, "angle").fold(fn(raw) => value.number(raw), fn(unit) => 0.0f64);
    let has_at = value.has(fields, "at");
    if (has_at && value.has(fields, "offset")) || at.x == invalid.x || at.y == invalid.y ||
        offset.x == invalid.x || offset.y == invalid.y || size.x == 0 || size.y == 0 || size.x > 512 || size.y > 512 ||
        !grid.bool_field(fields, "flipX") || !grid.bool_field(fields, "flipY") ||
        !brush.finite_between(angle, -360000.0f64, 360000.0f64) || !(rotation == "nearest" || rotation == "pixel-aware") {
        return Err("Use integer pixel positions and dimensions, a finite angle, and nearest or pixel-aware rotation");
    }
    let turn = normalized_angle(angle);
    let right = brush.modulo(turn, 90.0f64) == 0.0f64;
    let t = brush.rotation(angle);
    let w = f64_from_u32(size.x);
    let h = f64_from_u32(size.y);
    return Ok(Geometry { x: if has_at { at.x } else { grid.signed(clip.origin.x) + offset.x },
        y: if has_at { at.y } else { grid.signed(clip.origin.y) + offset.y },
        ow: extent(absolute(t.x) * w + absolute(t.y) * h, size.x, right),
        oh: extent(absolute(t.y) * w + absolute(t.x) * h, size.y, right),
        w: size.x, h: size.y, sx: f64_from_u32(clip.width) / w, sy: f64_from_u32(clip.height) / h,
        c: t.x, s: t.y, flip_x: value.flag(fields, "flipX", false), flip_y: value.flag(fields, "flipY", false),
        right_angle: right, refine: rotation == "pixel-aware" && !right });
}

fn same(clip: Clip, a: u32, b: u32) -> Bool {
    let slot = clip.slots.at_or(a, -3);
    return slot == clip.slots.at_or(b, -3) && (slot < 0 || clip.alpha.at_or(a, 255) == clip.alpha.at_or(b, 255));
}

fn corner(clip: Clip, x: u32, y: u32, fx: f64, fy: f64) -> u32 {
    let p = y * clip.width + x;
    let up = if y > 0 { p - clip.width } else { p };
    let down = if y + 1 < clip.height { p + clip.width } else { p };
    let left = if x > 0 { p - 1 } else { p };
    let right = if x + 1 < clip.width { p + 1 } else { p };
    if same(clip, up, down) || same(clip, left, right) { return p; }
    let horizontal = if fx < 0.5f64 { left } else { right };
    let vertical = if fy < 0.5f64 { up } else { down };
    return if same(clip, horizontal, vertical) { horizontal } else { p };
}

fn sample(clip: Clip, t: Geometry, col: u32, row: u32) -> u32 {
    if t.right_angle && t.w == clip.width && t.h == clip.height { return quarter_turn(clip, t, col, row); }
    let u = f64_from_u32(col) + 0.5f64 - f64_from_u32(t.ow) / 2.0f64;
    let v = f64_from_u32(row) + 0.5f64 - f64_from_u32(t.oh) / 2.0f64;
    let x = (t.c * u + t.s * v + f64_from_u32(t.w) / 2.0f64) * t.sx;
    let y = (-t.s * u + t.c * v + f64_from_u32(t.h) / 2.0f64) * t.sy;
    let i = floor(x);
    let j = floor(y);
    if i < 0.0f64 || j < 0.0f64 || i >= f64_from_u32(clip.width) || j >= f64_from_u32(clip.height) { return 4294967295; }
    let a = if t.flip_x { clip.width - 1 - value.as_word(i) } else { value.as_word(i) };
    let b = if t.flip_y { clip.height - 1 - value.as_word(j) } else { value.as_word(j) };
    let sx = if t.flip_x { 1.0f64 - (x - i) } else { x - i };
    let sy = if t.flip_y { 1.0f64 - (y - j) } else { y - j };
    let from = if t.refine { corner(clip, a, b, sx, sy) } else { b * clip.width + a };
    return if clip.slots.at_or(from, -3) == -3 { 4294967295 } else { from };
}

fn quarter_turn(clip: Clip, t: Geometry, col: u32, row: u32) -> u32 {
    let x = if t.c == 1.0f64 { col } else {
        if t.c == -1.0f64 { clip.width - 1 - col } else { if t.s > 0.0f64 { row } else { clip.width - 1 - row } }
    };
    let y = if t.c == 1.0f64 { row } else {
        if t.c == -1.0f64 { clip.height - 1 - row } else { if t.s > 0.0f64 { clip.height - 1 - col } else { col } }
    };
    let a = if t.flip_x { clip.width - 1 - x } else { x };
    let b = if t.flip_y { clip.height - 1 - y } else { y };
    let index = b * clip.width + a;
    return if clip.slots.at_or(index, -3) == -3 { 4294967295 } else { index };
}

fn scan(clip: Clip, t: Geometry) -> Sample {
    let init = Sampled { indices: Buffer.empty(), bounds: area.empty_bounds(mask.Grid { width: t.ow, height: t.oh }), found: false };
    let result = repeat_until(t.ow * t.oh, init, fn(out) => false, fn(i) => fn(out) =>
        scan_site(clip, t, rem_or(i, t.ow, 0), quot_or(i, t.ow, 0), out));
    let region = if !result.found { mask.Rect { x: 0, y: 0, w: t.ow, h: t.oh } }
        else { area.rectangle_from_bounds(result.bounds) };
    return Sample { indices: result.indices.freeze(), region: region };
}

fn scan_site(clip: Clip, t: Geometry, x: u32, y: u32, out: Sampled) -> Sampled {
    let p = sample(clip, t, x, y);
    let collected = out.indices.push(p);
    if p == 4294967295 { return Sampled { ..out, indices: collected }; }
    return Sampled { indices: collected, bounds: area.include(out.bounds, x, y), found: true };
}

fn native(g: mask.Grid, x: i32, y: i32) -> Bool {
    return x >= 0 && y >= 0 && x < grid.signed(g.width) && y < grid.signed(g.height);
}

fn place(g: mask.Grid, clip: Clip, t: Geometry, image: Sample, i: u32, out: Placed) -> Placed {
    let local = image.region;
    let u = rem_or(i, local.w, 0);
    let v = quot_or(i, local.w, 0);
    let from = if t.right_angle { sample(clip, t, u, v) }
        else { image.indices.at_or((local.y + v) * t.ow + local.x + u, 4294967295) };
    if from == 4294967295 { return out; }
    let x = t.x + grid.signed(u);
    let y = t.y + grid.signed(v);
    if !native(g, x, y) { return Placed { ..out, clipped: out.clipped + 1 }; }
    let pixel = grid.position(g, x, y);
    let source = (clip.origin.y + quot_or(from, clip.width, 0)) * g.width + clip.origin.x + rem_or(from, clip.width, 0);
    let slot = clip.slots.at_or(from, -3);
    let marked = if slot >= 0 { out.used.set(grid.unsigned(slot), true) } else { out.used };
    let entry = Hit { pixel: pixel, source: source, slot: slot, alpha: clip.alpha.at_or(from, 255) };
    return Placed { mask: mask.mark(out.mask, pixel), hits: out.hits.push(entry), used: marked, clipped: out.clipped };
}

fn palette_row(clip: Clip, used: List<Bool>, i: u32, old: Palette) -> Palette {
    if !used.at_or(i, false) { return Palette { ..old, mapped: old.mapped.concat([-1]) }; }
    let color = clip.palette.at_or(i, brush.Swatch { id: "", color: 0 });
    let lookup: Vec2<i32> = vec2(-1, -1);
    let match_color = repeat_until(length(old.rows), lookup, fn(out) => out.y >= 0, fn(j) => fn(out) =>
        palette_tools.prefer(old.rows.at_or(j, brush.Swatch { id: "", color: 4294967295 }), color, j, out));
    let separate = clip.version == 2 && color.id != "";
    let slot = if match_color.y >= 0 { match_color.y } else { if separate { -1 } else { match_color.x } };
    if slot >= 0 { return Palette { ..old, mapped: old.mapped.concat([slot]) }; }
    if separate && palette_tools.id_used(old.rows, color.id) {
        let len = mask.min(string_byte_len(color.id), 51);
        let id = string_slice(color.id, 0, len).fold(fn(s) => s, fn(unit) => "");
        let stem = string_concat(id, string_concat("-", palette_tools.color_digits(color.color)));
        return resolve_collision(old, color, stem);
    }
    let stem = if color.id != "" && !palette_tools.id_used(old.rows, color.id) { color.id }
        else { string_concat("brush-", palette_tools.color_digits(color.color)) };
    return append_color(old, color, palette_tools.available_id(old.rows, stem));
}

fn resolve_collision(old: Palette, color: brush.Swatch, stem: String) -> Palette {
    let state: Vec2<i32> = vec2(-1, -1);
    let choice = repeat_until(length(old.rows) + 1, state, fn(out) => out.x >= 0 || out.y >= 0, fn(i) => fn(out) =>
        collision(old.rows, color, collision_id(stem, i), i));
    if choice.x >= 0 { return Palette { ..old, mapped: old.mapped.concat([choice.x]) }; }
    return append_color(old, color, collision_id(stem, grid.unsigned(choice.y)));
}

fn collision_id(stem: String, i: u32) -> String {
    return if i == 0 { stem } else { string_concat(stem, string_concat("-", frame.decimal(i + 1))) };
}

fn collision(rows: List<brush.Swatch>, wanted: brush.Swatch, id: String, rank: u32) -> Vec2<i32> {
    let hit = repeat_until(length(rows), -1, fn(slot) => slot >= 0, fn(i) => fn(slot) =>
        if rows.at_or(i, brush.Swatch { id: "", color: 0 }).id == id { grid.signed(i) } else { slot });
    if hit < 0 { return vec2(-1, grid.signed(rank)); }
    return if rows.at_or(grid.unsigned(hit), wanted).color == wanted.color { vec2(hit, -1) } else { vec2(-1, -1) };
}

fn append_color(out: Palette, color: brush.Swatch, id: String) -> Palette {
    if length(out.rows) >= 255 { return Palette { ..out, issue: "Brush colors exceed the target palette limit" }; }
    let entry = brush.Swatch { ..color, id: id };
    return Palette { rows: out.rows.concat([entry]), mapped: out.mapped.concat([grid.signed(length(out.rows))]),
        added: out.added.concat([entry]), issue: "" };
}

fn assign(p: u32, slot: i32, alpha: u32, old: Writes) -> Writes {
    return Writes { slots: old.slots.set(p, slot), alpha: old.alpha.set(p, alpha), touched: mask.mark(old.touched, p) };
}

fn clear_source(g: mask.Grid, clip: Clip, i: u32, old: Writes) -> Writes {
    let slot = clip.slots.at_or(i, -3);
    if slot < -2 || slot == -1 { return old; }
    let x = clip.origin.x + rem_or(i, clip.width, 0);
    let y = clip.origin.y + quot_or(i, clip.width, 0);
    if x >= g.width || y >= g.height { return old; }
    return assign(y * g.width + x, -1, 255, old);
}

fn mapped_write(hit: Hit, palette: List<i32>) -> rgba.Write {
    let slot = if hit.slot < 0 { hit.slot } else { palette.at_or(grid.unsigned(hit.slot), -1) };
    return rgba.Write { pixel: hit.pixel, slot: slot, alpha: if slot < 0 { 255 } else { hit.alpha } };
}

fn placed_write(hit: Hit, palette: List<i32>, old: Writes) -> Writes {
    if hit.slot == -1 { return old; }
    let row = mapped_write(hit, palette);
    return assign(row.pixel, row.slot, row.alpha, old);
}

fn move_writes(g: mask.Grid, clip: Clip, hits: List<Hit>, palette: List<i32>) -> List<rgba.Write> {
    let init = Writes { slots: buffer_fill(mask.size(g), -3), alpha: buffer_fill(mask.size(g), 255), touched: mask.blank(g) };
    let cleared = repeat_until(length(clip.slots), init, fn(out) => false, fn(i) => fn(out) => clear_source(g, clip, i, out));
    let written = foldl(hits, cleared, fn(h) => fn(out) => placed_write(h, palette, out));
    let slots = written.slots.freeze();
    let alpha = written.alpha.freeze();
    return mask.indices(written.touched.freeze()).map(fn(p) =>
        rgba.Write { pixel: p, slot: slots.at_or(p, -1), alpha: alpha.at_or(p, 255) });
}

fn changed(row: rgba.Write, current: frame.Captured) -> Bool {
    let old = current.slots.at_or(row.pixel, -1);
    let alpha: u32 = if old < 0 { 255 } else { current.alpha.at_or(row.pixel, 255) };
    return row.slot != old || row.alpha != alpha;
}

fn stage(art: frame.Artwork, current: frame.Captured, clip: Clip, settings: json.Json, moving: Bool) -> Result<Plan, String> {
    let g = art.grid;
    let t = geometry(clip, settings)?;
    let image = if t.right_angle { Sample { indices: [], region: mask.Rect { x: 0, y: 0, w: t.ow, h: t.oh } } }
        else { scan(clip, t) };
    let b = image.region;
    let placed = repeat_until(b.w * b.h, Placed { mask: mask.blank(g), hits: Buffer.empty(),
        used: buffer_fill(length(clip.palette), false), clipped: 0 }, fn(out) => false, fn(i) => fn(out) =>
        place(g, clip, t, image, i, out));
    let hits = placed.hits.freeze();
    let used = placed.used.freeze();
    let words = placed.mask.freeze();
    let clipped = placed.clipped;
    let colors = repeat_until(length(clip.palette), Palette { rows: art_palette(art), mapped: [], added: [], issue: "" },
        fn(out) => out.issue != "", fn(i) => fn(out) => palette_row(clip, used, i, out));
    if colors.issue != "" { return Err(colors.issue); }
    let proposed = if moving { move_writes(g, clip, hits, colors.mapped) }
        else { hits.filter(fn(hit) => hit.slot != -1).map(fn(hit) => mapped_write(hit, colors.mapped)) };
    let writes = proposed.filter(fn(row) => changed(row, current));
    return Ok(Plan { mask: words, writes: writes, added: colors.added, hits: hits,
        bounds: vec4(t.x, t.y, grid.signed(b.w), grid.signed(b.h)), clipped: clipped });
}

fn selection_name(spec: List<json.Member>) -> Result<String, String> {
    let raw = value.get(spec, "selection");
    let label = if value.has(spec, "selection") { area.label(raw) } else { "undefined" };
    return json.as_text(raw).fold(fn(id) => Ok(id), fn(issue) => Err(string_concat("Unknown pixel selection ", label)));
}

fn copy_scope(art: frame.Artwork, named: selection.Named, spec: List<json.Member>, id: String) -> Result<frame.Scope, String> {
    let i = selection.named_slot(named.ids, id);
    if i == 4294967295 { return Err(string_concat("Unknown pixel selection ", id)); }
    let saved_frame = named.frames.at_or(i, "");
    let raw_frame = value.get(spec, "frame");
    let requested = value.text(raw_frame);
    if saved_frame != "" && value.has(spec, "frame") && requested != saved_frame {
        return Err(string_concat("Pixel selection belongs to frame ", saved_frame));
    }
    if raw_frame != json.null() && !json.as_text(raw_frame).fold(fn(text) => true, fn(issue) => false) {
        return Err(string_concat("Unknown pixel frame ", area.label(raw_frame)));
    }
    let frame_id = if raw_frame == json.null() { frame.optional_scope(saved_frame) } else { Some(requested) };
    let raw_layer = value.get(spec, "layer");
    let layer: Option<String> = if raw_layer == json.null() { None } else { area.option(spec, "layer") };
    let raw_cel = value.get(spec, "cel");
    if value.has(spec, "cel") && !json.as_text(raw_cel).fold(fn(text) => true, fn(issue) => false) {
        let scope = frame.resolve(art, frame_id, None, None)?;
        let suffix = frame_id.fold(fn(name) => string_concat(" on frame ", scope.frame), fn(unit) => "");
        return Err(string_concat("Unknown pixel cel ", string_concat(area.label(raw_cel), suffix)));
    }
    let scope = frame.resolve(art, frame_id, layer, area.option(spec, "cel"))?;
    if raw_layer != json.null() && !json.as_text(raw_layer).fold(fn(text) => true, fn(issue) => false) {
        return Err(string_concat("Unknown pixel layer ", area.label(raw_layer)));
    }
    return Ok(scope);
}

fn copy(art: frame.Artwork, named: selection.Named, document: json.Json, raw: json.Json) -> Result<Copy, String> {
    let spec = value.fields(raw);
    if value.has(spec, "layer") == value.has(spec, "cel") { return Err("Copy needs a source layer or cel"); }
    let id = selection_name(spec)?;
    let scope = copy_scope(art, named, spec, id)?;
    let source = frame.paint_view(art, scope)?;
    if !source.captured.found {
        return Err(string_concat("Unknown pixel layer ", if scope.layer == "" { "undefined" } else { scope.layer }));
    }
    let chosen = selection.recall_named(art.grid, named, scope.frame, id);
    if chosen.issue != "" { return Err(chosen.issue); }
    let result = capture(art, source.captured, chosen.mask)?;
    let palette = value.fields(value.get(value.fields(document), "palette"));
    let colors = result.palette.map(fn(row) => copy_swatch(palette, row));
    return Ok(Copy { width: result.width, height: result.height, origin: result.origin,
        palette: colors, slots: result.slots, alpha: result.alpha });
}

fn copy_swatch(palette: List<json.Member>, row: brush.Swatch) -> area.Pigment {
    let raw = value.get(palette, row.id);
    let color = json.as_text(raw).fold(fn(text) => text, fn(e) => value.text(value.get(value.fields(raw), "color")));
    return area.Pigment { id: row.id, color: color };
}
