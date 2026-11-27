module StudioPixelInspect;

import "std:json" as json;
import "pixel_asset_export.ink" as assets;
import "pixel_brush_capture.ink" as labels;
import "pixel_brush_paint.ink" as colors;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_guarded_edit.ink" as guards;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_preview.ink" as preview;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Layer { fields: json.Json, id: String, parent: String, opacity: f64, }
record Report { document: json.Json, layers: List<Layer>, }
record Visibility { shown: Buffer<Bool>, required: Buffer<Bool>, used: Buffer<Bool>, }
record Drawing { art: frame.Artwork, indexed: preview.Raster, palette: List<json.Json>, used: List<Bool>, }
record LayerReport { row: frame.Layer, original: List<json.Member>, observation: frame.Observation,
    locked: Bool, contributes: Bool, cel: String, }
record Request { scope: frame.Scope, at: Vec2<u32>, references: Bool, }

fn number(n: u32) -> json.Json { return json.number(frame.decimal(n)); }
fn rgb(some: Bool, bits: u32) -> json.Json {
    return if some { json.text(colors.color_text(bits)) } else { json.null() };
}

fn entry<T>(key: String, raw: Option<T>, encode: fn(T) -> json.Json) -> List<json.Member> {
    return raw.fold(fn(item) => [history.member(key, encode(item))], fn(unit) => []);
}

fn parent_index(art: frame.Artwork, id: String) -> u32 {
    if id == "" { return 0; }
    return frame.clip_index(art.layers, id, length(art.layers)) + 1;
}

fn effective_lock(art: frame.Artwork, ordinal: u32) -> Bool {
    let row = art.layers.at_or(ordinal, frame.empty_layer());
    let last = repeat_until(length(art.layers), row, fn(layer) => layer.parent == "" || layer.locked,
        fn(i) => fn(layer) => paint.find_layer(art.layers, layer.parent));
    return last.locked;
}

fn contributes(art: frame.Artwork, layers: List<frame.Observation>) -> List<Bool> {
    let count = length(art.layers) + 1;
    let start: Buffer<Bool> = buffer_fill(count, false);
    let initial = Visibility { shown: start.set(0, true), required: buffer_fill(count, false), used: buffer_fill(count, false) };
    return foldr(layers, initial, fn(row) => fn(out) => contributor(art, row, out)).used.freeze();
}

fn contributor(art: frame.Artwork, row: frame.Observation, old: Visibility) -> Visibility {
    let layer = art.layers.at_or(row.ordinal, frame.empty_layer());
    let parent = parent_index(art, layer.parent);
    let slot = row.ordinal + 1;
    let paints = row.state == "paint" || row.state == "knockout";
    let relevant = old.shown.at_or(parent, false) && paints || old.required.at_or(slot, false);
    let clip = parent_index(art, layer.clip);
    let needed = if relevant && clip != 0 { old.required.set(clip, true) } else { old.required };
    let covers = relevant && paints && (layer.blend == "normal" || row.state == "knockout") &&
        row.effective.fold(fn(alpha) => alpha == 255, fn(unit) => false);
    let remaining = if covers { old.shown.set(parent, false) } else { old.shown };
    let scoped = if layer.kind == "group" { remaining.set(slot, relevant) } else { remaining };
    return Visibility { shown: scoped, required: needed, used: old.used.set(slot, relevant) };
}

fn selected_swatch(palette: List<json.Json>, slot: i32) -> json.Json {
    if slot < 0 { return json.null(); }
    let i = value.as_word(f64_from_i32(slot));
    let swatch = value.fields(palette.at_or(i, json.null()));
    return json.object([history.member("index", number(i))].concat(swatch));
}

fn blended_color(pixel: frame.Pixel) -> json.Json {
    return json.object([history.member("alpha", number(pixel.alpha)), history.member("color", rgb(pixel.alpha != 0, pixel.color))]);
}

fn common_layer(report: LayerReport) -> List<json.Member> {
    let row = report.row;
    let spec = report.original;
    let fields = report.observation;
    let label = json.lookup(spec, "label").fold(fn(raw) => raw, fn(unit) => json.text(row.id));
    let kind = if row.kind == "" { "paint" } else { row.kind };
    return [history.member("id", json.text(row.id)), history.member("label", label), history.member("kind", json.text(kind)),
        history.member("blend", json.text(row.blend)), history.member("visible", json.boolean(fields.visible)),
        history.member("locked", json.boolean(report.locked)), history.member("contributes", json.boolean(report.contributes)),
        history.member("cel", guards.nullable(report.cel))];
}

fn layer_scope(report: LayerReport) -> List<json.Member> {
    let row = report.row;
    let from_source = report.original.filter(fn(field) => field.key == "parent" || field.key == "destination");
    let clip: List<json.Member> = if row.clip == "" { [] } else { [history.member("clip",
        json.object([history.member("layer", json.text(row.clip)), history.member("alpha", number(report.observation.clip))]))] };
    let group: List<json.Member> = if row.kind == "group" { [history.member("children", json.array([]))] } else { [] };
    return from_source.concat(clip).concat(group);
}

fn layer_pixel(report: LayerReport, palette: List<json.Json>) -> List<json.Member> {
    let row = report.observation;
    let swatch = if report.row.kind == "group" { json.null() } else { selected_swatch(palette, row.slot) };
    return [history.member("swatch", swatch), history.member("color", rgb(row.slot >= 0, row.rgb)),
        history.member("sourceAlpha", number(if row.slot < 0 { 0 } else { row.alpha })),
        history.member("knockout", json.boolean(row.slot == -2)), history.member("status", json.text(row.state))]
        .concat(entry<u32>("effectiveAlpha", row.effective, fn(alpha) => number(alpha)))
        .concat(entry<frame.Pixel>("before", row.before, fn(pixel) => blended_color(pixel)))
        .concat(entry<frame.Pixel>("after", row.after, fn(pixel) => blended_color(pixel)));
}

fn layer_report(drawing: Drawing, step: frame.Observation) -> Layer {
    let layer = drawing.art.layers.at_or(step.ordinal, frame.empty_layer());
    let row = LayerReport { row: layer, original: value.fields(drawing.art.inputs.at_or(step.ordinal, json.null())),
        observation: step, locked: effective_lock(drawing.art, step.ordinal) || layer.kind == "reference",
        contributes: drawing.used.at_or(step.ordinal + 1, false), cel: drawing.indexed.cels.at_or(step.ordinal + 1, "") };
    let item = json.object(common_layer(row).concat(layer_scope(row)).concat(layer_pixel(row, drawing.palette)));
    return Layer { fields: item, id: layer.id, parent: layer.parent, opacity: step.opacity };
}

fn observed_frame(doc: List<json.Member>, id: String, revision: String) -> List<json.Member> {
    let raw = foldl(value.items(value.get(doc, "frames")), json.null(), fn(row) => fn(found) =>
        if frame.frame_name(row) == id { row } else { found });
    return [history.member("revision", json.text(revision)), history.member("frame", json.text(id)),
        history.member("durationMs", value.get(value.fields(raw), "durationMs")),
        history.member("pixelAspect", value.get(doc, "pixelAspect"))];
}

fn figure(r: preview.Raster, palette: List<json.Json>, art: frame.Artwork, cell: frame.Pixel, trace: u32) -> List<json.Member> {
    let owner = frame.owner(trace);
    let swatch = selected_swatch(palette, cell.slot);
    let shown = rgb(cell.alpha != 0, cell.color);
    let top = json.object([history.member("layer", guards.nullable(r.layers.at_or(owner, ""))),
        history.member("cel", guards.nullable(r.cels.at_or(owner, ""))), history.member("color", shown),
        history.member("alpha", number(cell.alpha))]);
    let method = if cell.slot < 0 { "transparent" } else {
        if cell.color == frame.color_at(art.colors, cell.slot) { "authored-index" } else { "layer-blend" }
    };
    let index = json.object([history.member("swatch", swatch), history.member("color", shown), history.member("method", json.text(method))]);
    return [history.member("composite", top), history.member("palette", index)];
}

fn contains_site(sites: List<u32>, p: u32) -> Bool {
    return foldl(sites, false, fn(site) => fn(found) => found || site == p);
}

fn protection_fields(doc: List<json.Member>, active: List<paint.Detail>, p: u32) -> json.Json {
    let rows = value.items(value.get(doc, "protectedDetails"));
    let matched = active.filter(fn(row) => contains_site(row.sites, p));
    return json.array(matched.map(fn(detail) => describe_protection(rows, detail)));
}

fn describe_protection(rows: List<json.Json>, detail: paint.Detail) -> json.Json {
    let raw = foldl(rows, json.null(), fn(row) => fn(found) =>
        if value.text(value.get(value.fields(row), "id")) == detail.id { row } else { found });
    let kind = if detail.kind == "" { "pixel" } else { detail.kind };
    return json.object([history.member("id", json.text(detail.id)), history.member("kind", json.text(kind))]
        .concat(value.fields(raw).filter(fn(field) => field.key == "frame" || field.key == "frames")));
}

fn validate_materials(source: json.Json, options: List<json.Member>) -> Result<Unit, String> {
    let raw = value.get(options, "destinations");
    if raw == json.null() { return Ok(()); }
    let message = "Choose a list of distinct surface destinations to inspect";
    let rows = json.elements(raw).map_err(fn(issue) => message)?;
    let names = rows.map(fn(row) => value.text(row));
    if length(names.filter(fn(name) => !commands.non_blank(name))) != 0 ||
        length(names.filter(fn(name) => length(names.filter(fn(other) => name == other)) != 1)) != 0 {
        return Err(message);
    }
    let first = rows.at_or(0, json.null());
    if first == json.null() { return Ok(()); }
    let route = history.destination(source, first);
    if route.id == "" { return Err(string_concat("Unknown pixel edit destination ", labels.label(first))); }
    if route.kind != "surface-channel" { return Err("Choose a surface-channel destination to sample its material source"); }
    return Err("Pixel editor has not implemented scene material inspection");
}

fn validate_binding(doc: List<json.Member>, options: List<json.Member>) -> Result<Unit, String> {
    if !value.has(options, "binding") { return Ok(()); }
    let binding = value.get(options, "binding");
    let bindings = value.items(value.get(doc, "sceneBindings"));
    let known = foldl(bindings, false, fn(row) => fn(found) => found || value.get(value.fields(row), "id") == binding);
    if !known { return Err(string_concat("Unknown pixel scene binding ", labels.label(binding))); }
    return Err("Binding inspection needs a captured scene view");
}

fn request(art: frame.Artwork, at: json.Json, options: List<json.Member>) -> Result<Request, String> {
    let frame_id = assets.scope_arg(options, "frame")?;
    let cel = assets.scope_arg(options, "cel")?;
    let scope = frame.resolve(art, frame_id, None, cel)?;
    let point = selection.point(value.items(at), art.grid);
    if !selection.inside(point, art.grid) { return Err("Use a pixel coordinate inside the native grid"); }
    return Ok(Request { scope: scope, at: point, references: assets.truthy(value.get(options, "references")) });
}

fn inspect(source: json.Json, art: frame.Artwork, revision: String, at: json.Json, options: json.Json) -> Result<Report, String> {
    let spec = value.fields(source);
    let settings = value.fields(options);
    let req = request(art, at, settings)?;
    let materials = validate_materials(source, settings)?;
    let binding = validate_binding(spec, settings)?;
    return report(source, art, revision, req);
}

fn report(source: json.Json, art: frame.Artwork, revision: String, req: Request) -> Result<Report, String> {
    let details = paint.protections(source, art)?;
    let active = paint.active_details(details, selection.named_slot(art.frames, req.scope.frame));
    let p = mask.index(art.grid, req.at);
    let check_gaps = !req.references && length(active.filter(fn(row) => row.kind == "gap")) != 0;
    let scene = frame.inspect_view(art, req.scope, req.references, p, check_gaps)?;
    let gap = if check_gaps { paint.gap_issue(art.grid, active, scene.view.pixels) } else { "" };
    if gap != "" { return Err(gap); }
    return Ok(describe(source, art, revision, req, active, p, scene));
}

fn describe(source: json.Json, art: frame.Artwork, revision: String, req: Request, active: List<paint.Detail>, p: u32,
    scene: frame.Inspected) -> Report {
    let doc = value.fields(source);
    let indexed = preview.index_view(art, req.scope.frame, active, scene.view);
    let cell = scene.view.pixels.at_or(scene.sample, frame.blank());
    let trace = scene.view.trace.at_or(scene.sample, 0);
    let scan = guards.Scan { grid: art.grid, ids: art.ids, visible: indexed, layer: "" };
    let top = value.fields(guards.actual_state(scan, req.at, p, cell, trace));
    let palette = value.fields(value.get(doc, "palette")).map(fn(row) => commands.swatch(row));
    let apparent = figure(indexed, palette, art, cell, trace);
    let drawing = Drawing { art: art, indexed: indexed, palette: palette, used: contributes(art, scene.observations) };
    let header = observed_frame(doc, req.scope.frame, revision);
    let body = header.concat(top).concat(apparent).concat([
        history.member("protection", protection_fields(doc, active, p)), history.member("materials", json.array([]))]);
    return Report { document: json.object(body), layers: scene.observations.map(fn(step) => layer_report(drawing, step)) };
}
