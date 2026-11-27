use super::file_output::{output, resolved};
use ink_studio_pixel::{PixelEditError, PixelFileEditor, PixelPreviewOptions};
use serde_json::{Map, Value, json};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

const USAGE: &str = "Use edit or replay DOCUMENT INPUT --out RESULT, or preview DOCUMENT PATCH [--exact] [--limit COUNT]";

struct Arguments {
    source: PathBuf,
    input: PathBuf,
    options: Map<String, Value>,
}

impl Arguments {
    fn read(args: impl Iterator<Item = OsString>) -> Result<Self, String> {
        let mut args = args.peekable();
        let mut paths = Vec::new();
        let mut options = Map::new();
        while let Some(argument) = args.next() {
            let Some(option) = argument.to_str().and_then(|s| s.strip_prefix("--")) else {
                paths.push(PathBuf::from(argument));
                continue;
            };
            let has_value = args
                .peek()
                .is_some_and(|next| !next.to_string_lossy().starts_with("--"));
            let parsed = if has_value {
                let value = args.next().unwrap().into_string().map_err(|_| USAGE)?;
                Value::String(value)
            } else {
                Value::Bool(true)
            };
            options.insert(option.into(), parsed);
        }
        let [source, input] = paths.try_into().map_err(|_| USAGE)?;
        if options.contains_key("binding") {
            return Err("Use --binding id with pixel-art inspect or canvas".into());
        }
        if let Some(view) = options.get("source-view") {
            if reference(view).is_none() || options.contains_key("scene") {
                return Err("Use --source-view with inspect, canvas, select, edit, preview, or replay, or with --scene and --query for splat targets".into());
            }
        }
        Ok(Self {
            source,
            input,
            options,
        })
    }

    fn check_output(
        &self,
        path: &Path,
        inputs: impl IntoIterator<Item = &'static str>,
        message: &str,
    ) -> Result<(), String> {
        let out = resolved(path)?;
        for input in inputs {
            let path = match input {
                "document" => Some(self.source.as_path()),
                "input" => Some(self.input.as_path()),
                option => self.options.get(option).and_then(reference).map(Path::new),
            };
            if let Some(path) = path {
                if resolved(path)? == out {
                    return Err(message.into());
                }
            }
        }
        Ok(())
    }
}

fn reference(value: &Value) -> Option<&str> {
    value.as_str().filter(|s| !s.trim().is_empty())
}

fn preview_limit(text: &str) -> Option<f64> {
    let text = text.trim();
    if text.is_empty() {
        return Some(0.0);
    }
    for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
        if text
            .get(..2)
            .is_some_and(|first| first.eq_ignore_ascii_case(prefix))
        {
            return u64::from_str_radix(&text[2..], radix)
                .ok()
                .map(|n| n as f64);
        }
    }
    text.parse().ok()
}

fn read_preview_options(options: &Map<String, Value>) -> Result<PixelPreviewOptions, String> {
    let mut preview = Map::new();
    if let Some(exact) = options.get("exact") {
        preview.insert("exact".into(), exact.clone());
    }
    if let Some(limit) = options.get("limit") {
        preview.insert(
            "limit".into(),
            json!(limit.as_str().and_then(preview_limit)),
        );
    }
    if let Some(shot) = options.get("shot-hit-frame") {
        let frame = shot
            .as_str()
            .filter(|s| !s.is_empty() && s.bytes().all(|n| n.is_ascii_digit()))
            .and_then(|s| s.parse::<f64>().ok());
        preview.insert("shotHitFrame".into(), json!(frame));
    }
    PixelPreviewOptions::from_json(&Value::Object(preview).to_string()).map_err(|e| e.to_string())
}

fn json_text(value: &Value) -> Result<String, String> {
    serde_json::to_string_pretty(value).map_err(|e| e.to_string())
}

fn rejection(error: PixelEditError) -> String {
    if let Some(receipt) = &error.receipt {
        println!("{}", json_text(receipt).expect("pixel receipt is JSON"));
    }
    error.to_string()
}

pub fn run(action: &str, args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let mut args = Arguments::read(args)?;
    let source = fs::read_to_string(&args.source).map_err(|error| error.to_string())?;
    let patch = fs::read_to_string(&args.input).map_err(|error| error.to_string())?;
    let mut editor = PixelFileEditor::new(&source)?;
    if action == "preview" {
        let options = read_preview_options(&args.options)?;
        let report = editor
            .preview(&patch, options, args.options.get("frame"))
            .map_err(rejection)?;
        let serialized = json_text(&report)?;
        if let Some(path) = args.options.get("out").filter(|_| options.exact) {
            let path =
                reference(path).ok_or("Write the preview report to a separate output path")?;
            let target = Path::new(path);
            args.check_output(
                target,
                ["document", "input", "scene", "source-view"],
                "Write the preview report to a separate output path",
            )?;
            output(target, &serialized)?;
        } else {
            println!("{serialized}");
        }
        if report["valid"] == false {
            std::process::exit(2);
        }
        return Ok(());
    }

    let target = args
        .options
        .remove("out")
        .as_ref()
        .and_then(reference)
        .map(PathBuf::from)
        .ok_or("Use --out revised.json to save the edit")?;
    args.check_output(
        &target,
        ["source-view"],
        "Write the edit to a separate output from the captured view",
    )?;
    if action == "replay" {
        args.check_output(
            &target,
            ["document", "input"],
            "Write the replay to a separate output from its inputs",
        )?;
    }
    let edited = if action == "replay" {
        editor.replay(&patch, &args.options)
    } else {
        editor.edit(&patch, &args.options)
    }
    .map_err(rejection)?;
    output(&target, &edited.document)?;
    println!("{}", json_text(&edited.receipt)?);
    Ok(())
}
