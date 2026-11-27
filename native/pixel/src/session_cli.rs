use super::{
    cli_flags::split_arguments,
    file_output::{absolute_normalized, output, stage},
    session_commands::{self as commands, EDITS},
};
use ink_studio_pixel::PixelCommandEditor;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::OsString,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

const USAGE: &str = "Use a pixel-art session command. See ink-studio help for session actions.";
const CHANGED: &str = "The pixel edit session advanced on disk. Reopen it before writing.";

fn checkpoint(directory: &Path, revision: u64) -> PathBuf {
    directory.join(format!("checkpoint-{revision}.json"))
}

fn revision_of(name: &str) -> Option<u64> {
    let digits = name.strip_prefix("checkpoint-")?.strip_suffix(".json")?;
    if digits.starts_with('0') || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse::<u64>().ok().filter(|revision| *revision != 0)
}

fn read(directory: &Path) -> Result<PixelCommandEditor, String> {
    for _ in 0..3 {
        let mut latest = 0;
        for row in fs::read_dir(directory).map_err(|error| error.to_string())? {
            let row = row.map_err(|error| error.to_string())?;
            if let Some(revision) = row.file_name().to_str().and_then(revision_of) {
                latest = latest.max(revision);
            }
        }
        if latest == 0 || latest > 9_007_199_254_740_991 {
            return Err(format!("No pixel edit session in {}", directory.display()));
        }
        let contents = match fs::read_to_string(checkpoint(directory, latest)) {
            Ok(data) => data,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => return Err(error.to_string()),
        };
        if contents.trim() == "null" {
            continue;
        }
        let editor = PixelCommandEditor::open_session(&contents)?;
        if editor.session_generation() != latest {
            return Err("Invalid pixel edit session checkpoint".into());
        }
        return Ok(editor);
    }
    Err("Could not read the current pixel edit session checkpoint".into())
}

fn publish(
    directory: &Path,
    generation: u64,
    editor: &mut PixelCommandEditor,
) -> Result<(), String> {
    let contents = editor.export_session(generation)?;
    let staged = stage(directory, contents.as_bytes(), true)?;
    let target = checkpoint(directory, generation);
    let result = match fs::hard_link(&staged, &target) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            let previous = fs::read_to_string(&target).map_err(|error| error.to_string());
            previous.and_then(|previous| {
                let same = serde_json::from_str::<Value>(&previous)
                    .ok()
                    .zip(serde_json::from_str::<Value>(&contents).ok())
                    .is_some_and(|(a, b)| a == b);
                if same { Ok(()) } else { Err(CHANGED.into()) }
            })
        }
        Err(error) => Err(error.to_string()),
    };
    let _ = fs::remove_file(staged);
    result?;
    if generation > 2 {
        // Keep the last two generations and reserve older names against stale writers.
        if let Ok(tombstone) = stage(directory, b"null", true) {
            if fs::rename(&tombstone, checkpoint(directory, generation - 2)).is_err() {
                let _ = fs::remove_file(tombstone);
            }
        }
    }
    Ok(())
}

fn run_editor(
    directory: &Path,
    editor: &mut PixelCommandEditor,
    generation: &mut u64,
    request: commands::Request,
) -> Result<Result<String, ink_studio_pixel::PixelEditError>, String> {
    let before = editor.session_token()?;
    let outcome = request.invoke(editor);
    if editor.session_token()? != before {
        *generation = generation
            .checked_add(1)
            .ok_or("Pixel edit session revision overflow")?;
        publish(directory, *generation, editor)?;
    }
    Ok(outcome)
}

pub fn run(mut args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let action = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or(USAGE)?;
    let (paths, options) = split_arguments(args, USAGE)?;
    let needs_input =
        EDITS.contains(&action.as_str()) || matches!(action.as_str(), "init" | "run" | "select");
    let valid = needs_input
        || matches!(
            action.as_str(),
            "begin"
                | "status"
                | "commit"
                | "cancel"
                | "undo"
                | "redo"
                | "preview"
                | "validate"
                | "inspect"
                | "copy"
                | "sample"
                | "snap"
                | "timeline"
                | "export"
        );
    if !valid || paths.len() != usize::from(needs_input) + 1 {
        return Err(USAGE.into());
    }
    let directory = &paths[0];
    if directory.as_os_str().is_empty()
        || directory
            .to_str()
            .is_some_and(|text| text.trim().is_empty())
    {
        return Err("A pixel edit session needs a directory".into());
    }
    let input = paths.get(1).map(PathBuf::as_path);
    let (mut editor, mut generation) = if action == "init" {
        commands::initialize(&options)?;
        let source = fs::read_to_string(input.unwrap()).map_err(|error| error.to_string())?;
        let mut editor = PixelCommandEditor::new(&source, 100)?;
        fs::create_dir_all(directory).map_err(|error| error.to_string())?;
        publish(directory, 1, &mut editor)?;
        (editor, 1)
    } else {
        let editor = read(directory)?;
        let generation = editor.session_generation();
        (editor, generation)
    };
    let travel = matches!(action.as_str(), "commit" | "cancel" | "undo" | "redo");
    let mut changed = None;
    if !matches!(action.as_str(), "init" | "status") {
        let out = if matches!(action.as_str(), "run" | "export") {
            commands::target(directory, input, &options)?
        } else {
            None
        };
        if action == "export" && out.is_none() {
            return Err("--out needs a file path".into());
        }
        let request = commands::request(&action, input, &options)?;
        let outcome = run_editor(directory, &mut editor, &mut generation, request)?;
        let (text, rejected) = match outcome {
            Ok(reply) => {
                let value: Value =
                    serde_json::from_str(&reply).map_err(|error| error.to_string())?;
                if travel {
                    changed = value["changed"].as_bool();
                }
                (reply, value["valid"] == false)
            }
            Err(error) => match error.receipt {
                Some(receipt) if action == "run" => (receipt.to_string(), true),
                _ => return Err(error.to_string()),
            },
        };
        if !travel && action != "begin" {
            if action == "export" {
                println!("{}", commands::export(&text, out.as_deref().unwrap())?);
            } else if let Some(file) = out {
                output(&file, &text)?;
            } else {
                println!("{text}");
            }
            if rejected {
                std::process::exit(2);
            }
            return Ok(());
        }
    }
    let absolute = absolute_normalized(directory)?;
    let (_, _, pending) = editor.session_token()?;
    let mut status = json!({ "directory": absolute, "revision": generation, "saved": true, "error": null,
        "pending": pending, "history": editor.history()? });
    if let Some(changed) = changed {
        status["changed"] = json!(changed);
    } else {
        status["documentRevision"] = json!(editor.revision()?);
    }
    println!("{status}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_stale_writer_cannot_overwrite_another_history_or_tombstone() {
        let directory =
            std::env::temp_dir().join(format!("ink-pixel-stale-writer-{}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let scratch = Scratch(directory);
        let path = &scratch.0;
        let document = r##"{"format":"ink-studio/pixel-art","version":2,"width":4,"height":4,"pixelAspect":[1,1],"palette":{"ink":"#112233"},"layers":[{"id":"ink"}],"frames":[{"id":"art","durationMs":100,"cels":{"ink":{"marks":[]}}}]}"##;
        let mut initial = PixelCommandEditor::new(document, 3).unwrap();
        publish(path, 1, &mut initial).unwrap();
        let mut ahead = read(path).unwrap();
        let mut stale = read(path).unwrap();
        ahead.begin("First writer").unwrap();
        stale.begin("Second writer").unwrap();
        publish(path, 2, &mut ahead).unwrap();
        assert_eq!(publish(path, 2, &mut stale).unwrap_err(), CHANGED);
        assert!(ahead.cancel().unwrap());
        publish(path, 3, &mut ahead).unwrap();
        ahead.begin("Third revision").unwrap();
        publish(path, 4, &mut ahead).unwrap();
        assert_eq!(publish(path, 2, &mut stale).unwrap_err(), CHANGED);
        assert_eq!(
            fs::read_to_string(checkpoint(path, 2)).unwrap().trim(),
            "null"
        );
        assert!(read(path).unwrap().session_token().unwrap().2);
        assert_eq!(fs::read_dir(path).unwrap().count(), 4);
    }
}
