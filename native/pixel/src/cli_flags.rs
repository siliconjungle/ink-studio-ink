use ink_studio_pixel::PixelPreviewOptions;
use serde_json::{Map, Value, json};
use std::{ffi::OsString, path::PathBuf};

pub(crate) fn split_arguments(
    args: impl Iterator<Item = OsString>,
    usage: &str,
) -> Result<(Vec<PathBuf>, Map<String, Value>), String> {
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
            let value = args.next().unwrap().into_string().map_err(|_| usage)?;
            Value::String(value)
        } else {
            Value::Bool(true)
        };
        options.insert(option.into(), parsed);
    }
    Ok((paths, options))
}

pub(crate) fn reference(value: &Value) -> Option<&str> {
    value.as_str().filter(|s| !s.trim().is_empty())
}

pub(crate) fn cli_number(text: &str) -> Option<f64> {
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

pub(crate) fn read_preview_options(
    options: &Map<String, Value>,
) -> Result<PixelPreviewOptions, String> {
    let mut preview = Map::new();
    if let Some(exact) = options.get("exact") {
        preview.insert("exact".into(), exact.clone());
    }
    if let Some(limit) = options.get("limit") {
        preview.insert("limit".into(), json!(limit.as_str().and_then(cli_number)));
    }
    if let Some(shot) = options.get("shot-hit-frame") {
        let frame = shot_frame(shot);
        preview.insert("shotHitFrame".into(), json!(frame));
    }
    PixelPreviewOptions::from_json(&Value::Object(preview).to_string()).map_err(|e| e.to_string())
}

pub(crate) fn shot_frame(shot: &Value) -> Option<f64> {
    shot.as_str()
        .filter(|s| !s.is_empty() && s.bytes().all(|n| n.is_ascii_digit()))
        .and_then(|s| s.parse::<f64>().ok())
}
