mod cli_flags;
mod file_edit_cli;
mod file_output;
mod journal_cli;
mod palette_cli;
mod session_cli;
mod session_commands;

use ink_studio_pixel::{
    IndexedSelectionRaster, OpenedDocument, PixelEditor, mask_pixels, open_pixel_document,
    open_pixel_png, rasterize_pixel_frame, select_pixel_mask_with_raster,
};
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
    #[serde(default)]
    large: bool,
    indexed: Option<IndexedSelectionRaster>,
}

#[derive(Deserialize)]
struct FrameRequest<'a> {
    document: &'a RawValue,
    frame: Option<String>,
    layer: Option<String>,
    cel: Option<String>,
    #[serde(borrow)]
    query: Option<&'a RawValue>,
    #[serde(borrow)]
    saved: Option<&'a RawValue>,
}

fn frame(path: std::ffi::OsString, select: bool) -> Result<(), String> {
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: FrameRequest = serde_json::from_str(&source).map_err(|error| error.to_string())?;
    let output = if select {
        let query = request.query.ok_or("Document selection needs a query")?;
        let mut editor = PixelEditor::new(request.document.get())?;
        let selection = editor.select(
            query.get(),
            request.frame.as_deref(),
            request.layer.as_deref(),
            request.cel.as_deref(),
            request.saved.map_or("{}", RawValue::get),
        )?;
        serde_json::to_string(&selection)
    } else {
        let raster = rasterize_pixel_frame(
            request.document.get(),
            request.frame.as_deref(),
            request.layer.as_deref(),
            request.cel.as_deref(),
        )?;
        serde_json::to_string(&raster)
    };
    println!("{}", output.map_err(|error| error.to_string())?);
    Ok(())
}

#[derive(Deserialize)]
struct PaintRequest<'a> {
    #[serde(borrow)]
    document: &'a RawValue,
    #[serde(borrow)]
    operation: &'a RawValue,
    frame: Option<String>,
    cel: Option<String>,
}

fn paint(path: std::ffi::OsString, selection: bool) -> Result<(), String> {
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: PaintRequest = serde_json::from_str(&source).map_err(|error| error.to_string())?;
    let mut editor = PixelEditor::new(request.document.get())?;
    let target = if selection {
        if request.cel.is_some() {
            return Err("A selection edit needs a stable selection ID and a query".into());
        }
        serde_json::to_string(
            &editor.save_selection(request.operation.get(), request.frame.as_deref())?,
        )
    } else {
        serde_json::to_string(&editor.paint(
            request.operation.get(),
            request.frame.as_deref(),
            request.cel.as_deref(),
        )?)
    }
    .map_err(|error| error.to_string())?;
    let document = editor.snapshot()?;
    println!(r#"{{"target":{target},"document":{document}}}"#);
    Ok(())
}

#[derive(Deserialize)]
struct CaptureRequest<'a> {
    #[serde(borrow)]
    document: &'a RawValue,
    #[serde(borrow)]
    options: Option<&'a RawValue>,
}

fn capture(path: std::ffi::OsString, selection: bool) -> Result<(), String> {
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: CaptureRequest =
        serde_json::from_str(&source).map_err(|error| error.to_string())?;
    let mut editor = PixelEditor::new(request.document.get())?;
    let options = request.options.map_or("{}", RawValue::get);
    let output = if selection {
        serde_json::to_string(&editor.copy_selection(options)?)
    } else {
        serde_json::to_string(&editor.capture_brush(options)?)
    }
    .map_err(|error| error.to_string())?;
    println!("{output}");
    Ok(())
}

fn select(path: std::ffi::OsString, packed: bool) -> Result<(), String> {
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: SelectionRequest =
        serde_json::from_str(&source).map_err(|error| error.to_string())?;
    let words = select_pixel_mask_with_raster(
        request.width,
        request.height,
        request.query.get(),
        request.rgba,
        request.saved.map_or("{}", RawValue::get),
        request.large,
        request.indexed,
    )?;
    let result = if packed {
        serde_json::to_string(&words)
    } else {
        serde_json::to_string(&mask_pixels(request.width, &words))
    };
    println!("{}", result.map_err(|error| error.to_string())?);
    Ok(())
}

fn run() -> Result<(), String> {
    let mut args = std::env::args_os().skip(1);
    let usage = "Usage: ink-studio-pixel DOCUMENT | ink-studio-pixel import-png FILE | ink-studio-pixel select|select-mask|raster|select-document|paint-document|save-selection-document|capture-brush-document|copy-selection-document|journal-document|command-document REQUEST | ink-studio-pixel session ACTION DIRECTORY | ink-studio-pixel palette ACTION SOURCE --out OUTPUT | ink-studio-pixel edit|preview|replay DOCUMENT INPUT [--out OUTPUT]";
    let path = args.next().ok_or(usage)?;
    if let Some(action @ ("edit" | "preview" | "replay")) = path.to_str() {
        return file_edit_cli::run(action, args);
    }
    if path == "session" { return session_cli::run(args); }
    if path == "palette" { return palette_cli::run(args); }
    if let Some(request) = args.next() {
        if args.next().is_some() {
            return Err(usage.into());
        }
        if path == "import-png" {
            let image = std::fs::read(request).map_err(|error| error.to_string())?;
            return print_opened(open_pixel_png(&image)?);
        }
        if path == "select" || path == "select-mask" {
            return select(request, path == "select-mask");
        }
        if path == "raster" || path == "select-document" {
            return frame(request, path == "select-document");
        }
        if path == "paint-document" || path == "save-selection-document" {
            return paint(request, path == "save-selection-document");
        }
        if path == "capture-brush-document" || path == "copy-selection-document" {
            return capture(request, path == "copy-selection-document");
        }
        if path == "journal-document" {
            return journal_cli::run(request);
        }
        if path == "command-document" {
            return journal_cli::run_command(request);
        }
        return Err(usage.into());
    }
    let source = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    print_opened(open_pixel_document(&source)?)
}

fn print_opened(opened: OpenedDocument) -> Result<(), String> {
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
