use super::{
    cli_flags::{reference, split_arguments},
    file_output::{output, output_bytes, resolved},
};
use ink_studio_pixel::PixelFileEditor;
use std::{ffi::OsString, fs, path::Path};

const USAGE: &str =
    "Use pixel-art slices inspect <document> or slices export <document> --slice id --out slice.png";

pub(crate) fn run(args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let (paths, options) = split_arguments(args, USAGE)?;
    let [command, source] = paths.as_slice() else {
        return Err(USAGE.into());
    };
    let export = match command.to_str() {
        Some("inspect") => false,
        Some("export") => true,
        _ => return Err(USAGE.into()),
    };
    let allowed = if export { &["slice", "frame", "out", "metadata"][..] } else { &["frame", "out"][..] };
    if options.iter().any(|(key, value)| !allowed.contains(&key.as_str()) || reference(value).is_none()) {
        return Err(USAGE.into());
    }
    let argument = |name| options.get(name).and_then(reference);
    let out = argument("out").map(Path::new);
    let metadata = argument("metadata").map(Path::new);
    let targets: Vec<_> = out.into_iter().chain(metadata).map(resolved).collect::<Result<_, _>>()?;
    if targets.contains(&resolved(source)?) || (targets.len() == 2 && targets[0] == targets[1]) {
        return Err(USAGE.into());
    }
    let text = fs::read_to_string(source).map_err(|error| error.to_string())?;
    let mut editor = PixelFileEditor::new(&text)?;
    let frame = argument("frame");
    if !export {
        let report = editor.slices(frame).map_err(|error| error.to_string())?;
        if let Some(out) = out {
            return output(out, &report);
        }
        println!("{report}");
        return Ok(());
    }
    let name = argument("slice").filter(|name| stable_id(name)).ok_or(USAGE)?;
    let out = out.filter(|path| path.extension().and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("png"))).ok_or(USAGE)?;
    let (report, png) = editor.slice_png(name, frame).map_err(|error| error.to_string())?;
    output_bytes(out, &png)?;
    if let Some(path) = metadata {
        output(path, &report)?;
    }
    Ok(())
}

fn stable_id(name: &str) -> bool {
    let mut bytes = name.bytes();
    name.len() <= 64 && bytes.next().is_some_and(|byte| byte.is_ascii_lowercase()) &&
        bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}
