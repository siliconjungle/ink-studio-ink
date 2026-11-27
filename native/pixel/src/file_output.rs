use std::{
    fs,
    path::{Path, PathBuf},
};

pub(crate) fn resolved(path: &Path) -> Result<PathBuf, String> {
    if let Ok(existing) = fs::canonicalize(path) {
        return Ok(existing);
    }
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

pub(crate) fn output(path: &Path, data: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let staged = super::session_cli::stage(parent, data)?;
    let renamed = fs::rename(&staged, path).map_err(|error| error.to_string());
    if renamed.is_err() {
        let _ = fs::remove_file(staged);
    }
    renamed
}
