use ink_studio_pixel::{PixelCommandEditor, PixelEditor, extract_png_palette};
use serde::Deserialize;
use serde_json::{Map, Value, json, value::RawValue};
use std::{
    ffi::{OsStr, OsString},
    fs,
    path::{Path, PathBuf},
};

const USAGE: &str = "Use pixel-art palette export <document.json>, extract <image.png|document.json>, or import <document.json> <palette.json> with --out";

fn as_text(value: &OsStr) -> Result<&str, String> {
    value.to_str().ok_or_else(|| USAGE.into())
}

fn resolved(path: &Path) -> Result<PathBuf, String> {
    if let Ok(existing) = fs::canonicalize(path) {
        return Ok(existing);
    }
    let absolute = std::path::absolute(path).map_err(|error| error.to_string())?;
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        if component == std::path::Component::ParentDir {
            normalized.pop();
        } else {
            normalized.push(component.as_os_str());
        }
    }
    Ok(normalized)
}

fn output(path: &Path, data: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let staged = super::session_cli::stage(parent, data)?;
    let renamed = fs::rename(&staged, path).map_err(|error| error.to_string());
    if renamed.is_err() {
        let _ = fs::remove_file(staged);
    }
    renamed
}

fn imported(document: &str, palette: &str) -> Result<(String, Value), String> {
    #[derive(Deserialize)]
    struct Version {
        version: u32,
    }
    if serde_json::from_str::<Version>(document)
        .map_err(|error| error.to_string())?
        .version
        == 1
    {
        return Err("Upgrade the document to version 2 before editing the palette".into());
    }
    let mut editor = PixelCommandEditor::new(document, 0)?;
    let incoming = RawValue::from_string(palette.to_owned()).map_err(|error| error.to_string())?;
    let command = json!({ "format": "ink-studio/pixel-command", "version": 1, "action": "apply",
        "patch": { "id": "import-palette", "revision": editor.revision()?, "destination": "document:palette",
            "operation": { "type": "import", "palette": incoming } } });
    let receipt = editor
        .execute(&command.to_string())
        .map_err(|error| error.to_string())?;
    let mut receipt: Value = serde_json::from_str(&receipt).map_err(|error| error.to_string())?;
    receipt["command"]["runner"] = json!("cli");
    Ok((editor.snapshot()?, receipt))
}

pub fn run(mut args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let action = args.next().ok_or(USAGE)?;
    let source = PathBuf::from(args.next().ok_or(USAGE)?);
    let input = if action == "import" {
        Some(PathBuf::from(args.next().ok_or(USAGE)?))
    } else {
        None
    };
    let mut target = None;
    let mut options = Map::new();
    while let Some(flag) = args.next() {
        let text = as_text(&flag)?;
        let (key, inline) = text
            .split_once('=')
            .map_or((text, None), |(key, input)| (key, Some(input)));
        let supplied = match inline {
            Some(input) => OsString::from(input),
            None => args.next().ok_or(USAGE)?,
        };
        match (key, action.to_str()) {
            ("--out", _) if !as_text(&supplied)?.trim().is_empty() => {
                target = Some(PathBuf::from(supplied))
            }
            ("--frame" | "--layer" | "--alpha", Some("extract")) => {
                options.insert(key[2..].into(), json!(as_text(&supplied)?));
            }
            ("--size", Some("extract")) => {
                let text = as_text(&supplied)?.trim();
                let size = text
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64);
                options.insert("size".into(), size.map_or(Value::Null, Value::Number));
            }
            _ => return Err(USAGE.into()),
        }
    }
    let target = target.ok_or(USAGE)?;
    let final_path = resolved(&target)?;
    if resolved(&source)? == final_path
        || input
            .as_ref()
            .map(|path| resolved(path))
            .transpose()?
            .is_some_and(|path| path == final_path)
    {
        return Err("Write the palette result separately from its inputs".into());
    }
    let text = |path: &Path| fs::read_to_string(path).map_err(|error| error.to_string());
    match action.to_str() {
        Some("export") => output(&target, &PixelEditor::new(&text(&source)?)?.palette()?),
        Some("extract") => {
            let options = Value::Object(options).to_string();
            let asset = if source
                .extension()
                .and_then(OsStr::to_str)
                .is_some_and(|ext| ext.eq_ignore_ascii_case("json"))
            {
                PixelEditor::new(&text(&source)?)?.extract_palette(&options)?
            } else {
                extract_png_palette(
                    &fs::read(&source).map_err(|error| error.to_string())?,
                    &options,
                )?
            };
            output(&target, &asset)
        }
        Some("import") => {
            let (document, receipt) =
                imported(&text(&source)?, &text(input.as_ref().ok_or(USAGE)?)?)?;
            output(&target, &document)?;
            println!("{receipt}");
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}
