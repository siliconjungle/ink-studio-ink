use super::{
    cli_flags::{cli_number, read_preview_options, reference, shot_frame},
    file_output::{absolute_normalized, output, output_bytes, resolved},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use ink_abi::{json_value::{Json, parse as parse_authored_json}, value_wire::Limits};
use ink_studio_pixel::{CapturedBrush, PixelCommandEditor, PixelEditError, PixelPreviewOptions};
use serde::{
    Deserialize, Serialize, Serializer,
    ser::{Error as _, SerializeMap, SerializeSeq, SerializeStruct},
};
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
    decimal_tuple(raw, 2, message)
}

fn decimal_tuple(raw: &Value, size: usize, message: &str) -> Result<Value, String> {
    let parts: Vec<_> = raw
        .as_str()
        .ok_or(message)?
        .split(',')
        .map(str::trim)
        .collect();
    if parts.len() != size || parts.contains(&"") {
        return Err(message.into());
    }
    Ok(Value::Array(
        parts
            .into_iter()
            .map(|part| json!(cli_number(part)))
            .collect(),
    ))
}

#[derive(Serialize)]
struct BrushDynamics {
    #[serde(skip_serializing_if = "Option::is_none")]
    stabilization: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pressure: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    velocity: Option<BrushVelocity>,
}

#[derive(Serialize)]
struct BrushVelocity {
    speed: Value,
    size: [Value; 2],
}

#[derive(Serialize)]
struct BrushTint {
    mode: &'static str,
    id: String,
    color: String,
}

#[derive(Serialize)]
struct BrushOptions {
    #[serde(flatten)]
    scope: Map<String, Value>,
    settings: BrushSettings,
}

#[derive(Serialize)]
struct BrushSettings {
    #[serde(skip_serializing_if = "Option::is_none")]
    angle: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    swatch: Option<BrushTint>,
    #[serde(skip_serializing_if = "Option::is_none")]
    dynamics: Option<BrushDynamics>,
}

fn brush_options(
    editor: &mut PixelCommandEditor,
    input: &Map<String, Value>,
) -> Result<BrushOptions, String> {
    let tuple = |flag, size| {
        input
            .get(flag)
            .map(|raw| decimal_tuple(raw, size, &format!("Use --{flag} with {size} numbers")))
            .transpose()
    };
    let number = |flag| {
        input
            .get(flag)
            .map(|raw| json!(reference(raw).and_then(cli_number)))
    };
    let angle = number("angle");
    let size = tuple("size", 2)?;
    let stabilization = number("stabilization");
    let velocity = tuple("velocity", 3)?.map(|values| BrushVelocity {
        speed: values[0].clone(),
        size: [values[1].clone(), values[2].clone()],
    });
    let pressure = tuple("pressure", 2)?;
    let dynamics = (stabilization.is_some() || pressure.is_some() || velocity.is_some()).then_some(
        BrushDynamics {
            stabilization,
            pressure,
            velocity,
        },
    );
    let swatch = input
        .get("tint")
        .map(|raw| {
            let message = "Choose a known swatch for --tint";
            let id = reference(raw).ok_or(message)?;
            let palette: Value =
                serde_json::from_str(&editor.palette()?).map_err(|error| error.to_string())?;
            let color = palette["swatches"]
                .as_array()
                .and_then(|swatches| swatches.iter().find(|row| row["id"] == id))
                .and_then(|row| row["color"].as_str())
                .ok_or(message)?;
            Ok::<_, String>(BrushTint {
                mode: "tint",
                id: id.into(),
                color: color.into(),
            })
        })
        .transpose()?;
    let mut scope = selected(
        input,
        &[
            ("selection", "selection"),
            ("frame", "frame"),
            ("layer", "layer"),
            ("cel", "cel"),
        ],
    );
    for (flag, size) in [("rect", 4), ("anchor", 2)] {
        if let Some(value) = tuple(flag, size)? {
            scope.insert(flag.into(), value);
        }
    }
    Ok(BrushOptions {
        scope,
        settings: BrushSettings {
            angle,
            size,
            swatch,
            dynamics,
        },
    })
}

// The brush settings travel as authored JSON to preserve their order and
// numeric spelling. Expand that JSON when writing the indented asset.
struct Authored<'a>(&'a Json);

impl Serialize for Authored<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Json::Null => serializer.serialize_unit(),
            Json::Boolean(value) => serializer.serialize_bool(*value),
            Json::Number(token) => RawValue::from_string(token.clone())
                .map_err(S::Error::custom)?
                .serialize(serializer),
            Json::Text(text) => serializer.serialize_str(text),
            Json::Array(items) => {
                let mut values = serializer.serialize_seq(Some(items.len()))?;
                for value in items {
                    values.serialize_element(&Authored(value))?;
                }
                values.end()
            }
            Json::Object(fields) => {
                let mut object = serializer.serialize_map(Some(fields.len()))?;
                for (key, value) in fields {
                    object.serialize_entry(key, &Authored(value))?;
                }
                object.end()
            }
        }
    }
}

struct BrushFile<'a>(&'a CapturedBrush, Authored<'a>);

impl Serialize for BrushFile<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let brush = self.0;
        let mut fields = serializer.serialize_struct("BrushFile", 8)?;
        fields.serialize_field("format", brush.format)?;
        fields.serialize_field("version", &brush.version)?;
        fields.serialize_field("width", &brush.width)?;
        fields.serialize_field("height", &brush.height)?;
        fields.serialize_field("anchor", &brush.anchor)?;
        fields.serialize_field("palette", &brush.palette)?;
        fields.serialize_field("slots", &brush.slots)?;
        fields.serialize_field("settings", &self.1)?;
        fields.end()
    }
}

pub(crate) fn brush(
    directory: &Path,
    editor: &mut PixelCommandEditor,
    input: &Map<String, Value>,
) -> Result<String, String> {
    require_local("brush", input)?;
    const MISSING: &str = "Use --out to save the brush JSON";
    const SEPARATE: &str = "Write the brush to a separate output";
    if input.get("out").and_then(reference).is_none() {
        return Err(MISSING.into());
    }
    let file = target(directory, None, input)
        .map_err(|error| {
            if error == "Choose an output outside the session checkpoints" {
                SEPARATE.into()
            } else {
                error
            }
        })?
        .ok_or(MISSING)?;
    if resolved(&file)? == resolved(directory)? {
        return Err(SEPARATE.into());
    }
    let options =
        serde_json::to_string(&brush_options(editor, input)?).map_err(|error| error.to_string())?;
    let brush = editor.capture_brush(&options)?;
    let settings = parse_authored_json(brush.settings.get(), Limits::default())?;
    let asset = serde_json::to_string_pretty(&BrushFile(&brush, Authored(&settings)))
        .map_err(|error| error.to_string())?;
    output(&file, &asset)?;
    Ok(json!({ "file": file, "format": brush.format, "size": [brush.width, brush.height], "anchor": brush.anchor }).to_string())
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
