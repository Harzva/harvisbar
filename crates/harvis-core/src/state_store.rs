use serde::{de::DeserializeOwned, Serialize};
use std::fs;
use std::path::Path;

use crate::error::HarvisResult;

pub fn read_json_file<T: DeserializeOwned>(path: &Path) -> HarvisResult<T> {
    let file = fs::File::open(path)?;
    Ok(serde_json::from_reader(file)?)
}

pub fn write_json_file<T: Serialize>(path: &Path, value: &T) -> HarvisResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = fs::File::create(path)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    Ok(())
}
