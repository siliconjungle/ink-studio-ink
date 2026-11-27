module StudioPixelAssetExport;

import "std:json" as json;
import "pixel_brush_capture.ink" as names;
import "pixel_brush_paint.ink" as colors;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Raster { slots: List<i32>, alpha: List<u32>, knockouts: List<u32>, }
record IndexedRaster { colors: List<u32>, ids: List<String>, raster: Raster, }
record Named { id: String, pixels: List<Vec2<u32>>, }
record Stamp { info: json.Json, raster: Raster, selections: List<Named>, }
record DeckCel { layer: String, info: json.Json, raster: Raster, }
record DeckFrame { info: json.Json, cels: List<DeckCel>, selections: List<Named>, }
record Deck { info: json.Json, frames: List<DeckFrame>, shared: List<Named>, show_selections: Bool, }
record Blends { seen: Map<u32, i32>, slots: Buffer<i32>, added: Buffer<u32>, }
record Frames { rows: Buffer<DeckFrame>, issue: String, }

fn raw(captured: frame.Captured) -> Raster {
    let slots = captured.slots.map(fn(slot) => if slot < 0 { -1 } else { slot });
    let alpha = captured.alpha.map_indexed(fn(i) => fn(a) => if slots.at_or(i, -1) < 0 { 255 } else { a });
    let erased: Buffer<u32> = Buffer.empty();
    let knockouts = repeat_until(length(slots), erased, fn(out) => false,
        fn(i) => fn(out) => if captured.slots.at_or(i, -1) == -2 { out.push(i) } else { out });
    return Raster { slots: slots, alpha: alpha, knockouts: knockouts.freeze() };
}

fn next_blend(ids: List<String>, stem: String, i: u32, known: String) -> String {
    let id = string_concat(stem, string_concat("-", paint.number(i + 2)));
    return if selection.named_slot(ids, id) == 4294967295 { id } else { known };
}

fn blend_id(ids: List<String>, rgb: u32) -> String {
    let stem = string_concat("blend-", colors.color_digits(rgb));
    if selection.named_slot(ids, stem) == 4294967295 { return stem; }
    return repeat_until(length(ids), "", fn(found) => found != "", fn(i) => fn(found) => next_blend(ids, stem, i, found));
}

fn add_blend(palette: List<u32>, cell: frame.Pixel, out: Blends) -> Blends {
    if cell.slot < 0 || frame.color_at(palette, cell.slot) == cell.color {
        return Blends { ..out, slots: out.slots.push(cell.slot) };
    }
    let seen = out.seen.get_or(cell.color, -1);
    if seen >= 0 { return Blends { ..out, slots: out.slots.push(seen) }; }
    let index = i32_from_f64(f64_from_u32(length(palette) + out.added.len())).fold(fn(slot) => slot, fn(unit) => -1);
    return Blends { seen: out.seen.set(cell.color, index), slots: out.slots.push(index), added: out.added.push(cell.color) };
}

fn named_rows(g: mask.Grid, spec: List<json.Member>, positions: List<List<u32>>, id: String, shared: Bool) -> List<Named> {
    let rows = value.items(value.get(spec, "selections"));
    let initial: Buffer<Named> = Buffer.empty();
    return repeat_until(length(rows), initial, fn(out) => false, fn(i) => fn(out) =>
        active_selection(g, value.fields(rows.at_or(i, json.null())), positions.at_or(i, []), id, shared, out)).freeze();
}

fn active_selection(g: mask.Grid, row: List<json.Member>, indices: List<u32>, id: String, shared: Bool, out: Buffer<Named>) -> Buffer<Named> {
    let scope = value.text(value.get(row, "frame"));
    if (scope != id && !(shared && scope == "")) { return out; }
    let named = value.text(value.get(row, "id"));
    let pixels = if length(indices) == 0 {
        value.items(value.get(row, "pixels")).map(fn(at) => selection.point(value.items(at), g))
    } else { indices.map(fn(p) => vec2(rem_or(p, g.width, 0), quot_or(p, g.width, 0))) };
    return out.push(Named { id: named, pixels: pixels });
}

fn scoped_rows(spec: List<json.Member>, key: String, id: String, shared: Bool) -> List<json.Json> {
    return value.items(value.get(spec, key)).filter(fn(row) => on_frame(value.fields(row), id, shared));
}

fn on_frame(row: List<json.Member>, id: String, shared: Bool) -> Bool {
    let scope = value.text(value.get(row, "frame"));
    return scope == id || shared && scope == "";
}

fn local_fields(row: json.Json) -> json.Json {
    return json.object(value.fields(row).filter(fn(field) => field.key != "frame"));
}

fn when_rows(key: String, rows: List<json.Json>) -> List<json.Member> {
    return if length(rows) == 0 { [] } else { [history.member(key, json.array(rows))] };
}

fn palette_metadata(palette: List<json.Member>, ramps: List<json.Json>) -> List<json.Member> {
    let labels = palette.filter(fn(row) => value.has(value.fields(row.value), "label")).map(fn(row) =>
        history.member(row.key, value.get(value.fields(row.value), "label")));
    let locks = palette.filter(fn(row) => value.flag(value.fields(row.value), "locked", false))
        .map(fn(row) => json.text(row.key));
    let named: List<json.Member> = if length(labels) == 0 { [] } else { [history.member("swatchLabels", json.object(labels))] };
    return named.concat(when_rows("lockedSwatches", locks)).concat(when_rows("ramps", ramps));
}

fn stamp_info(spec: List<json.Member>, ids: List<String>, palette: List<json.Json>) -> List<json.Member> {
    return [history.member("width", value.get(spec, "width")), history.member("height", value.get(spec, "height")),
        history.member("origin", json.text("top-left")), history.member("palette", json.array(palette)),
        history.member("swatchIds", json.array(ids.map(fn(id) => json.text(id))))].concat(
        palette_metadata(value.fields(value.get(spec, "palette")), value.items(value.get(spec, "ramps"))));
}

fn scope_arg(spec: List<json.Member>, key: String) -> Result<Option<String>, String> {
    return json.lookup(spec, key).fold(fn(raw) => json.as_text(raw).fold(fn(name) => Ok(Some(name)),
        fn(error) => Err(string_concat("Unknown pixel ", string_concat(key, string_concat(" ", names.label(raw)))))), fn(unit) => Ok(None));
}

fn truthy(raw: json.Json) -> Bool {
    if raw == json.null() { return false; }
    return json.as_boolean(raw).fold(fn(b) => b, fn(error) => json.as_text(raw).fold(fn(s) => s != "",
        fn(error) => json.as_number(raw).fold(fn(token) => value.number(raw) != 0.0f64, fn(error) => true)));
}

fn checked_export(art: frame.Artwork, scope: frame.Scope, references: Bool, layers: Bool, details: List<paint.Detail>)
    -> Result<frame.ExportView, String> {
    let view = frame.export_view(art, scope, references, layers)?;
    if !references {
        let active = paint.active_details(details, selection.named_slot(art.frames, scope.frame));
        let issue = paint.gap_issue(art.grid, active, view.pixels);
        if issue != "" { return Err(issue); }
    }
    return Ok(view);
}

fn export_scope(art: frame.Artwork, settings: List<json.Member>) -> Result<frame.Scope, String> {
    let wanted_frame = scope_arg(settings, "frame")?;
    let wanted_cel = scope_arg(settings, "cel")?;
    let wanted_layer = scope_arg(settings, "layer")?;
    let scope = frame.resolve(art, wanted_frame, None, wanted_cel)?;
    return Ok(frame.Scope { ..scope, layer: wanted_layer.fold(fn(name) => name, fn(unit) => "") });
}

fn stamp(source: json.Json, art: frame.Artwork, positions: List<List<u32>>, options: json.Json) -> Result<Stamp, String> {
    let settings = value.fields(options);
    let scope = export_scope(art, settings)?;
    let selected = scoped_raster(source, art, settings, scope, truthy(value.get(settings, "references")))?;
    let spec = value.fields(source);
    let id = scope.frame;
    let guides = scoped_rows(spec, "guides", id, true).map(fn(row) => local_fields(row));
    let bindings = scoped_rows(spec, "sceneBindings", id, true);
    let info = when_rows("guides", guides).concat(when_rows("sceneBindings", bindings));
    let chosen = named_rows(art.grid, spec, positions, id, true);
    let palette = selected.colors.map(fn(rgb) => json.text(colors.color_text(rgb)));
    return Ok(Stamp { info: json.object(stamp_info(spec, selected.ids, palette).concat(info)),
        raster: selected.raster, selections: chosen });
}

fn scoped_raster(source: json.Json, art: frame.Artwork, settings: List<json.Member>, scope: frame.Scope,
    references: Bool) -> Result<IndexedRaster, String> {
    let details = paint.protections(source, art)?;
    let view = checked_export(art, scope, references, false, details)?;
    if value.has(settings, "layer") && !view.raw.found { return Err(string_concat("Unknown pixel layer ", scope.layer)); }
    if view.raw.found { return Ok(IndexedRaster { colors: art.colors, ids: art.ids, raster: raw(view.raw) }); }
    return Ok(composite_raster(art, view));
}

fn composite_raster(art: frame.Artwork, view: frame.ExportView) -> IndexedRaster {
    let start = Blends { seen: Map.empty(), slots: Buffer.empty(), added: Buffer.empty() };
    let blends = foldl(view.pixels, start, fn(cell) => fn(out) => add_blend(art.colors, cell, out));
    let added = blends.added.freeze();
    let ids = art.ids.concat(added.map(fn(rgb) => blend_id(art.ids, rgb)));
    let alpha = if view.uses_alpha { view.pixels.map(fn(cell) => if cell.slot < 0 { 255 } else { cell.alpha }) } else { [] };
    return IndexedRaster { colors: art.colors.concat(added), ids: ids,
        raster: Raster { slots: blends.slots.freeze(), alpha: alpha, knockouts: [] } };
}

fn deck_cel(art: frame.Artwork, view: frame.ExportView, cel: frame.Cel) -> DeckCel {
    let ordinal = frame.clip_index(art.layers, cel.layer, length(art.layers)) + 1;
    let empty = frame.RawLayer { owner: 0, view: frame.no_capture() };
    let layer = repeat_until(length(view.sources), empty, fn(found) => found.owner != 0, fn(i) => fn(found) =>
        if view.sources.at_or(i, empty).owner == ordinal { view.sources.at_or(i, empty) } else { found });
    return DeckCel { layer: cel.layer, info: json.object(cel.fields.filter(fn(field) =>
        commands.includes(["id", "label", "opacity"], field.key))), raster: raw(layer.view) };
}

fn deck_frame(spec: List<json.Member>, art: frame.Artwork, positions: List<List<u32>>, details: List<paint.Detail>, row: json.Json)
    -> Result<DeckFrame, String> {
    let fields = value.fields(row);
    let id = value.text(value.get(fields, "id"));
    let view = checked_export(art, frame.Scope { frame: id, layer: "" }, false, true, details)?;
    let cels = commands.frame_cels(fields, art.cels).map(fn(cel) => deck_cel(art, view, cel));
    let guide_fields = if value.has(spec, "guides") {
        [history.member("guides", json.array(scoped_rows(spec, "guides", id, false).map(fn(guide) => local_fields(guide))))]
    } else { [] };
    return Ok(DeckFrame { info: json.object(fields.filter(fn(field) =>
        commands.includes(["id", "label", "durationMs"], field.key)).concat(guide_fields)), cels: cels,
        selections: named_rows(art.grid, spec, positions, id, false) });
}

fn deck(source: json.Json, art: frame.Artwork, positions: List<List<u32>>) -> Result<Deck, String> {
    let spec = value.fields(source);
    let details = paint.protections(source, art)?;
    let frames = value.items(value.get(spec, "frames"));
    let start = Frames { rows: Buffer.empty(), issue: "" };
    let built = fold_until(frames, start, fn(row) => fn(out) => out.issue != "",
        fn(row) => fn(out) => add_frame(deck_frame(spec, art, positions, details, row), out));
    if built.issue != "" { return Err(built.issue); }
    return Ok(Deck { info: deck_info(spec, art), frames: built.rows.freeze(),
        shared: named_rows(art.grid, spec, positions, "", false), show_selections: value.has(spec, "selections") });
}

fn deck_info(spec: List<json.Member>, art: frame.Artwork) -> json.Json {
    let palette = value.fields(value.get(spec, "palette")).map(fn(row) => value.get(value.fields(commands.swatch(row)), "color"));
    let layers = art.inputs.map(fn(raw) => json.object(value.fields(raw).filter(fn(field) => field.key != "offset")));
    let global_guides = scoped_rows(spec, "guides", "", false);
    let extra = spec.filter(fn(field) =>
        commands.includes(["sceneBindings", "destinations", "protectedDetails", "artRules", "legacyMetadata", "tags", "directional", "tilemap", "slices"], field.key));
    let header = [history.member("format", json.text("ink-studio/pixel-layer-deck")), history.member("version", json.number("1")),
        history.member("pixelAspect", value.get(spec, "pixelAspect")), history.member("layers", json.array(layers))];
    return json.object(header.concat(stamp_info(spec, art.ids, palette)).concat(when_rows("guides", global_guides)).concat(extra));
}

fn add_frame(row: Result<DeckFrame, String>, out: Frames) -> Frames {
    return match row {
        Ok(frame_row) => Frames { ..out, rows: out.rows.push(frame_row) },
        Err(issue) => Frames { ..out, issue: issue },
    };
}
