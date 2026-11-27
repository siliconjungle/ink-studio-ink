use super::{
    cli_flags::{cli_number, reference, split_arguments},
    file_output::{output, output_bytes, resolved},
};
use ink_studio_pixel::PixelCommandEditor;
use serde_json::json;
use std::{ffi::OsString, fs, path::Path};

const USAGE: &str = "Use pixel-art tilemap inspect <document>, draw <document> --out map.png or neighbors <document> --at x,y";

pub(crate) fn run(args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let (paths, options) = split_arguments(args, USAGE)?;
    let [command, source] = paths.as_slice() else { return Err(USAGE.into()); };
    let action = command.to_str().ok_or(USAGE)?;
    let allowed: &[&str] = match action {
        "inspect" => &["out", "at"],
        "draw" => &["out", "t"],
        "neighbors" => &["out", "at", "t", "image"],
        _ => return Err(USAGE.into()),
    };
    if options.iter().any(|(key, value)| !allowed.contains(&key.as_str()) || reference(value).is_none()) {
        return Err(USAGE.into());
    }
    let option = |name| options.get(name).and_then(reference);
    let out = option("out").map(Path::new);
    let image = option("image").map(Path::new);
    let at = option("at");
    if (action == "draw" && !out.is_some_and(is_png))
        || (action == "neighbors" && (at.is_none() || image.is_some_and(|name| !is_png(name)))) {
        return Err(USAGE.into());
    }
    let targets: Vec<_> = out.into_iter().chain(image).map(resolved).collect::<Result<_, _>>()?;
    if targets.contains(&resolved(source)?) || (targets.len() == 2 && targets[0] == targets[1]) {
        return Err(USAGE.into());
    }
    let text = fs::read_to_string(source).map_err(|error| error.to_string())?;
    let mut editor = PixelCommandEditor::new(&text, 0)?;
    let point = at.map(coordinate).transpose()?;
    let time = option("t").map_or(0.0, |value| cli_number(value).unwrap_or(f64::NAN));
    if action == "draw" {
        let png = editor.tilemap_png(time).map_err(|error| error.to_string())?;
        return output_bytes(out.ok_or(USAGE)?, &png);
    }
    if action == "neighbors" {
        let (report, bytes) = editor.tilemap_neighbors(point.as_deref().ok_or(USAGE)?, time, image.is_some())
            .map_err(|error| error.to_string())?;
        if let (Some(path), Some(bytes)) = (image, bytes) {
            output_bytes(path, &bytes)?;
        }
        return print_report(out, &report);
    }
    let report = editor.tilemap(point.as_deref()).map_err(|error| error.to_string())?;
    print_report(out, &report)
}

fn coordinate(raw: &str) -> Result<String, String> {
    let diagnostic = "Use --at x,y inside the native grid";
    let (x, y) = raw.split_once(',').ok_or(diagnostic)?;
    if [x, y].iter().any(|s| s.is_empty() || !s.bytes().all(|byte| byte.is_ascii_digit())) {
        return Err(diagnostic.into());
    }
    Ok(json!([x.parse::<f64>().ok(), y.parse::<f64>().ok()]).to_string())
}

fn is_png(path: &Path) -> bool {
    path.extension().and_then(|ext| ext.to_str()).is_some_and(|ext| ext.eq_ignore_ascii_case("png"))
}

fn print_report(path: Option<&Path>, report: &str) -> Result<(), String> {
    if let Some(path) = path { return output(path, report); }
    println!("{report}");
    Ok(())
}
