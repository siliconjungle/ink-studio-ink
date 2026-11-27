module StudioPixelGuardedEdit;

import "std:json" as json;
import "pixel_fault.ink" as fault;
import "pixel_frame.ink" as frame;
import "pixel_history.ink" as history;
import "pixel_mask.ink" as mask;
import "pixel_paint.ink" as paint;
import "pixel_preview.ink" as preview;
import "pixel_raster.ink" as raster;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Mark { at: Vec2<u32>, slot: i32, }
record Target { frame: String, layer: String, cel: String, pixels: List<Vec2<u32>>, }
record Edit { document: json.Json, artwork: frame.Artwork, target: Target, cache: paint.CachedView, diff: Option<preview.Pair>, }
record Observed { raster: preview.Raster, active: List<paint.Detail>, details: List<paint.Detail>, }
record Scan { grid: mask.Grid, ids: List<String>, visible: preview.Raster, layer: String, }
record Checks { visited: Buffer<u32>, marks: Buffer<Mark>, issues: Buffer<json.Json>, }

fn at(point: Vec2<u32>) -> json.Json {
    return json.array([json.number(frame.decimal(point.x)), json.number(frame.decimal(point.y))]);
}

fn nullable(text: String) -> json.Json { return if text == "" { json.null() } else { json.text(text) }; }

fn invalid(message: String) -> List<json.Json> { return [history.problem("invalid-edit", message, [])]; }

fn fault_issue(issue: fault.Fault) -> List<json.Json> {
    let layer: List<json.Member> = if issue.layer == "" { [] } else { [history.member("layer", json.text(issue.layer))] };
    let frame_id: List<json.Member> = if issue.frame_id == "" { [] } else { [history.member("frame", json.text(issue.frame_id))] };
    let detail: List<json.Member> = if issue.detail == "" { [] } else { [history.member("detail", json.text(issue.detail))] };
    let site: List<json.Member> = issue.at.fold(fn(point) => [history.member("at", at(point))], fn(unit) => []);
    return [history.problem(issue.code, issue.message, layer.concat(frame_id).concat(detail).concat(site))];
}

fn observed(source: json.Json, art: frame.Artwork, id: String) -> Result<Observed, List<json.Json>> {
    let details = paint.protections(source, art).map_err(fn(issue) => invalid(issue))?;
    let active = paint.active_details(details, selection.named_slot(art.frames, id));
    let compiled = checked_view(art, id, active)?;
    return Ok(Observed { raster: compiled, active: active, details: details });
}

fn checked_view(art: frame.Artwork, id: String, active: List<paint.Detail>) -> Result<preview.Raster, List<json.Json>> {
    let compiled = preview.raster(art, id, active, false).map_err(fn(issue) => invalid(issue))?;
    let issue = paint.gap_issue(art.grid, active, compiled.view.pixels);
    if issue != "" { return Err(invalid(issue)); }
    return Ok(compiled);
}

fn selected_layer(art: frame.Artwork, id: String, frame_id: String, cel: Option<String>) -> Result<frame.Scope, List<json.Json>> {
    if cel.fold(fn(name) => true, fn(unit) => false) {
        return paint.target(art, [], Some(frame_id), cel).map_err(fn(issue) => fault_issue(issue));
    }
    if paint.find_layer(art.layers, id).id != "" {
        return Err(invalid("A raster edit needs a new layer ID and pixel edits"));
    }
    return Ok(frame.Scope { frame: frame_id, layer: id });
}

fn invalid_pixel(site: json.Json) -> json.Json {
    let details: List<json.Member> = json.elements(site).fold(fn(rows) => [history.member("at", site)], fn(issue) => []);
    return history.problem("invalid-pixel", "A pixel edit needs at, from, layer and to", details);
}

fn owner_fields(location: preview.Location) -> List<json.Member> {
    return [history.member("layer", nullable(location.layer)), history.member("cel", nullable(location.cel)),
        history.member("swatch", nullable(location.swatch))];
}

fn actual_state(scan: Scan, point: Vec2<u32>, p: u32, cell: frame.Pixel, trace: u32) -> json.Json {
    let r = scan.visible;
    let location = preview.location(r, frame.owner(trace), preview.swatch_index(cell.slot));
    let below = preview.location(r, frame.under_owner(trace), frame.under_swatch(trace));
    let alpha: List<json.Member> = if r.view.uses_alpha { [history.member("alpha", json.number(frame.decimal(cell.alpha)))] } else { [] };
    return json.object([history.member("at", at(point))].concat(owner_fields(location)).concat([
        history.member("protected", json.boolean(preview.protected(r, p, cell))),
        history.member("underneath", json.object(owner_fields(below))) ]).concat(alpha));
}

fn expected_state(fields: List<json.Member>) -> json.Json {
    return json.object([history.member("layer", value.get(fields, "layer")),
        history.member("swatch", value.get(fields, "from"))]);
}

fn conflict_at(scan: Scan, fields: List<json.Member>, point: Vec2<u32>, p: u32, cell: frame.Pixel,
    trace: u32, code: String) -> json.Json {
    let message = string_concat("Pixel edit no longer applies at ", coords(scan.grid, p));
    return history.problem(code, message, [history.member("at", at(point)),
        history.member("expected", expected_state(fields)), history.member("actual", actual_state(scan, point, p, cell, trace))]);
}

fn coords(grid: mask.Grid, p: u32) -> String {
    return string_concat(frame.decimal(rem_or(p, grid.width, 0)), string_concat(",", frame.decimal(quot_or(p, grid.width, 0))));
}

fn matches_guard(observed: String, expected: json.Json) -> Bool {
    return if observed == "" { expected == json.null() } else { observed == value.text(expected) };
}

fn guard_code(scan: Scan, fields: List<json.Member>, cell: frame.Pixel, trace: u32, p: u32, visited: Bool) -> String {
    if visited { return "duplicate-pixel"; }
    if preview.protected(scan.visible, p, cell) { return "protected-pixel"; }
    let swatch = scan.visible.swatches.at_or(preview.swatch_index(cell.slot), "");
    let layer = scan.visible.layers.at_or(frame.owner(trace), "");
    if !matches_guard(swatch, value.get(fields, "from")) || !matches_guard(layer, value.get(fields, "layer")) {
        return "pixel-changed";
    }
    if scan.layer != "" && layer != "" && layer != scan.layer { return "wrong-cel"; }
    return "";
}

fn check_mark(scan: Scan, raw: json.Json, old: Checks) -> Checks {
    let fields = value.fields(raw);
    let site = value.get(fields, "at");
    let point = selection.point(value.items(site), scan.grid);
    let requested = value.get(fields, "to");
    let slot: i32 = if value.has(fields, "to") { raster.slot(scan.ids, requested) } else { -3 };
    if !selection.inside(point, scan.grid) || slot == -3 ||
        !value.has(fields, "from") || !value.has(fields, "layer") {
        return Checks { ..old, issues: old.issues.push(invalid_pixel(site)) };
    }
    let p = mask.index(scan.grid, point);
    let visited = word_and(old.visited.at_or(mask.word_slot(p), 0), mask.word_bit(p)) != 0;
    let cell = scan.visible.view.pixels.at_or(p, frame.blank());
    let trace = scan.visible.view.trace.at_or(p, 0);
    let code = guard_code(scan, fields, cell, trace, p, visited);
    let pending = mask.mark(old.visited, p);
    if code == "" {
        return Checks { ..old, visited: pending, marks: old.marks.push(Mark { at: point, slot: slot }) };
    }
    return Checks { ..old, visited: pending, issues: old.issues.push(conflict_at(scan, fields, point, p, cell, trace, code)) };
}

fn read_marks(scan: Scan, edits: json.Json) -> Result<List<Mark>, List<json.Json>> {
    let rows = value.items(edits);
    if length(rows) == 0 || length(rows) > 4096 { return Err(invalid("Pixel paint needs 1–4096 edits")); }
    let start = Checks { visited: mask.blank(scan.grid), marks: Buffer.empty(), issues: Buffer.empty() };
    let checked = foldl(rows, start, fn(row) => fn(out) => check_mark(scan, row, out));
    if checked.issues.len() != 0 { return Err(checked.issues.freeze()); }
    return Ok(checked.marks.freeze());
}

fn add_layer(art: frame.Artwork, source: json.Json, name: String) -> Result<preview.Page, List<json.Json>> {
    let count = length(art.layers) + 1;
    if count > 64 || mask.size(art.grid) * count > 4000000 {
        return Err(invalid("Pixel art needs a native grid, a palette and up to 64 bounded layers"));
    }
    let fields = value.fields(source);
    let layer = json.object([history.member("id", json.text(name))]);
    let inputs = art.inputs.concat([layer]);
    let document = json.object(paint.replace(fields, "layers", json.array(inputs)));
    return Ok(preview.Page { source: document, art: frame.Artwork { ..art, inputs: inputs,
        layers: art.layers.concat([frame.layer_spec(layer)]) } });
}

fn point_span(mark: Mark) -> Vec3<u32> { return vec3(mark.at.y, mark.at.x, 1); }

fn outside(grid: mask.Grid, placement: frame.Placement, marks: List<Mark>) -> Option<Mark> {
    if placement.x == 0 && placement.y == 0 { return None; }
    let start: Option<Mark> = None;
    return fold_until(marks, start, fn(mark) => fn(found) => found.fold(fn(row) => true, fn(unit) => false),
        fn(mark) => fn(found) => found.fold(fn(row) => Some(row), fn(unit) =>
            paint.local_run(grid, placement, point_span(mark)).fold(fn(row) => None, fn(issue) => Some(mark))));
}

fn local_marks(art: frame.Artwork, scope: frame.Scope, marks: List<Mark>, id: String) -> Result<paint.Appended, List<json.Json>> {
    let cel = frame.active_cel(art.cels, scope.frame, scope.layer);
    let n = frame.clip_index(art.layers, scope.layer, length(art.layers));
    let placement = frame.placement(art.inputs.at_or(n, json.null()), cel);
    let failed = outside(art.grid, placement, marks);
    if failed.fold(fn(row) => true, fn(unit) => false) {
        let site = failed.fold(fn(row) => at(row.at), fn(unit) => json.null());
        return Err([history.problem("outside-cel", "Edit lies outside the shifted cel grid",
            [history.member("at", site), history.member("layer", json.text(scope.layer))])]);
    }
    let authored = marks.map(fn(mark) => raster.RunMark { slot: mark.slot, alpha: None, spans: [point_span(mark)], point: true });
    if placement.x == 0 && placement.y == 0 { return Ok(paint.append_local_marks(art, scope, cel, authored, id)); }
    return paint.append_marks(art, scope, authored, id).map_err(fn(issue) => invalid(issue));
}

fn clipped(r: preview.Raster, g: mask.Grid, id: String, mark: Mark) -> Option<json.Json> {
    let p = mask.index(g, mark.at);
    let trace = r.view.trace.at_or(p, 0);
    let cell = r.view.pixels.at_or(p, frame.blank());
    let owner = r.cels.at_or(frame.owner(trace), "");
    if owner == id && (cell.slot == mark.slot || cell.slot < 0 && mark.slot == -2) { return None; }
    return Some(history.problem("clipped-pixel", string_concat("Pixel cel edit is clipped at ", coords(g, p)),
        [history.member("at", at(mark.at))]));
}

fn verify_cel(before: frame.Artwork, after: frame.Artwork, old: Observed) -> Result<Unit, List<json.Json>> {
    return paint.check_dependent_frames(before, after, old.details, "").map_err(fn(issue) => fault_issue(issue));
}

fn finalize(art: frame.Artwork, page: preview.Page, scope: frame.Scope, marks: List<Mark>, old: Observed,
    creating: Bool, reuse_composites: Bool) -> Result<Edit, List<json.Json>> {
    let id = paint.choose_cel(page.art, scope);
    let retained = local_marks(page.art, scope, marks, id)?;
    let next = paint.attach(page.art, scope, id, retained);
    let dependencies: Result<Unit, List<json.Json>> = if creating { Ok(()) } else { verify_cel(art, next, old) };
    let checked = dependencies?;
    let viewed = checked_view(next, scope.frame, old.active)?;
    let misses: List<json.Json> = if creating { [] } else {
        marks.map(fn(mark) => clipped(viewed, next.grid, id, mark)).filter(fn(issue) => issue.fold(fn(row) => true, fn(unit) => false))
            .map(fn(issue) => issue.fold(fn(row) => row, fn(unit) => json.null()))
    };
    if length(misses) != 0 { return Err(misses); }
    let report = Target { frame: scope.frame, layer: scope.layer, cel: id, pixels: marks.map(fn(mark) => mark.at) };
    let cache = paint.CachedView { scope: frame.Scope { frame: scope.frame, layer: "" },
        view: frame.PaintView { pixels: viewed.view.pixels, captured: frame.no_capture() } };
    let diff: Option<preview.Pair> = if reuse_composites && length(art.frames) == 1 {
        Some(preview.pair(scope.frame, next.grid, old.raster, viewed))
    } else { None };
    return Ok(Edit { document: page.source, artwork: next, target: report, cache: cache, diff: diff });
}

fn apply(source: json.Json, art: frame.Artwork, id: String, frame_id: String, cel: Option<String>,
    edits: json.Json, reuse_composites: Bool) -> Result<Edit, List<json.Json>> {
    let old = observed(source, art, frame_id)?;
    let scope = selected_layer(art, id, frame_id, cel)?;
    let creating = cel.fold(fn(name) => false, fn(unit) => true);
    let scan = Scan { grid: art.grid, ids: art.ids, visible: old.raster, layer: if creating { "" } else { scope.layer } };
    let marks = read_marks(scan, edits)?;
    let prepared = if creating { add_layer(art, source, id) } else { Ok(preview.Page { source: json.null(), art: art }) };
    let page = prepared?;
    return finalize(art, page, scope, marks, old, creating, reuse_composites);
}
