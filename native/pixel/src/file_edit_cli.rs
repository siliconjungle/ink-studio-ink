use super::cli_flags::{read_preview_options, reference, split_arguments};
use super::file_output::{output, resolved};
use ink_studio_pixel::{PixelEditError, PixelFileEditor};
use serde_json::{Map, Value};
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
        let (paths, options) = split_arguments(args, USAGE)?;
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
