use ink_studio_pixel::open_pixel_document;

fn run() -> Result<(), String> {
    let mut args = std::env::args_os().skip(1);
    let path = args.next().ok_or("Usage: ink-studio-pixel DOCUMENT")?;
    if args.next().is_some() {
        return Err("Usage: ink-studio-pixel DOCUMENT".into());
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
