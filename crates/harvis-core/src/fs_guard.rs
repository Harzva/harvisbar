use std::path::{Path, PathBuf};

use crate::error::{HarvisError, HarvisResult};

pub fn resolve_existing_dir(path: impl AsRef<Path>) -> HarvisResult<PathBuf> {
    let resolved = path.as_ref().canonicalize()?;
    if !resolved.is_dir() {
        return Err(HarvisError::InvalidRoot(resolved.display().to_string()));
    }
    Ok(resolved)
}

pub fn is_within_root(path: &Path, root: &Path) -> bool {
    match (path.canonicalize(), root.canonicalize()) {
        (Ok(path), Ok(root)) => path.starts_with(root),
        _ => false,
    }
}

pub fn resolve_workspace_path(root: &Path, value: &str) -> HarvisResult<PathBuf> {
    let root = resolve_existing_dir(root)?;
    let candidate = if Path::new(value).is_absolute() {
        PathBuf::from(value)
    } else {
        root.join(value)
    };
    let resolved = candidate.canonicalize()?;
    if !resolved.starts_with(&root) {
        return Err(HarvisError::InvalidPath(resolved.display().to_string()));
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_paths_outside_root() {
        let root = std::env::temp_dir();
        let outside = Path::new("/");
        if root != outside {
            assert!(!is_within_root(outside, &root));
        }
    }
}
