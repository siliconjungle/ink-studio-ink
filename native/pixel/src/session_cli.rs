use ink_studio_pixel::PixelCommandEditor;
use serde_json::{Value, json};
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{ErrorKind, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

const USAGE: &str = "Usage: ink-studio-pixel session init DIRECTORY DOCUMENT | session run DIRECTORY COMMAND | session status|begin|commit|cancel|undo|redo DIRECTORY";
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

fn stage(directory: &Path, data: &str) -> Result<PathBuf, String> {
    static NEXT_FILE: AtomicU64 = AtomicU64::new(0);
    loop {
        let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
        let staging = directory.join(format!(".ink-checkpoint-{}-{id}", std::process::id()));
        match OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&staging)
        {
            Ok(mut file) => {
                if let Err(error) = (|| {
                    file.write_all(data.as_bytes())?;
                    file.write_all(b"\n")?;
                    file.sync_all()
                })() {
                    let _ = fs::remove_file(&staging);
                    return Err(error.to_string());
                }
                return Ok(staging);
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn publish(
    directory: &Path,
    generation: u64,
    editor: &mut PixelCommandEditor,
) -> Result<(), String> {
    let contents = editor.export_session(generation)?;
    let staged = stage(directory, &contents)?;
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
        if let Ok(tombstone) = stage(directory, "null") {
            if fs::rename(&tombstone, checkpoint(directory, generation - 2)).is_err() {
                let _ = fs::remove_file(tombstone);
            }
        }
    }
    Ok(())
}

fn envelope(action: &str) -> Value {
    json!({ "format": "ink-studio/pixel-command", "version": 1, "action": action })
}

pub fn run(mut args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let action = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or(USAGE)?;
    let dir = PathBuf::from(args.next().ok_or(USAGE)?);
    let extra: Vec<_> = args.collect();
    let valid = match action.as_str() {
        "init" | "run" => extra.len() == 1,
        "begin" => extra.is_empty() || extra.len() == 2 && extra[0] == "--label",
        "status" | "commit" | "cancel" | "undo" | "redo" => extra.is_empty(),
        _ => false,
    };
    if !valid || dir.as_os_str().is_empty() {
        return Err(USAGE.into());
    }
    let (mut editor, mut generation) = if action == "init" {
        let source = fs::read_to_string(&extra[0]).map_err(|error| error.to_string())?;
        let mut editor = PixelCommandEditor::new(&source, 100)?;
        fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
        publish(&dir, 1, &mut editor)?;
        (editor, 1)
    } else {
        let editor = read(&dir)?;
        let generation = editor.session_generation();
        (editor, generation)
    };
    let mut reply = None;
    let mut rejected = false;
    if !matches!(action.as_str(), "init" | "status") {
        let command = if action == "run" {
            fs::read_to_string(&extra[0]).map_err(|error| error.to_string())?
        } else {
            let mut command = envelope(&action);
            if extra.len() == 2 {
                command["label"] = json!(extra[1].to_str().ok_or(USAGE)?);
            }
            command.to_string()
        };
        let before = editor.session_token()?;
        let outcome = editor.execute(&command);
        if editor.session_token()? != before {
            generation = generation
                .checked_add(1)
                .ok_or("Pixel edit session revision overflow")?;
            publish(&dir, generation, &mut editor)?;
        }
        match outcome {
            Ok(value) => {
                let parsed: Value =
                    serde_json::from_str(&value).map_err(|error| error.to_string())?;
                rejected = parsed["valid"] == false;
                reply = Some((value, parsed));
            }
            Err(mut error) => {
                if let Some(receipt) = error.receipt.take() {
                    println!("{receipt}");
                    std::process::exit(2);
                }
                return Err(error.to_string());
            }
        }
    }

    if let Some((text, _)) = reply.as_ref().filter(|_| action == "run") {
        println!("{text}");
        if rejected {
            std::process::exit(2);
        }
        return Ok(());
    }
    let absolute = fs::canonicalize(&dir).map_err(|error| error.to_string())?;
    let (_, _, pending) = editor.session_token()?;
    let mut status = json!({ "directory": absolute, "revision": generation, "saved": true, "error": null,
        "pending": pending, "history": editor.history()? });
    if matches!(action.as_str(), "commit" | "cancel" | "undo" | "redo") {
        status["changed"] = reply.unwrap().1["changed"].clone();
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
