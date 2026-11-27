module StudioPixelBatch;

import "std:json" as json;
import "pixel_commands.ink" as commands;
import "pixel_history.ink" as history;
import "pixel_labels.ink" as labels;
import "pixel_values.ink" as value;

record Draft { label: String, receipt: u32, anchor: json.Json, }

fn revision(raw: json.Json) -> Bool {
    let text = value.text(raw);
    if string_byte_len(text) != 64 { return false; }
    return repeat_until(64, true, fn(valid) => !valid, fn(i) => fn(valid) =>
        digest_digit(labels.byte(text, i)));
}

fn digest_digit(byte: u32) -> Bool { return byte >= 48 && byte <= 57 || byte >= 97 && byte <= 102; }

fn count(length: u32) -> Result<Unit, String> {
    return if length >= 1 && length <= 256 { Ok(()) } else { Err("A pixel edit batch needs 1–256 ordered steps") };
}

fn plan(raw: json.Json, length: u32) -> Result<String, String> {
    let fields = value.fields(raw);
    let name = json.lookup(fields, "label").fold(fn(row) => value.text(row), fn(unit) => "Pixel edit batch");
    if !value.only(fields, ["revision", "label", "commands"]) || !revision(value.get(fields, "revision")) ||
        !commands.non_blank(name) {
        return Err("A pixel edit batch needs a base document revision and ordered commands");
    }
    let valid = count(length)?;
    return Ok(name);
}

fn anchor(cursor: history.Cursor) -> json.Json {
    // SHA-256 of the empty render-options JSON object for a local document.
    let render = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
    return json.object([
        history.member("documentRevision", json.text(cursor.revision)),
        history.member("legacyRevision", if cursor.legacy == "" { json.null() } else { json.text(cursor.legacy) }),
        history.member("renderRevision", json.text(render)),
        history.member("scene", json.null())
    ]);
}

fn valid_anchor(raw: json.Json) -> Bool {
    let fields = value.fields(raw);
    let legacy = value.get(fields, "legacyRevision");
    let scene = value.get(fields, "scene");
    let binding = value.fields(scene);
    return length(fields) == 4 && value.only(fields, ["documentRevision", "legacyRevision", "renderRevision", "scene"]) &&
        revision(value.get(fields, "documentRevision")) && (legacy == json.null() || revision(legacy)) &&
        revision(value.get(fields, "renderRevision")) && (scene == json.null() ||
            length(binding) == 2 && value.only(binding, ["ref", "revision"]) &&
            commands.non_blank(value.text(value.get(binding, "ref"))) && revision(value.get(binding, "revision")));
}

fn receipt(raw: json.Json) -> Result<Unit, String> {
    let fields = value.fields(raw);
    let valid = value.only(fields, ["format", "version", "label", "inputs", "outputs", "steps", "revision", "revalidatedFrom"]) &&
        value.text(value.get(fields, "format")) == "ink-studio/pixel-edit-batch" &&
        value.number(value.get(fields, "version")) == 1.0f64 &&
        commands.non_blank(value.text(value.get(fields, "label"))) && revision(value.get(fields, "revision")) &&
        valid_anchor(value.get(fields, "inputs")) && valid_anchor(value.get(fields, "outputs")) &&
        json.lookup(fields, "revalidatedFrom").fold(fn(row) => revision(row), fn(unit) => true);
    return if valid { Ok(()) } else { Err("Replay needs a version 1 pixel edit batch receipt") };
}

fn input_changes(expected: json.Json, actual: json.Json) -> List<json.Json> {
    let before = value.fields(expected);
    let after = value.fields(actual);
    let keys = ["documentRevision", "legacyRevision", "scene", "renderRevision"];
    let changed = keys.filter(fn(key) => value.get(before, key) != value.get(after, key));
    return changed.map(fn(key) => history.problem(if key == "scene" || key == "renderRevision" { "stale-source" } else { "stale-document" },
        string_concat("Pixel batch input differs from the recorded ", key),
        [history.member("input", json.text(key)), history.member("expected", value.get(before, key)),
            history.member("actual", value.get(after, key))]));
}

fn same_target(before: json.Json, after: json.Json) -> Bool {
    let left = value.fields(before);
    let right = value.fields(after);
    let keys = ["kind", "destination", "scene", "binding", "object", "part", "layer", "cel", "chart",
        "channel", "mesh", "material", "decal"];
    return length(left) != 0 && length(right) != 0 && foldl(keys, true, fn(key) => fn(same) =>
        same && json.lookup(left, key) == json.lookup(right, key));
}
