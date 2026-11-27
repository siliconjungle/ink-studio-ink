use std::{
    fs::{self, OpenOptions},
    io::{ErrorKind, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

pub(crate) fn absolute_normalized(path: &Path) -> Result<PathBuf, String> {
    let absolute = std::path::absolute(path).map_err(|error| error.to_string())?;
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        if component == std::path::Component::ParentDir {
            normalized.pop();
        } else {
            normalized.push(component.as_os_str());
        }
    }
    Ok(normalized)
}

pub(crate) fn resolved(path: &Path) -> Result<PathBuf, String> {
    let normalized = absolute_normalized(path)?;
    let mut existing = normalized.as_path();
    let mut suffix = Vec::new();
    let mut target = loop {
        match fs::canonicalize(existing) {
            Ok(target) => break target,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                let name = existing.file_name().ok_or_else(|| error.to_string())?;
                suffix.push(name);
                existing = existing.parent().ok_or_else(|| error.to_string())?;
            }
            Err(error) => return Err(error.to_string()),
        }
    };
    target.extend(suffix.into_iter().rev());
    Ok(target)
}

pub(crate) fn output(path: &Path, data: &str) -> Result<(), String> {
    publish(path, data.as_bytes(), true)
}

pub(crate) fn output_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    publish(path, bytes, false)
}

fn publish(path: &Path, data: &[u8], newline: bool) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let staged = stage(parent, data, newline)?;
    let renamed = fs::rename(&staged, path).map_err(|error| error.to_string());
    if renamed.is_err() {
        let _ = fs::remove_file(staged);
    }
    renamed
}

pub(crate) fn stage(directory: &Path, data: &[u8], newline: bool) -> Result<PathBuf, String> {
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
                    file.write_all(data)?;
                    if newline {
                        file.write_all(b"\n")?;
                    }
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
