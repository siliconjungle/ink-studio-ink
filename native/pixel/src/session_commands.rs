use super::{
    cli_flags::{cli_number, read_preview_options, reference, shot_frame},
    file_output::{absolute_normalized, output, output_bytes, resolved},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use ink_studio_pixel::{PixelCommandEditor, PixelEditError, PixelPreviewOptions};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json, value::RawValue};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub(crate) const EDITS: &[&str] = &["apply", "draw", "mask", "recolor", "transform"];
const RUN_OPTIONS: &str = "Use pixel-art session run <directory> <command.json> [--scene scene.json | --source-view view.json] [--out result.json]";
const SOURCE: &str =
    "Pixel editor has not implemented attached scene sessions or captured scene views";

#[derive(Serialize)]
struct Command<'a> {
    format: &'static str,
    version: u8,
    action: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    patch: Option<&'a RawValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    query: Option<&'a RawValue>,
    #[serde(flatten)]
    fields: Map<String, Value>,
}

pub(crate) enum Request {
    Execute(String),
    Preview(PixelPreviewOptions),
    Copy(String),
    Sample { point: Value, settings: Map<String, Value> },
    Snap { point: Value, settings: Map<String, Value> },
    Timeline,
}

impl Request {
    pub(crate) fn invoke(self, editor: &mut PixelCommandEditor) -> Result<String, PixelEditError> {
        match self {
            Self::Execute(json) => editor.execute(&json),
            Self::Preview(options) => {
                let reply = editor.preview_changes(options)?;
                serde_json::to_string(&reply).map_err(|error| error.to_string().into())
            }
            Self::Copy(options) => {
                let reply = editor.copy_selection(&options)?;
                serde_json::to_string(&reply).map_err(|error| error.to_string().into())
            }
            Self::Sample { point, settings } => editor.sample(&point.to_string(), &Value::Object(settings).to_string()),
            Self::Snap { point, settings } => editor.snap(&point.to_string(), &Value::Object(settings).to_string()),
            Self::Timeline => editor.timeline(),
        }
    }
}

pub(crate) fn envelope(action: &str) -> Value {
    json!({ "format": "ink-studio/pixel-command", "version": 1, "action": action })
}

fn selected(options: &Map<String, Value>, keys: &[(&str, &str)]) -> Map<String, Value> {
    keys.iter()
        .filter_map(|&(flag, field)| {
            options
                .get(flag)
                .map(|value| (field.to_owned(), value.clone()))
        })
        .collect()
}

fn inspect_point(raw: Option<&Value>) -> Result<Value, String> {
    let message = "Use --at x,y inside the native grid";
    let text = raw.and_then(Value::as_str).ok_or(message)?;
    let (x, y) = text.split_once(',').ok_or(message)?;
    let values = [x, y].map(|n| {
        if n.is_empty() || !n.bytes().all(|c| c.is_ascii_digit()) {
            return Err(message);
        }
        Ok(json!(n.parse::<f64>().ok()))
    });
    let [x, y] = values;
    Ok(Value::Array(vec![x?, y?]))
}

fn inspect_destinations(options: &Map<String, Value>) -> Result<Option<Value>, String> {
    options
        .get("destination")
        .map(|raw| {
            let message = "Use --destination with comma-separated surface destination IDs";
            let names: Vec<_> = raw
                .as_str()
                .ok_or(message)?
                .split(',')
                .map(str::trim)
                .collect();
            if names.contains(&"") {
                return Err(message.into());
            }
            Ok(json!(names))
        })
        .transpose()
}

fn decimal_pair(raw: &Value, message: &str) -> Result<Value, String> {
    let parts: Vec<_> = raw.as_str().ok_or(message)?.split(',').map(str::trim).collect();
    if parts.len() != 2 || parts.contains(&"") {
        return Err(message.into());
    }
    Ok(Value::Array(parts.into_iter().map(|part| json!(cli_number(part))).collect()))
}

fn require_local(action: &str, options: &Map<String, Value>) -> Result<(), String> {
    let flags = ["scene", "source-view"];
    if action == "run"
        && (options
            .keys()
            .any(|key| !["scene", "source-view", "out"].contains(&key.as_str()))
            || flags.iter().any(|key| {
                options
                    .get(*key)
                    .is_some_and(|value| reference(value).is_none())
            }))
    {
        return Err(RUN_OPTIONS.into());
    }
    if action == "init"
        && options
            .get("scene")
            .is_some_and(|value| reference(value).is_none())
    {
        return Err("--scene needs an editable diorama path".into());
    }
    if (action == "select" || EDITS.contains(&action))
        && options
            .get("source-view")
            .is_some_and(|value| reference(value).is_none() || options.contains_key("scene"))
    {
        return Err("Use a single --scene or --source-view with this pixel command".into());
    }
    if flags.iter().any(|key| options.contains_key(*key)) && action != "export" {
        return Err(SOURCE.into());
    }
    Ok(())
}

pub(crate) fn initialize(options: &Map<String, Value>) -> Result<(), String> {
    require_local("init", options)
}

pub(crate) fn request(
    action: &str,
    input: Option<&Path>,
    options: &Map<String, Value>,
) -> Result<Request, String> {
    require_local(action, options)?;
    let input = input
        .map(fs::read_to_string)
        .transpose()
        .map_err(|error| error.to_string())?;
    if action == "run" {
        return Ok(Request::Execute(input.unwrap()));
    }
    if action == "preview" {
        return Ok(Request::Preview(read_preview_options(options)?));
    }
    let mut command = Command {
        format: "ink-studio/pixel-command",
        version: 1,
        action,
        patch: None,
        query: None,
        fields: Map::new(),
    };
    let scope = [("frame", "frame"), ("layer", "layer"), ("cel", "cel")];
    let mut settings = Map::new();
    if EDITS.contains(&action) {
        command.patch = Some(
            serde_json::from_str(input.as_deref().unwrap()).map_err(|error| error.to_string())?,
        );
        if let Some(shot) = options.get("shot-hit-frame") {
            // This option must also reach the ordinary command validator when malformed.
            settings.insert("shotHitFrame".into(), json!(shot_frame(shot)));
        }
    } else {
        match action {
            "begin" => command
                .fields
                .extend(selected(options, &[("label", "label")])),
            "inspect" => {
                let at = inspect_point(options.get("at"))?;
                command.fields.insert("at".into(), at);
                settings = selected(
                    options,
                    &[("frame", "frame"), ("cel", "cel"), ("binding", "binding")],
                );
                if let Some(destinations) = inspect_destinations(options)? {
                    settings.insert("destinations".into(), destinations);
                }
                settings.insert(
                    "references".into(),
                    json!(options.get("references") == Some(&Value::Bool(true))),
                );
            }
            "select" => {
                command.query = Some(
                    serde_json::from_str(input.as_deref().unwrap())
                        .map_err(|error| error.to_string())?,
                );
                settings = selected(options, &scope);
                settings.extend(selected(options, &[("target-revision", "targetRevision")]));
            }
            "copy" => {
                settings = selected(options, &scope);
                settings.extend(selected(options, &[("selection", "selection")]));
                return Ok(Request::Copy(Value::Object(settings).to_string()));
            }
            "sample" => {
                let point = options.get("at").map(|v| decimal_pair(v, "Use --at with two numbers"))
                    .transpose()?.unwrap_or(Value::Null);
                settings = selected(options, &scope);
                settings.extend(selected(options, &[("mode", "mode"), ("destination", "destination")]));
                if let Some(uv) = options.get("uv") {
                    settings.insert("uv".into(), decimal_pair(uv, "Use --uv with two numbers")?);
                }
                return Ok(Request::Sample { point, settings });
            }
            "snap" => {
                let message = "Use --at x,y for guide snapping";
                let point = decimal_pair(options.get("at").ok_or(message)?, message)?;
                settings = selected(options, &[("frame", "frame")]);
                if let Some(radius) = options.get("radius") {
                    settings.insert("radius".into(), json!(reference(radius).and_then(cli_number)));
                }
                return Ok(Request::Snap { point, settings });
            }
            "timeline" => return Ok(Request::Timeline),
            "export" => return Ok(Request::Execute(export_command(options)?)),
            _ => {}
        }
    }
    if !settings.is_empty() {
        command
            .fields
            .insert("options".into(), Value::Object(settings));
    }
    serde_json::to_string(&command)
        .map(Request::Execute)
        .map_err(|error| error.to_string())
}

fn export_command(options: &Map<String, Value>) -> Result<String, String> {
    let artifact = options
        .get("artifact")
        .cloned()
        .unwrap_or(json!("document"));
    let mut command = envelope("export");
    let mut settings = Map::new();
    if artifact == "preset" {
        if options.get("preset").and_then(reference).is_none() {
            return Err("Use --preset with a pixel export preset JSON file".into());
        }
        return Err("Pixel editor has not implemented command export preset".into());
    }
    if options.contains_key("preset") {
        return Err("Choose --artifact preset when using --preset".into());
    }
    if artifact == "png" || artifact == "stamp" {
        settings = selected(
            options,
            &[("frame", "frame"), ("cel", "cel"), ("layer", "layer")],
        );
        if artifact == "png" {
            settings.extend(selected(options, &[("color-mode", "colorMode")]));
        } else {
            settings.insert(
                "references".into(),
                json!(options.get("references") == Some(&Value::Bool(true))),
            );
        }
    }
    if matches!(
        artifact.as_str(),
        Some("shot-corrections" | "splat-fit" | "scan-paint")
    ) {
        settings.extend(selected(options, &[("scene", "scene")]));
    }
    command["artifact"] = artifact;
    if !settings.is_empty() {
        command["options"] = Value::Object(settings);
    }
    Ok(command.to_string())
}

pub(crate) fn target(
    directory: &Path,
    input: Option<&Path>,
    options: &Map<String, Value>,
) -> Result<Option<PathBuf>, String> {
    let Some(raw) = options.get("out") else {
        return Ok(None);
    };
    let out = absolute_normalized(Path::new(reference(raw).ok_or("--out needs a file path")?))?;
    let real = resolved(&out)?;
    if real.parent() == Some(resolved(directory)?.as_path())
        && real
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix("checkpoint-")?.strip_suffix(".json"))
            .is_some_and(|generation| {
                !generation.is_empty() && generation.bytes().all(|n| n.is_ascii_digit())
            })
    {
        return Err("Choose an output outside the session checkpoints".into());
    }
    let sources = [
        input,
        options.get("scene").and_then(reference).map(Path::new),
        options
            .get("source-view")
            .and_then(reference)
            .map(Path::new),
    ];
    for source in sources.into_iter().flatten() {
        if resolved(source)? == real {
            return Err("Write the pixel command output separately from its inputs".into());
        }
    }
    Ok(Some(out))
}

pub(crate) fn export(reply: &str, path: &Path) -> Result<String, String> {
    #[derive(Deserialize)]
    struct Asset<'a> {
        artifact: &'a str,
        encoding: Option<&'a str>,
        data: &'a RawValue,
    }
    let asset: Asset = serde_json::from_str(reply).map_err(|error| error.to_string())?;
    if asset.encoding == Some("base64") {
        let encoded: &str =
            serde_json::from_str(asset.data.get()).map_err(|error| error.to_string())?;
        output_bytes(
            path,
            &STANDARD
                .decode(encoded)
                .map_err(|error| error.to_string())?,
        )?;
    } else {
        output(path, asset.data.get())?;
    }
    Ok(json!({ "artifact": asset.artifact, "file": path }).to_string())
}
