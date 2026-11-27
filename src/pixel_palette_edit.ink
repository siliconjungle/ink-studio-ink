module StudioPixelPaletteEdit;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_capture.ink" as names;
import "pixel_commands.ink" as commands;
import "pixel_drawing_grid.ink" as drawing;
import "pixel_fault.ink" as fault;
import "pixel_frame.ink" as frame;
import "pixel_labels.ink" as labels;
import "pixel_paint.ink" as paint;
import "pixel_png_import.ink" as png_import;
import "pixel_raster.ink" as raster;
import "pixel_values.ink" as value;

record Palette { swatches: List<json.Json>, ramps: List<json.Json>, }
record Revision { palette: Palette, replacements: List<json.Member>, removed: List<json.Json>, }
record ArtEdit { source: json.Json, artwork: frame.Artwork, report: json.Json, }
record Translation { indices: List<i32>, changed: List<Bool>, replacements: List<json.Member>, }

fn bad(message: String) -> json.Json { return problem("invalid-edit", message, []); }
fn problem(code: String, message: String, details: List<json.Member>) -> json.Json {
    return json.object([paint.member("code", json.text(code)), paint.member("message", json.text(message))].concat(details));
}
fn locked(raw: json.Json) -> Result<Unit, json.Json> {
    let id = label(raw);
    if value.flag(value.fields(raw), "locked", false) {
        return Err(problem("locked-swatch", string_concat("Swatch ", string_concat(id, " is locked")),
            [paint.member("swatch", json.text(id))]));
    }
    return Ok(());
}
fn label(raw: json.Json) -> String { return value.text(value.get(value.fields(raw), "id")); }
fn color(raw: json.Json) -> json.Json { return value.get(value.fields(raw), "color"); }
fn label_field_valid(raw: json.Json) -> Bool { return commands.non_blank(value.text(raw)); }
fn boolean(raw: json.Json) -> Bool { return json.as_boolean(raw).fold(fn(b) => true, fn(issue) => false); }
fn rgb(raw: json.Json) -> Bool {
    let text = value.text(raw);
    return string_byte_len(text) == 7 && labels.byte(text, 0) == 35 &&
        repeat_until(6, true, fn(valid) => !valid, fn(i) => fn(valid) => hex(labels.byte(text, i + 1)));
}
fn hex(byte: u32) -> Bool { return byte >= 48 && byte <= 57 || byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102; }

fn optional_valid(fields: List<json.Member>, key: String, allow_clear: Bool) -> Bool {
    return json.lookup(fields, key).fold(fn(raw) => attribute_valid(raw, key, allow_clear), fn(unit) => true);
}

fn attribute_valid(raw: json.Json, key: String, allow_clear: Bool) -> Bool {
    if key == "label" { return allow_clear && raw == json.null() || label_field_valid(raw); }
    if key == "color" { return rgb(raw); }
    if key == "ramps" { return array(raw); }
    return boolean(raw);
}

fn find(rows: List<json.Json>, id: String) -> json.Json {
    return fold_until(rows, json.null(), fn(row) => fn(found) => found != json.null(),
        fn(row) => fn(found) => if label(row) == id { row } else { found });
}

fn contains(rows: List<String>, id: String) -> Bool {
    return fold_until(rows, false, fn(row) => fn(hit) => hit, fn(row) => fn(hit) => hit || row == id);
}

fn swatch_valid(raw: json.Json) -> Bool {
    let fields = value.fields(raw);
    return value.only(fields, ["id", "color", "label", "locked"]) && brush.stable_id(label(raw)) && rgb(color(raw)) &&
        optional_valid(fields, "label", false) && optional_valid(fields, "locked", false);
}

fn ramp_valid(ids: List<String>, raw: json.Json) -> Bool {
    let fields = value.fields(raw);
    let swatches = value.items(value.get(fields, "swatches")).map(fn(row) => value.text(row));
    return value.only(fields, ["id", "label", "swatches"]) && brush.stable_id(label(raw)) &&
        optional_valid(fields, "label", false) && length(swatches) >= 2 && png_import.distinct(swatches) &&
        foldl(swatches, true, fn(id) => fn(valid) => valid && contains(ids, id));
}

fn validate(palette: Palette) -> Result<Palette, json.Json> {
    if length(palette.swatches) == 0 || length(palette.swatches) > 255 ||
        !foldl(palette.swatches, true, fn(raw) => fn(valid) => valid && swatch_valid(raw)) {
        return Err(bad("A pixel palette needs 1–255 ordered RGB swatches with IDs, optional names and locks"));
    }
    let ids = palette.swatches.map(fn(row) => label(row));
    if !png_import.distinct(ids) { return Err(bad("Pixel swatch IDs must be unique")); }
    if length(palette.ramps) > 255 || !png_import.distinct(palette.ramps.map(fn(row) => label(row))) ||
        !foldl(palette.ramps, true, fn(row) => fn(valid) => valid && ramp_valid(ids, row)) {
        return Err(bad("Palette ramps need unique IDs and at least two distinct, existing swatches in order"));
    }
    return Ok(palette);
}

fn count_json(n: u32) -> json.Json {
    return json.number(frame.decimal(n));
}

fn asset(palette: Palette) -> json.Json {
    return json.object([paint.member("format", json.text("ink-studio/pixel-palette")),
        paint.member("version", count_json(1)),
        paint.member("swatches", json.array(palette.swatches)), paint.member("ramps", json.array(palette.ramps))]);
}

fn array(raw: json.Json) -> Bool { return json.elements(raw).fold(fn(rows) => true, fn(issue) => false); }
fn object(raw: json.Json) -> Bool { return json.members(raw).fold(fn(rows) => true, fn(issue) => false); }

fn read_asset(raw: json.Json) -> Result<Palette, json.Json> {
    let fields = value.fields(raw);
    if !value.only(fields, ["format", "version", "swatches", "ramps"]) ||
        value.text(value.get(fields, "format")) != "ink-studio/pixel-palette" ||
        value.number(value.get(fields, "version")) != 1.0f64 {
        return Err(bad("A pixel palette needs 1–255 ordered RGB swatches with IDs, optional names and locks"));
    }
    let parsed = validate(Palette { swatches: value.items(value.get(fields, "swatches")),
        ramps: value.items(value.get(fields, "ramps")) })?;
    if !optional_valid(fields, "ramps", false) {
        return Err(bad("Palette ramps need unique IDs and at least two distinct, existing swatches in order"));
    }
    return Ok(parsed);
}

fn put(rows: List<json.Json>, next: json.Json) -> List<json.Json> {
    let id = label(next);
    if find(rows, id) == json.null() { return rows.concat([next]); }
    return rows.map(fn(row) => if label(row) == id { next } else { row });
}

fn swatch_edit(before: Palette, change: json.Json) -> Result<Palette, json.Json> {
    let fields = value.fields(change);
    let id = label(change);
    if !value.only(fields, ["id", "color", "label", "locked"]) || !brush.stable_id(id) ||
        !optional_valid(fields, "color", false) ||
        !optional_valid(fields, "label", true) ||
        !optional_valid(fields, "locked", false) {
        return Err(bad("A swatch edit needs an ID and optional RGB, name or lock"));
    }
    let prior = find(before.swatches, id);
    let supplied = value.has(fields, "color");
    if prior == json.null() && !supplied { return Err(bad("New swatches need an RGB color")); }
    if prior != json.null() && supplied && frame.palette_color(color(prior)) != frame.palette_color(color(change)) {
        let accepted = locked(prior)?;
    }
    let merged = merge(value.fields(prior), fields);
    let row = json.object(merged.filter(fn(item) => item.key != "label" && item.key != "locked" ||
        item.key == "label" && item.value != json.null() || item.key == "locked" && item.value == json.boolean(true)));
    return Ok(Palette { ..before, swatches: put(before.swatches, row) });
}

fn merge(base: List<json.Member>, updates: List<json.Member>) -> List<json.Member> {
    return foldl(updates, base, fn(item) => fn(out) => paint.replace(out, item.key, item.value));
}

fn import_swatch(done: Result<Palette, json.Json>, row: json.Json) -> Result<Palette, json.Json> {
    let before = done?;
    let id = label(row);
    let prior = find(before.swatches, id);
    if prior == json.null() { return Ok(Palette { ..before, swatches: put(before.swatches, row) }); }
    if frame.palette_color(color(prior)) != frame.palette_color(color(row)) {
        let accepted = locked(prior)?;
        return Err(bad(string_concat("Imported swatch ", string_concat(id, " has a different RGB value"))));
    }
    let merged = merge(value.fields(row), value.fields(prior));
    let fields = if value.flag(value.fields(row), "locked", false) { paint.replace(merged, "locked", json.boolean(true)) } else { merged };
    return Ok(Palette { ..before, swatches: put(before.swatches, json.object(fields)) });
}

fn import_ramp(done: Result<Palette, json.Json>, row: json.Json) -> Result<Palette, json.Json> {
    let before = done?;
    let id = label(row);
    let prior = find(before.ramps, id);
    if prior == json.null() { return Ok(Palette { ..before, ramps: put(before.ramps, row) }); }
    if value.property(prior, "swatches") != value.property(row, "swatches") {
        return Err(bad(string_concat("Imported ramp ", string_concat(id, " has a different swatch order"))));
    }
    return Ok(before);
}

fn import_palette(before: Palette, raw: json.Json) -> Result<Palette, json.Json> {
    let incoming = read_asset(raw)?;
    let initial: Result<Palette, json.Json> = Ok(before);
    let merged = foldl(incoming.swatches, initial, fn(row) => fn(done) => import_swatch(done, row));
    return foldl(incoming.ramps, merged, fn(row) => fn(done) => import_ramp(done, row));
}

fn rearrange(before: Palette, raw: json.Json) -> Result<Palette, json.Json> {
    let ids = value.items(raw).map(fn(row) => value.text(row));
    let next = ids.map(fn(id) => find(before.swatches, id));
    if length(next) != length(before.swatches) || !png_import.distinct(ids) ||
        foldl(next, false, fn(row) => fn(invalid) => invalid || row == json.null()) {
        return Err(bad("Palette reorder needs every swatch ID exactly once"));
    }
    return Ok(Palette { ..before, swatches: next });
}

fn indexed(raw: json.Member, swatches: List<json.Json>) -> Result<json.Member, json.Json> {
    let parsed = json.number(raw.key);
    let index = value.word(parsed, 254);
    let wanted = value.word(raw.value, 254);
    if index >= length(swatches) || wanted >= length(swatches) || frame.decimal(index) != raw.key {
        return Err(bad("Remap indices must be zero-based integers in the current palette"));
    }
    return Ok(paint.member(label(swatches.at_or(index, json.null())), json.text(label(swatches.at_or(wanted, json.null())))));
}

fn remap_step(steps: Result<List<json.Member>, json.Json>, swatches: List<json.Json>,
    raw: json.Member, by_index: Bool) -> Result<List<json.Member>, json.Json> {
    let prior = steps?;
    let pair: Result<json.Member, json.Json> = if by_index { indexed(raw, swatches) } else { Ok(raw) };
    let row = pair?;
    let target = value.text(row.value);
    let source = find(swatches, row.key);
    if source == json.null() || find(swatches, target) == json.null() {
        return Err(bad("Remapping requires existing source and target swatches"));
    }
    if row.key == target { return Ok(prior); }
    let accepted = locked(source)?;
    return Ok(prior.concat([row]));
}

fn substitute(map: List<json.Member>, raw: json.Json) -> json.Json {
    return json.lookup(map, value.text(raw)).fold(fn(next) => next, fn(unit) => raw);
}

fn remap_ramp(raw: json.Json, map: List<json.Member>) -> Result<json.Json, json.Json> {
    let fields = value.fields(raw);
    let initial: List<json.Json> = [];
    let words = foldl(value.items(value.get(fields, "swatches")), initial, fn(row) => fn(out) =>
        add_unique(out, substitute(map, row)));
    if length(words) < 2 {
        return Err(bad(string_concat("Remap would leave ramp ", string_concat(label(raw), " with fewer than two swatches"))));
    }
    return Ok(json.object(paint.replace(fields, "swatches", json.array(words))));
}

fn add_unique(out: List<json.Json>, raw: json.Json) -> List<json.Json> {
    let found = foldl(out, false, fn(item) => fn(hit) => hit || item == raw);
    return if found { out } else { out.concat([raw]) };
}

fn drop_sources(before: Palette, map: List<json.Member>) -> Result<Palette, json.Json> {
    if foldl(map, false, fn(row) => fn(found) => found || value.has(map, value.text(row.value))) {
        return Err(bad("A remap target must stay in the palette when removing sources"));
    }
    let initial: Result<List<json.Json>, json.Json> = Ok([]);
    let ramps = foldl(before.ramps, initial, fn(row) => fn(done) => append_ramp(done, row, map))?;
    return Ok(Palette { swatches: before.swatches.filter(fn(row) => !value.has(map, label(row))), ramps: ramps });
}

fn append_ramp(done: Result<List<json.Json>, json.Json>, raw: json.Json, map: List<json.Member>)
    -> Result<List<json.Json>, json.Json> {
    let rows = done?;
    let next = remap_ramp(raw, map)?;
    return Ok(rows.concat([next]));
}

fn remap(before: Palette, op: List<json.Member>, by_index: Bool) -> Result<Revision, json.Json> {
    let keys = if by_index { ["type", "map"] } else { ["type", "map", "removeSources"] };
    let raw = value.get(op, "map");
    if !value.only(op, keys) || !object(raw) || !optional_valid(op, "removeSources", false) {
        return Err(bad("Remap needs a map of swatch IDs or zero-based palette indices"));
    }
    let empty: Result<List<json.Member>, json.Json> = Ok([]);
    let map = foldl(value.fields(raw), empty, fn(row) => fn(done) => remap_step(done, before.swatches, row, by_index))?;
    if length(map) == 0 { return Err(bad("Choose at least one different target swatch")); }
    if !value.flag(op, "removeSources", false) { return Ok(Revision { palette: before, replacements: map, removed: [] }); }
    let palette = drop_sources(before, map)?;
    return Ok(Revision { palette: palette, replacements: map, removed: map.map(fn(row) => json.text(row.key)) });
}

fn operation(before: Palette, op: List<json.Member>, kind: String) -> Result<Revision, json.Json> {
    if kind == "remap" || kind == "remap-indices" { return remap(before, op, kind == "remap-indices"); }
    let palette = edit_definition(before, op, kind)?;
    return Ok(Revision { palette: palette, replacements: [], removed: [] });
}

fn edit_definition(before: Palette, op: List<json.Member>, kind: String) -> Result<Palette, json.Json> {
    if kind == "swatch" && value.only(op, ["type", "swatch"]) { return swatch_edit(before, value.get(op, "swatch")); }
    let ramp = value.get(op, "ramp");
    if kind == "ramp" && value.only(op, ["type", "ramp"]) && brush.stable_id(label(ramp)) {
        return Ok(Palette { ..before, ramps: put(before.ramps, ramp) });
    }
    if kind == "remove-ramp" && value.only(op, ["type", "id"]) {
        let id = value.text(value.get(op, "id"));
        if find(before.ramps, id) == json.null() {
            return Err(bad(string_concat("Unknown palette ramp ", json.lookup(op, "id").fold(fn(raw) => names.label(raw), fn(unit) => "undefined"))));
        }
        return Ok(Palette { ..before, ramps: before.ramps.filter(fn(row) => label(row) != id) });
    }
    if kind == "reorder" && value.only(op, ["type", "order"]) { return rearrange(before, value.get(op, "order")); }
    if kind == "import" && value.only(op, ["type", "palette"]) { return import_palette(before, value.get(op, "palette")); }
    return Err(bad("Choose a palette swatch, ramp, reorder, import, or remap operation"));
}

fn authored(row: json.Json, before: Palette, fields: List<json.Member>) -> json.Member {
    let id = label(row);
    if find(before.swatches, id) == row { return paint.member(id, value.get(fields, id)); }
    let values = value.fields(row);
    let named = values.filter(fn(item) => item.key == "label" || item.key == "locked" && item.value == json.boolean(true));
    let raw = if length(named) == 0 { color(row) } else { json.object([paint.member("color", color(row))]
        .concat(named.filter(fn(item) => item.key == "label")).concat(named.filter(fn(item) => item.key == "locked"))) };
    return paint.member(id, raw);
}

fn map_slot(indices: List<i32>, old: i32) -> i32 {
    return if old < 0 { old } else { indices.at_or(drawing.unsigned(old), old) };
}
fn references(row: json.Json, map: List<json.Member>) -> Bool { return value.has(map, value.text(row)); }
fn changed_slot(plan: Translation, slot: i32) -> Bool { return slot >= 0 && plan.changed.at_or(drawing.unsigned(slot), false); }
fn swatch_reference(raw: json.Json) -> json.Json { return value.get(value.fields(raw), "swatch"); }

fn uses_replacement(cel: frame.Cel, planes: List<List<i32>>, plan: Translation) -> Bool {
    if length(plan.replacements) == 0 { return false; }
    return fold_until(planes.at_or(cel.plane - 1, []), false, fn(row) => fn(hit) => hit,
        fn(slot) => fn(hit) => hit || changed_slot(plan, slot)) ||
        foldl(value.items(value.get(cel.fields, "slots")), false, fn(row) => fn(hit) => hit || references(row, plan.replacements)) ||
        foldl(value.items(value.get(cel.fields, "marks")), false, fn(row) => fn(hit) => hit || references(swatch_reference(row), plan.replacements)) ||
        foldl(cel.runs, false, fn(row) => fn(hit) => hit || changed_slot(plan, row.slot));
}

fn remap_mark(raw: json.Json, map: List<json.Member>) -> json.Json {
    let old = swatch_reference(raw);
    return if references(old, map) { json.object(paint.replace(value.fields(raw), "swatch", substitute(map, old))) } else { raw };
}

fn remap_fields(fields: List<json.Member>, map: List<json.Member>) -> List<json.Member> {
    return fields.map(fn(row) => remap_field(row, map));
}

fn remap_field(row: json.Member, map: List<json.Member>) -> json.Member {
    if row.key == "marks" {
        return paint.member(row.key, json.array(value.items(row.value).map(fn(mark) => remap_mark(mark, map))));
    }
    if row.key == "slots" {
        return paint.member(row.key, json.array(value.items(row.value).map(fn(slot) => substitute(map, slot))));
    }
    return row;
}

fn recolor_cel(cel: frame.Cel, plan: Translation, remapped: Bool) -> frame.Cel {
    return frame.Cel { ..cel, fields: if remapped { remap_fields(cel.fields, plan.replacements) } else { cel.fields },
        prepared: cel.prepared.map(fn(row) => raster.RunMark { ..row, slot: map_slot(plan.indices, row.slot) }),
        runs: cel.runs.map(fn(row) => raster.RunMark { ..row, slot: map_slot(plan.indices, row.slot) }) };
}

fn changed_layers(cels: List<frame.Cel>, art: frame.Artwork) -> Result<Unit, json.Json> {
    let name = fold_until(cels, "", fn(cel) => fn(issue) => issue != "", fn(cel) => fn(issue) =>
        if paint.locked_layer(art.layers, paint.find_layer(art.layers, cel.layer)) { cel.layer } else { issue });
    if name != "" {
        let denied = fault.locked(name);
        return Err(problem(denied.code, denied.message, [paint.member("layer", json.text(name))]));
    }
    return Ok(());
}

fn guard_protection(source: json.Json, before: frame.Artwork, after: frame.Artwork) -> Result<Unit, json.Json> {
    let details = paint.protections(source, before).map_err(fn(issue) => bad(issue))?;
    let initial: Result<Unit, json.Json> = Ok(());
    return foldl(before.frames.map_indexed(fn(i) => fn(id) => i), initial, fn(index) => fn(checked) =>
        guard_frame(checked, before, after, index, paint.active_details(details, index)));
}

fn guard_frame(checked: Result<Unit, json.Json>, before: frame.Artwork, after: frame.Artwork,
    index: u32, details: List<paint.Detail>) -> Result<Unit, json.Json> {
    let valid = checked?;
    if length(details) == 0 { return Ok(()); }
    let scope = frame.Scope { frame: before.frames.at_or(index, ""), layer: "" };
    let left = frame.paint_view(before, scope).map_err(fn(issue) => bad(issue))?;
    let right = frame.paint_view(after, scope).map_err(fn(issue) => bad(issue))?;
    let change = foldl(details, paint.no_detail_change(), fn(row) => fn(prior) =>
        if prior.detail != "" { prior } else { changed_detail(before.ids, after.ids, row, left.pixels, right.pixels) });
    if change.detail == "" { return Ok(()); }
    let found = fault.dependent(before.grid, scope.frame, change.detail, change.pixel);
    return Err(problem(found.code, found.message, [paint.member("frame", json.text(scope.frame)),
        paint.member("detail", json.text(change.detail)), paint.member("at", json.array([
            count_json(rem_or(change.pixel, before.grid.width, 0)),
            count_json(quot_or(change.pixel, before.grid.width, 0))]))]));
}

fn changed_detail(before: List<String>, after: List<String>, row: paint.Detail,
    a: List<frame.Pixel>, b: List<frame.Pixel>) -> paint.DetailChange {
    let p: u32 = fold_until(row.sites, 4294967295, fn(site) => fn(found) => found != 4294967295,
        fn(site) => fn(found) => if same_pigment(before, after, a.at_or(site, frame.blank()), b.at_or(site, frame.blank())) { found } else { site });
    return if p == 4294967295 { paint.no_detail_change() } else { paint.DetailChange { detail: row.id, pixel: p } };
}

fn same_pigment(before: List<String>, after: List<String>, a: frame.Pixel, b: frame.Pixel) -> Bool {
    if a.alpha == 0 && b.alpha == 0 { return true; }
    return a.alpha == b.alpha && a.color == b.color && before.at_or(drawing.unsigned(a.slot), "") == after.at_or(drawing.unsigned(b.slot), "");
}

fn positions_changed(hits: List<Bool>) -> List<u32> {
    return hits.map_indexed(fn(i) => fn(hit) => if hit { i } else { 4294967295 }).filter(fn(i) => i != 4294967295);
}

fn saved_cel(cel: frame.Cel) -> paint.SavedCel {
    return paint.SavedCel { frame: cel.frame, layer: cel.layer, authored: json.object(cel.fields) };
}

record Recolored { artwork: frame.Artwork, saved: List<paint.SavedCel>, }

fn definition(source: json.Json) -> Palette {
    let fields = value.fields(source);
    return Palette { swatches: value.fields(value.get(fields, "palette")).map(fn(row) => commands.swatch(row)),
        ramps: value.items(value.get(fields, "ramps")) };
}

fn apply(source: json.Json, art: frame.Artwork, raw: json.Json, scoped: Bool) -> Result<ArtEdit, json.Json> {
    if scoped { return Err(bad("Palette edits apply to the whole document")); }
    let document = value.fields(source);
    let fields = value.fields(value.get(document, "palette"));
    let before = definition(source);
    let op = value.fields(raw);
    let kind = value.text(value.get(op, "type"));
    let edit = operation(before, op, kind)?;
    let after = validate(edit.palette)?;
    let mapped = map_artwork(art, after, edit.replacements)?;
    let protected = guard_protection(source, art, mapped.artwork)?;
    return Ok(ArtEdit { source: update_source(document, fields, before, after, mapped.saved),
        artwork: mapped.artwork, report: report(kind, before, after, edit, length(mapped.saved), value.get(op, "map")) });
}

fn map_artwork(art: frame.Artwork, after: Palette, map: List<json.Member>) -> Result<Recolored, json.Json> {
    let ids = after.swatches.map(fn(row) => label(row));
    let colors = after.swatches.map(fn(row) => frame.palette_color(color(row)));
    let positions = art.ids.map(fn(id) => raster.slot(ids, substitute(map, json.text(id))));
    let plan = Translation { indices: positions, changed: art.ids.map(fn(id) => value.has(map, id)), replacements: map };
    let hits = art.cels.map(fn(cel) => uses_replacement(cel, art.planes, plan));
    let affected = positions_changed(hits);
    let writable = changed_layers(affected.map(fn(index) => art.cels.at_or(index, frame.no_cel())), art)?;
    let indexed = positions != art.ids.map_indexed(fn(i) => fn(id) => drawing.signed(i));
    let cels = if indexed { art.cels.map_indexed(fn(i) => fn(cel) => recolor_cel(cel, plan, hits.at_or(i, false))) } else { art.cels };
    let planes = if indexed { art.planes.map(fn(plane) => plane.map(fn(slot) => map_slot(positions, slot))) } else { art.planes };
    return Ok(Recolored { artwork: frame.Artwork { ..art, ids: ids, colors: colors, cels: cels, planes: planes },
        saved: affected.map(fn(i) => saved_cel(cels.at_or(i, frame.no_cel()))) });
}

fn update_source(document: List<json.Member>, fields: List<json.Member>, before: Palette, after: Palette,
    saved: List<paint.SavedCel>) -> json.Json {
    let next = after.swatches.map(fn(row) => authored(row, before, fields));
    let palette = paint.replace(document, "palette", json.object(next));
    let metadata = if value.has(document, "ramps") || length(after.ramps) != 0 {
        paint.replace(palette, "ramps", json.array(after.ramps))
    } else { palette };
    if length(saved) == 0 { return json.object(metadata); }
    let frames = value.items(value.get(metadata, "frames")).map(fn(row) => paint.saved_frame(row, saved));
    return json.object(paint.replace(metadata, "frames", json.array(frames)));
}

fn report(kind: String, before: Palette, after: Palette, edit: Revision, n: u32, raw: json.Json) -> json.Json {
    let extra: List<json.Member> = if length(edit.replacements) == 0 { [] } else {
        [paint.member("remappedCels", count_json(n)), paint.member("map", json.object(edit.replacements)),
            paint.member("removed", json.array(edit.removed))]
    };
    let indices: List<json.Member> = if kind == "remap-indices" { [paint.member("indices", raw)] } else { [] };
    return json.object([paint.member("destination", json.text("palette")), paint.member("kind", json.text("palette")),
        paint.member("tool", json.text(kind)), paint.member("before", asset(before)), paint.member("after", asset(after))].concat(extra).concat(indices));
}
