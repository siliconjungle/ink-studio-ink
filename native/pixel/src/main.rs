use ink_studio_pixel::{open_pixel_document, select_pixels};
use serde::Deserialize;
use serde_json::value::RawValue;

#[derive(Deserialize)]
struct SelectionRequest<'a> {
    width: u32,
    height: u32,
    query: &'a RawValue,
    #[serde(default)]
    rgba: Vec<u32>,
    #[serde(default, borrow)]
    saved: Option<&'a RawValue>,
}

fn select(path: std::ffi::OsString) -> Result<(), String> {
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: SelectionRequest =
        serde_json::from_str(&source).map_err(|error| error.to_string())?;
    let pixels = select_pixels(
        request.width,
        request.height,
        request.query.get(),
        request.rgba,
        request.saved.map_or("{}", RawValue::get),
    )?;
    println!(
        "{}",
        serde_json::to_string(&pixels).map_err(|error| error.to_string())?
    );
    Ok(())
}

fn run() -> Result<(), String> {
    let mut args = std::env::args_os().skip(1);
    let usage = "Usage: ink-studio-pixel DOCUMENT | ink-studio-pixel select REQUEST";
    let path = args.next().ok_or(usage)?;
    if let Some(request) = args.next() {
        if path != "select" || args.next().is_some() {
            return Err(usage.into());
        }
        return select(request);
    }
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let opened = open_pixel_document(&source)?;
    let document = opened.document_json;
    let legacy =
        serde_json::to_string(&opened.legacy_revision).map_err(|error| error.to_string())?;
    println!(
        r#"{{"document":{document},"revision":"{}","legacyRevision":{legacy}}}"#,
        opened.revision
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
