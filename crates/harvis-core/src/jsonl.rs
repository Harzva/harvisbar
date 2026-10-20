use serde::{de::DeserializeOwned, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

use crate::error::HarvisResult;

pub fn append_jsonl<T: Serialize>(path: &Path, item: &T) -> HarvisResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    serde_json::to_writer(&mut file, item)?;
    writeln!(file)?;
    Ok(())
}

pub fn read_jsonl<T: DeserializeOwned>(path: &Path, limit: usize) -> HarvisResult<Vec<T>> {
    if !path.exists() {
        return Ok(Vec::new());
    }

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut rows = Vec::new();
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        rows.push(serde_json::from_str(&line)?);
    }
    let start = rows.len().saturating_sub(limit);
    Ok(rows.split_off(start))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use std::fs;

    #[derive(Debug, Deserialize, PartialEq, Serialize)]
    struct Row {
        id: u32,
        label: String,
    }

    #[test]
    fn appends_and_reads_limited_jsonl_rows() {
        let dir = std::env::temp_dir().join(format!(
            "harvis-jsonl-test-{}-{}",
            std::process::id(),
            crate::time::now_rfc3339().expect("time").replace(':', "-")
        ));
        fs::create_dir_all(&dir).expect("create temp dir");
        let path = dir.join("events.jsonl");

        append_jsonl(
            &path,
            &Row {
                id: 1,
                label: "first".to_string(),
            },
        )
        .expect("append first");
        append_jsonl(
            &path,
            &Row {
                id: 2,
                label: "second".to_string(),
            },
        )
        .expect("append second");

        let rows: Vec<Row> = read_jsonl(&path, 1).expect("read limited rows");
        assert_eq!(
            rows,
            vec![Row {
                id: 2,
                label: "second".to_string()
            }]
        );

        fs::remove_dir_all(dir).ok();
    }
}
