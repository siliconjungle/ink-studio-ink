module StudioPixelHistory;

import "std:json" as json;
import "pixel_brush.ink" as brush;
import "pixel_brush_capture.ink" as labels;
import "pixel_labels.ink" as names;
import "pixel_frame.ink" as frame;
import "pixel_selection.ink" as selection;
import "pixel_values.ink" as value;

record Cursor { revision: String, legacy: String, receipt: u32, }
record Edition { authored: json.Json, art: frame.Artwork, named: selection.Named,
    positions: List<List<u32>>, cursor: Cursor, }
record Entry { id: u32, label: String, receipt: u32, }
record View { cursor: Cursor, pending: Bool, undo: List<String>, redo: List<String>, roots: List<u32>, }
record Route { id: String, kind: String, }
record Command { destination: String, kind: String, frame: String, cel: Option<String>, conflict: json.Json, }
record Location { cel: String, frame: String, layer: String, }
record SharedDrawing { source: Location, holds: List<Location>, }
record UnlinkedDrawing { instance: Location, source: Location, }
record Links { sharedDrawings: List<SharedDrawing>, unlinked: List<UnlinkedDrawing>, }

fn empty_cursor() -> Cursor { return Cursor { revision: "", legacy: "", receipt: 0 }; }
fn entry_count(rows: List<Entry>) -> u32 { return length(rows); }
fn last(rows: List<Entry>) -> Entry { return rows.at_or(length(rows) - 1, empty_entry()); }
fn kept(rows: List<Entry>, first: u32) -> List<Entry> { return rows.drop(first); }
fn prefix(rows: List<Entry>, count: u32) -> List<Entry> { return rows.take(count); }
fn retired(rows: List<Entry>, limit: u32, future: List<Entry>) -> List<u32> {
    return rows.take(limit).concat(future).map(fn(row) => row.id);
}
fn empty_entry() -> Entry { return Entry { id: 0, label: "", receipt: 0 }; }

fn view(current: Cursor, draft: Entry, past: List<Entry>, future: List<Entry>) -> View {
    let reachable = past.concat(future);
    return View { cursor: current, pending: draft.id != 0, undo: past.map(fn(entry) => entry.label),
        redo: future.map(fn(entry) => entry.label),
        roots: [current.receipt, draft.receipt].concat(reachable.map(fn(entry) => entry.receipt)) };
}

fn member(key: String, raw: json.Json) -> json.Member { return json.Member { key: key, value: raw }; }

fn problem(code: String, message: String, details: List<json.Member>) -> json.Json {
    return json.object([member("code", json.text(code)), member("message", json.text(message))].concat(details));
}

fn invalid(command: Command, issue: json.Json) -> Command { return Command { ..command, conflict: issue }; }

fn requested_destination(spec: List<json.Member>) -> json.Json {
    return json.lookup(spec, "destination").fold(fn(raw) => raw, fn(unit) => json.text("raster"));
}

fn builtin(name: String) -> String {
    if name == "raster" || name == "guides" || name == "selections" { return name; }
    let kinds = ["canvas", "palette", "adjustments", "layers", "protection", "art-rules", "timeline"];
    return foldl(kinds, "", fn(kind) => fn(found) =>
        if name == kind || name == string_concat("document:", kind) { kind } else { found });
}

fn destination(source: json.Json, raw: json.Json) -> Route {
    let name = value.text(raw);
    let kind = builtin(name);
    let rows = value.items(value.get(value.fields(source), "destinations"));
    return foldl(rows, Route { id: kind, kind: kind }, fn(row) => fn(old) => route_row(row, name, old));
}

fn route_row(raw: json.Json, name: String, old: Route) -> Route {
    let fields = value.fields(raw);
    if name == "" || value.text(value.get(fields, "id")) != name { return old; }
    return Route { id: name, kind: value.text(value.get(fields, "kind")) };
}

fn requested_scope(raw: Option<json.Json>) -> Option<String> {
    return raw.fold(fn(item) => Some(labels.label(item)), fn(unit) => None);
}

fn resolve(source: json.Json, art: frame.Artwork, current: Cursor, raw: json.Json) -> Command {
    let spec = value.fields(raw);
    let route = destination(source, requested_destination(spec));
    let base = Command { destination: route.id, kind: route.kind, frame: "", cel: None, conflict: json.null() };
    if route.id == "" {
        let name = requested_destination(spec);
        return invalid(base, problem("unknown-destination", string_concat("Unknown pixel edit destination ", labels.label(name)),
            [member("destination", name)]));
    }
    let supplied = value.get(spec, "revision");
    let legacy = current.legacy != "" && supplied == json.text(current.legacy);
    let cel = json.lookup(spec, "cel");
    let target_frame = json.lookup(spec, "frame");
    let migrated: Option<json.Json> = if legacy && !value.has(spec, "cel") && !value.has(spec, "frame") {
        Some(json.text("artwork"))
    } else { target_frame };
    let scope = frame.resolve(art, requested_scope(migrated), None, requested_scope(cel));
    return scope.fold(fn(found) => check_command(Command { ..base, frame: found.frame, cel: requested_scope(cel) },
        current, spec, migrated, legacy), fn(issue) => invalid(base, problem("invalid-edit", issue, [])));
}

fn expected(raw: Option<json.Json>, actual: String) -> List<json.Member> {
    let prior: List<json.Member> = raw.fold(fn(data) => [member("expected", data)], fn(unit) => []);
    return prior.concat([member("actual", json.text(actual))]);
}

fn check_command(command: Command, current: Cursor, spec: List<json.Member>,
    wanted: Option<json.Json>, legacy: Bool) -> Command {
    let revision = json.lookup(spec, "revision");
    let edit_id = value.text(value.get(spec, "id"));
    let complaint = "Pixel edit needs the observed revision and a valid edit ID";
    if !brush.stable_id(edit_id) { return invalid(command, problem("invalid-edit", complaint, [])); }
    if !legacy && value.get(spec, "revision") != json.text(current.revision) {
        return invalid(command, problem("stale-document", complaint, expected(revision, current.revision)));
    }
    if command.kind != "raster" && command.kind != "selections" {
        return invalid(command, problem("unsupported-destination",
            string_concat("Pixel editor has not implemented destination ", command.destination), [member("destination", json.text(command.destination))]));
    }
    if value.has(spec, "ownership") {
        return invalid(command, problem("hybrid-owner-needs-source", "A hybrid edit needs a bound source destination", []));
    }
    if !value.has(spec, "cel") && wanted.fold(fn(item) => item != json.text(command.frame), fn(unit) => true) {
        return invalid(command, problem("wrong-frame", "Pixel edit needs the observed frame ID", expected(wanted, command.frame)));
    }
    if value.has(spec, "sourceRevision") {
        return invalid(command, problem("invalid-source-revision", "An inspected sourceRevision must be a SHA-256 digest for a scene destination", []));
    }
    if command.kind == "selections" && (value.has(spec, "edits") || value.has(spec, "cel")) {
        return invalid(command, problem("invalid-edit", "A selection edit needs a stable selection ID and a query", []));
    }
    if command.kind == "raster" && !value.has(spec, "operation") {
        return invalid(command, problem("unsupported-edit", "Use a raster operation for this pixel edit", []));
    }
    return check_raster_payload(command, spec);
}

fn check_raster_payload(command: Command, spec: List<json.Member>) -> Command {
    if command.kind != "raster" || !value.has(spec, "edits") { return command; }
    let tool = value.text(value.get(value.fields(value.get(spec, "operation")), "tool"));
    let message = if tool == "transform" || tool == "paste" { "A transform needs a named selection or an indexed clipboard to paste" }
        else { "A raster tool needs a layer or cel and a pencil, eraser, fill, shape or brush operation" };
    return invalid(command, problem("invalid-edit", message, []));
}

fn holds(cels: List<frame.Cel>) -> Bool {
    return repeat_until(length(cels), false, fn(found) => found, fn(i) => fn(found) =>
        value.has(cels.at_or(i, frame.no_cel()).fields, "hold"));
}

fn affected_cels(art: frame.Artwork) -> List<frame.Cel> {
    return if holds(art.cels) { art.cels } else { [] };
}

fn location(cel: frame.Cel) -> Location { return Location { cel: cel.id, frame: cel.frame, layer: cel.layer }; }

fn root(cels: List<frame.Cel>, cel: frame.Cel) -> String {
    return frame.resolved_cel(cels, cel).id;
}

fn drawing_changed(old: frame.Cel, next: frame.Cel) -> Bool {
    return old.id != "" && (old.runs != next.runs || value.get(old.fields, "slots") != value.get(next.fields, "slots") ||
        value.get(old.fields, "marks") != value.get(next.fields, "marks"));
}

fn links(before: List<frame.Cel>, after: List<frame.Cel>) -> Option<Links> {
    if length(before) == 0 { return None; }
    let growing = after.filter(fn(cel) => value.has(cel.fields, "hold"));
    let shared = shared_links(before, after, growing);
    let removed = before.filter(fn(cel) => detached(after, cel));
    let unlinked = removed.map(fn(cel) => UnlinkedDrawing { instance: location(cel),
        source: location(frame.resolved_cel(before, cel)) });
    return if length(shared) == 0 && length(unlinked) == 0 { None }
        else { Some(Links { sharedDrawings: shared, unlinked: unlinked }) };
}

fn detached(after: List<frame.Cel>, cel: frame.Cel) -> Bool {
    if !value.has(cel.fields, "hold") { return false; }
    let next = frame.find_cel(after, cel.id);
    return next.id != "" && !value.has(next.fields, "hold");
}

record LinkBuild { seen: Map<u64, List<String>>, rows: Buffer<SharedDrawing>, }

fn shared_links(before: List<frame.Cel>, after: List<frame.Cel>, held: List<frame.Cel>) -> List<SharedDrawing> {
    let init = LinkBuild { seen: Map.empty(), rows: Buffer.empty() };
    let rows = foldl(held, init, fn(cel) => fn(old) => append_link(before, after, held, cel, old));
    return rows.rows.freeze();
}

fn append_link(before: List<frame.Cel>, after: List<frame.Cel>, held: List<frame.Cel>,
    cel: frame.Cel, old: LinkBuild) -> LinkBuild {
    let source = frame.resolved_cel(after, cel);
    let key = names.id_hash(source.id);
    let bucket = old.seen.get_or(key, []);
    if selection.named_slot(bucket, source.id) != 4294967295 { return old; }
    let seen = old.seen.set(key, bucket.concat([source.id]));
    let prior = frame.resolved_cel(before, frame.find_cel(before, source.id));
    if !drawing_changed(prior, source) { return LinkBuild { ..old, seen: seen }; }
    let linked = held.filter(fn(other) => root(after, other) == source.id).map(fn(other) => location(other));
    return LinkBuild { seen: seen, rows: old.rows.push(SharedDrawing { source: location(source), holds: linked }) };
}
