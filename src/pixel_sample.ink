module StudioPixelSample;

import "std:json" as json;
import "pixel_asset_export.ink" as assets;
import "pixel_brush_capture.ink" as labels;
import "pixel_commands.ink" as commands;
import "pixel_frame.ink" as frame;
import "pixel_guarded_edit.ink" as guards;
import "pixel_history.ink" as history;
import "pixel_inspect.ink" as inspection;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

fn settings_mode(settings: List<json.Member>) -> Result<String, String> {
    let mode = json.lookup(settings, "mode").fold(fn(raw) => value.text(raw), fn(unit) => "composite");
    let layer = value.has(settings, "layer");
    let cel = value.has(settings, "cel");
    let source = mode == "source";
    let destination = json.as_text(value.get(settings, "destination")).fold(fn(s) => true, fn(issue) => false);
    if !commands.includes(["composite", "layer", "source"], mode) || (mode != "layer" && (layer || cel)) ||
        (!source && (value.has(settings, "destination") || value.has(settings, "uv"))) ||
        (mode == "layer" && layer == cel) || (source && !destination) {
        return Err("Sample the composite, a layer or cel, or a surface-channel destination");
    }
    return Ok(mode);
}

fn source_error(source: json.Json, key: json.Json) -> Result<json.Json, String> {
    let route = history.destination(source, key);
    if route.id == "" { return Err(string_concat("Unknown pixel edit destination ", labels.label(key))); }
    if route.kind != "surface-channel" { return Err("Choose a surface-channel destination to sample its material source"); }
    return Err("Pixel editor has not implemented sampling from scene material sources");
}

fn sampled_scope(art: frame.Artwork, settings: List<json.Member>) -> Result<frame.Scope, String> {
    let id = assets.scope_arg(settings, "frame")?;
    let layer = assets.scope_arg(settings, "layer")?;
    let cel = assets.scope_arg(settings, "cel")?;
    return frame.resolve(art, id, layer, cel);
}

fn sample(source: json.Json, art: frame.Artwork, revision: String, at: json.Json, options: json.Json) -> Result<json.Json, String> {
    let settings = value.fields(options);
    let mode = settings_mode(settings)?;
    let scope = sampled_scope(art, settings)?;
    return at_point(source, art, revision, at, settings, mode, scope);
}

fn at_point(source: json.Json, art: frame.Artwork, revision: String, at: json.Json, settings: List<json.Member>,
    mode: String, scope: frame.Scope) -> Result<json.Json, String> {
    let point = selection.point(value.items(at), art.grid);
    if !selection.inside(point, art.grid) && !(mode == "source" && at == json.null() && value.has(settings, "uv")) {
        return Err("Use a native pixel coordinate, or supply UV for a source channel");
    }
    if mode == "source" { return source_error(source, value.get(settings, "destination")); }
    return local_sample(source, art, revision, at, mode, scope, mask.index(art.grid, point));
}

fn local_sample(source: json.Json, art: frame.Artwork, revision: String, at: json.Json,
    mode: String, base: frame.Scope, p: u32) -> Result<json.Json, String> {
    let rules = paint.protections(source, art)?;
    let active = paint.active_details(rules, selection.named_slot(art.frames, base.frame));
    let check_gaps = length(active.filter(fn(row) => row.kind == "gap")) != 0;
    let viewed = frame.inspect_view(art, base, false, p, check_gaps)?;
    let issue = if check_gaps { paint.gap_issue(art.grid, active, viewed.view.pixels) } else { "" };
    if issue != "" { return Err(issue); }
    let header = inspection.observed_frame(value.fields(source), base.frame, revision)
        .concat([history.member("mode", json.text(mode)), history.member("at", at)]);
    let body = if mode == "layer" { raw(art, base, viewed) } else { Ok(composite(art, base.frame, active, p, viewed)) };
    let fields = body?;
    return Ok(json.object(header.concat(fields)));
}

fn raw(art: frame.Artwork, scope: frame.Scope, inspected: frame.Inspected) -> Result<List<json.Member>, String> {
    if !inspected.raw.found { return Err(string_concat("Unknown pixel layer ", scope.layer)); }
    let layer_index = frame.clip_index(art.layers, scope.layer, length(art.layers));
    let row = art.layers.at_or(layer_index, frame.empty_layer());
    let id = frame.active_cel(art.cels, scope.frame, scope.layer).id;
    let slot = inspected.raw.slots.at_or(inspected.sample, -1);
    let alpha = inspected.raw.alpha;
    let color = frame.color_at(art.colors, slot);
    let opacity: List<json.Member> = if length(alpha) == 0 { [] } else {
        [history.member("alpha", inspection.number(if slot < 0 { 0 } else { alpha.at_or(inspected.sample, 255) }))]
    };
    let lock: List<json.Member> = if row.kind == "reference" || inspection.effective_lock(art, layer_index) {
        [history.member("locked", json.boolean(true))]
    } else { [] };
    let common = pigment(art, scope.layer, id, slot, color);
    let flags = [history.member("knockout", json.boolean(slot == -2)),
        history.member("clipped", json.boolean(inspected.raw.clipping.at_or(inspected.sample, 255) == 0))];
    return Ok(common.concat(opacity).concat(flags).concat(lock));
}

fn composite(art: frame.Artwork, id: String, active: List<paint.Detail>, p: u32, viewed: frame.Inspected) -> List<json.Member> {
    let pixel = viewed.view.pixels.at_or(viewed.sample, frame.blank());
    let owner = frame.owner(viewed.view.trace.at_or(viewed.sample, 0));
    let layer = if owner == 0 { "" } else { art.layers.at_or(owner - 1, frame.empty_layer()).id };
    let cel = frame.active_cel(art.cels, id, layer).id;
    let alpha: List<json.Member> = if viewed.view.uses_alpha { [history.member("alpha", inspection.number(pixel.alpha))] } else { [] };
    let protected = pixel.locked || fold_until(active, false, fn(row) => fn(found) => found,
        fn(row) => fn(found) => inspection.contains_site(row.sites, p));
    return pigment(art, layer, cel, pixel.slot, pixel.color).concat(alpha)
        .concat([history.member("protected", json.boolean(protected))]);
}

fn pigment(art: frame.Artwork, layer: String, cel: String, slot: i32, color: u32) -> List<json.Member> {
    let name = if slot < 0 { "" } else { art.ids.at_or(u32_from_f64(f64_from_i32(slot)).fold(fn(n) => n, fn(unit) => 0), "") };
    return [history.member("layer", guards.nullable(layer)), history.member("cel", guards.nullable(cel)),
        history.member("swatch", guards.nullable(name)), history.member("color", inspection.rgb(slot >= 0, color))];
}
