module StudioPixelCommands;

import "std:json" as json;
import "pixel_brush_capture.ink" as names;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_labels.ink" as labels;
import "pixel_paint.ink" as paint;
import "pixel_values.ink" as value;

record Plan { action: String, destination: Option<String>, tool: Option<String>, }

fn edit(action: String) -> Bool {
    return action == "apply" || action == "draw" || action == "mask" || action == "recolor" || action == "transform";
}

fn includes(choices: List<String>, name: String) -> Bool {
    return foldl(choices, false, fn(candidate) => fn(found) => found || name == candidate);
}

fn members(action: String) -> Option<List<String>> {
    if edit(action) { return Some(["patch", "options"]); }
    if includes(["validate", "commit", "cancel", "undo", "redo", "record-batch"], action) { return Some([]); }
    if action == "inspect" { return Some(["at", "options"]); }
    if action == "select" { return Some(["query", "options"]); }
    if action == "preview" { return Some(["edit", "options"]); }
    if action == "begin" { return Some(["label"]); }
    if action == "replay" { return Some(["receipt"]); }
    if action == "batch" { return Some(["revision", "label", "commands"]); }
    if action == "replay-batch" { return Some(["batch"]); }
    if action == "revalidate-batch" || action == "export-review" { return Some(["batch", "options"]); }
    if action == "preview-recipe" { return Some(["recipe", "inputs", "options"]); }
    if action == "apply-recipe" { return Some(["plan", "approval"]); }
    if action == "export" { return Some(["artifact", "options"]); }
    return None;
}

fn required(action: String) -> List<String> {
    if edit(action) { return ["patch"]; }
    if action == "inspect" { return ["at"]; }
    if action == "select" { return ["query"]; }
    if action == "replay" { return ["receipt"]; }
    if action == "batch" { return ["revision", "commands"]; }
    if action == "replay-batch" || action == "revalidate-batch" { return ["batch"]; }
    if action == "preview-recipe" { return ["recipe"]; }
    if action == "apply-recipe" { return ["plan", "approval"]; }
    return [];
}

fn prepare(raw: json.Json) -> Result<List<json.Member>, String> {
    let issue = "Use a version 1 Ink pixel command with fields for its action";
    let spec = json.members(raw).map_err(fn(error) => issue)?;
    let action = value.text(value.get(spec, "action"));
    let allowed = members(action).ok_or(issue)?;
    let missing = required(action).filter(fn(name) => !value.has(spec, name));
    if value.text(value.get(spec, "format")) != "ink-studio/pixel-command" ||
        value.number(value.get(spec, "version")) != 1.0f64 ||
        !value.only(spec, ["format", "version", "action"].concat(allowed)) || length(missing) != 0 {
        return Err(issue);
    }
    return Ok(spec);
}

fn option_fields(action: String) -> List<String> {
    if edit(action) { return ["shotHitFrame"]; }
    if action == "inspect" { return ["frame", "cel", "binding", "destinations", "references"]; }
    if action == "select" { return ["frame", "layer", "cel", "targetRevision"]; }
    if action == "preview" { return ["limit", "exact", "shotHitFrame"]; }
    if action == "preview-recipe" || action == "revalidate-batch" { return ["limit", "exact"]; }
    if action == "export-review" { return ["out", "zoom", "views"]; }
    return [];
}

fn check_options(spec: List<json.Member>, fields: List<String>) -> Result<Unit, String> {
    let valid = json.lookup(spec, "options").fold(fn(raw) =>
        json.members(raw).fold(fn(rows) => value.only(rows, fields), fn(issue) => false), fn(unit) => true);
    return if valid { Ok(()) } else { Err("Unknown options for this pixel command") };
}

fn non_blank(text: String) -> Bool {
    let size = string_byte_len(text);
    let start: u32 = 0;
    let end = repeat_until(size, start, fn(p) => p >= size, fn(i) => fn(p) => skip_space(text, p));
    return end == size + 1;
}

fn skip_space(text: String, p: u32) -> u32 {
    let a = labels.byte(text, p);
    if a == 32 || a >= 9 && a <= 13 { return p + 1; }
    let b = labels.byte(text, p + 1);
    if a == 194 && b == 160 { return p + 2; }
    let c = labels.byte(text, p + 2);
    let wide = a == 225 && b == 154 && c == 128 || a == 227 && b == 128 && c == 128 ||
        a == 239 && b == 187 && c == 191 || a == 226 &&
        (b == 128 && (c >= 128 && c <= 138 || c == 168 || c == 169 || c == 175) || b == 129 && c == 159);
    return if wide { p + 3 } else { string_byte_len(text) + 1 };
}

fn no_edits(action: String) -> Plan { return Plan { action: action, destination: None, tool: None }; }

fn guessed_destination(action: String, operation: List<json.Member>) -> String {
    let kind = value.text(value.get(operation, "type"));
    if action == "mask" { return "selections"; }
    if action == "recolor" && includes(["swatch", "remap-indices"], kind) { return "palette"; }
    if action == "transform" && includes(["crop", "trim", "pad", "resize", "resample"], kind) { return "canvas"; }
    return "raster";
}

fn alias(source: json.Json, action: String, spec: List<json.Member>) -> Result<Plan, String> {
    let patch = json.members(value.get(spec, "patch")).map_err(fn(issue) => "A pixel edit command needs a guarded patch object")?;
    if action == "apply" { return Ok(no_edits(action)); }
    let raw = value.get(patch, "operation");
    let op = value.fields(raw);
    let request = json.lookup(patch, "destination").fold(fn(row) => row,
        fn(unit) => json.text(guessed_destination(action, op)));
    let route = history.destination(source, request);
    if route.id == "" { return Err(string_concat("Unknown pixel edit destination ", names.label(request))); }
    let chosen = value.text(request);
    let base = Plan { action: "apply", destination: Some(chosen), tool: None };
    let tool = value.text(value.get(op, "tool"));
    let surface = route.kind == "surface-channel";
    let raster = route.kind == "raster";
    let valid_operation = json.members(raw).fold(fn(rows) => true, fn(issue) => false);
    let kind = value.text(value.get(op, "type"));
    if action == "draw" && (surface || raster && (includes(["pencil", "eraser", "fill", "shape", "brush", "rgba", "cleanup"], tool) ||
        !value.has(patch, "operation") && json.elements(value.get(patch, "edits")).fold(fn(rows) => true, fn(issue) => false))) {
        return Ok(base);
    }
    let mask_channel = string_slice(route.channel, 0, 5).fold(fn(s) => s == "mask:", fn(unit) => false);
    if action == "mask" && (route.kind == "selections" || surface && mask_channel) { return Ok(base); }
    if action == "recolor" {
        if route.kind == "palette" && includes(["swatch", "remap-indices"], kind) ||
            surface && includes(["paint", "pigment"], route.channel) { return Ok(base); }
        if raster && valid_operation && (!value.has(op, "tool") || tool == "replace-swatch") {
            return Ok(Plan { ..base, tool: Some("replace-swatch") });
        }
    }
    if action == "transform" {
        if route.kind == "canvas" { return Ok(base); }
        if raster && valid_operation && (!value.has(op, "tool") || tool == "transform" || tool == "paste") {
            return Ok(Plan { ..base, tool: Some(if tool == "" { "transform" } else { tool }) });
        }
    }
    return Err(string_concat("Pixel ", string_concat(action, " command does not accept this destination or operation")));
}

fn export_plan(spec: List<json.Member>) -> Result<Plan, String> {
    let raw = value.get(spec, "artifact");
    let artifact = if raw == json.null() { "document" } else { names.label(raw) };
    let render = includes(["shot-corrections", "splat-fit", "scan-paint"], artifact);
    if !render && !includes(["document", "scene", "layer-deck", "stamp", "png", "preset"], artifact) {
        return Err(string_concat("Unknown pixel export artifact ", artifact));
    }
    let allowed = if artifact == "preset" { ["preset", "out", "directory"] } else {
        if artifact == "png" { ["frame", "cel", "layer", "colorMode"] } else {
            if artifact == "stamp" { ["frame", "cel", "layer", "references"] } else {
                if render { ["scene"] } else { [] }
            }
        }
    };
    let checked = check_options(spec, allowed)?;
    return Ok(no_edits(string_concat("export-", artifact)));
}

fn plan_batch_step(source: json.Json, raw: json.Json) -> Result<Plan, String> {
    let spec = prepare(raw)?;
    let action = value.text(value.get(spec, "action"));
    if !edit(action) { return Err("A batch step must be a pixel edit command"); }
    let checked = check_options(spec, option_fields(action))?;
    let patch = json.members(value.get(spec, "patch")).map_err(fn(issue) => "A batch step needs a pixel edit patch")?;
    return alias(source, action, spec);
}

fn plan(source: json.Json, raw: json.Json) -> Result<Plan, String> {
    let spec = prepare(raw)?;
    let action = value.text(value.get(spec, "action"));
    if edit(action) {
        let ready = alias(source, action, spec)?;
        let checked = check_options(spec, option_fields(action))?;
        return Ok(ready);
    }
    if action == "export" { return export_plan(spec); }
    let checked = check_options(spec, option_fields(action))?;
    if action == "begin" && value.has(spec, "label") && !non_blank(value.text(value.get(spec, "label"))) {
        return Err("A pixel transaction label needs text");
    }
    if action != "preview" { return Ok(no_edits(action)); }
    if !value.has(spec, "edit") { return Ok(no_edits("preview-draft")); }
    let nested = prepare(value.get(spec, "edit"))?;
    let proposed = value.text(value.get(nested, "action"));
    if !edit(proposed) { return Err("Preview needs a pixel edit command"); }
    let options = check_options(nested, option_fields(proposed))?;
    let ready = alias(source, proposed, nested)?;
    return Ok(Plan { ..ready, action: "preview-edit" });
}

fn describe(source: json.Json, art: frame.Artwork, revision: String) -> Result<json.Json, String> {
    let spec = value.fields(source);
    let details = paint.protections(source, art)?;
    let checked = repeat_until(length(art.frames), "", fn(issue) => issue != "", fn(i) => fn(previous) =>
        validate_frame(art, details, i));
    if checked != "" { return Err(checked); }
    let frames = value.items(value.get(spec, "frames"));
    let palette = value.fields(value.get(spec, "palette"));
    let empty: List<json.Json> = [];
    let cels = foldl(frames, empty, fn(row) => fn(out) => out.concat(described_cels(value.fields(row), art.cels)));
    let identities = json.object([history.member("layers", value.get(spec, "layers")),
        history.member("swatches", json.array(palette.map(fn(row) => swatch(row)))),
        history.member("cels", json.array(cels))]);
    let legacy = value.fields(value.get(spec, "legacyMetadata"));
    let aseprite = legacy.filter(fn(row) => row.key == "aseprite");
    let file = if value.has(legacy, "asepriteFile") {
        value.fields(value.get(legacy, "asepriteFile")).filter(fn(row) => row.key == "report")
            .map(fn(row) => history.member("asepriteFile", row.value))
    } else { [] };
    return Ok(json.object([history.member("format", json.text("ink-studio/pixel-art")), history.member("version", json.number("2")),
        history.member("revision", json.text(revision)), history.member("grid", json.array([value.get(spec, "width"), value.get(spec, "height")])),
        history.member("pixelAspect", value.get(spec, "pixelAspect")), history.member("frames", json.array(frames.map(fn(row) =>
            json.object(value.fields(row).filter(fn(field) => includes(["id", "durationMs", "label"], field.key)))))),
        history.member("identities", identities)].concat(spec.filter(fn(field) =>
            includes(["artRules", "protectedDetails", "ramps", "tags", "directional", "tilemap", "slices", "guides", "destinations"], field.key)))
            .concat(aseprite).concat(file)));
}

fn validate_frame(art: frame.Artwork, details: List<paint.Detail>, index: u32) -> String {
    let id = art.frames.at_or(index, "");
    let issue = frame.paint_view(art, frame.Scope { frame: id, layer: "" }).fold(fn(view) =>
        paint.gap_issue(art.grid, paint.active_details(details, index), view.pixels), fn(error) => error);
    return if issue == "" { "" } else { string_concat("Pixel frame ", string_concat(id, string_concat(": ", issue))) };
}

fn described_cels(spec: List<json.Member>, cels: List<frame.Cel>) -> List<json.Json> {
    return frame_cels(spec, cels).map(fn(cel) => describe_cel(cel));
}

fn frame_cels(spec: List<json.Member>, cels: List<frame.Cel>) -> List<frame.Cel> {
    let id = value.text(value.get(spec, "id"));
    let authored = value.fields(value.get(spec, "cels"));
    let existing = authored.map(fn(row) => frame.active_cel(cels, id, row.key));
    let added = cels.filter(fn(row) => row.frame == id && !value.has(authored, row.layer));
    return existing.concat(added);
}

fn describe_cel(cel: frame.Cel) -> json.Json {
    return json.object([history.member("id", json.text(cel.id)), history.member("frame", json.text(cel.frame)),
        history.member("layer", json.text(cel.layer))].concat(cel.fields.filter(fn(row) => row.key == "label")));
}

fn swatch(row: json.Member) -> json.Json {
    let fields = value.fields(row.value);
    let color = json.as_text(row.value).fold(fn(rgb) => row.value, fn(issue) => value.get(fields, "color"));
    let locked = if value.flag(fields, "locked", false) { [history.member("locked", json.boolean(true))] } else { [] };
    return json.object([history.member("id", json.text(row.key)), history.member("color", color)]
        .concat(fields.filter(fn(field) => field.key == "label")).concat(locked));
}
