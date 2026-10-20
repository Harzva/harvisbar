use anyhow::Result;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use time::macros::format_description;
use time::{Duration, OffsetDateTime, PrimitiveDateTime};

pub const DEFAULT_REPORT_RETENTION_DAYS: u64 = 14;
pub const DEFAULT_REPORT_KEEP_LATEST: u64 = 50;

#[derive(Debug, Clone, Default, Serialize)]
pub struct RetentionOutcome {
    pub archived: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone)]
struct ReportCandidate {
    path: PathBuf,
    moment: OffsetDateTime,
}

/// T305: logrotate-style report retention. A report is retained only while
/// its age is at most `retention_days` AND it ranks among the newest
/// `keep_latest` reports; anything failing either condition is moved (never
/// deleted) into `<archive_reports_root>/YYYY-MM/`, grouped by the report's
/// own month, so the live directory stays bounded.
pub fn archive_reports(
    reports_dir: &Path,
    archive_reports_root: &Path,
    retention_days: u64,
    keep_latest: u64,
) -> Result<RetentionOutcome> {
    let now = OffsetDateTime::now_utc();
    let mut outcome = RetentionOutcome::default();
    let mut candidates = Vec::new();
    let entries = match fs::read_dir(reports_dir) {
        Ok(entries) => entries,
        Err(error) => {
            outcome.warnings.push(format!(
                "retention could not list reports dir {}: {error}",
                reports_dir.display()
            ));
            return Ok(outcome);
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file()
            || path.extension().and_then(|value| value.to_str()) != Some("md")
            || !path
                .file_name()
                .and_then(|value| value.to_str())
                .map(|name| name.starts_with("tick-"))
                .unwrap_or(false)
        {
            continue;
        }
        let Some(moment) = report_moment(&path) else {
            outcome.warnings.push(format!(
                "retention could not date report {}, leaving it in place",
                path.display()
            ));
            continue;
        };
        candidates.push(ReportCandidate { path, moment });
    }
    // Newest first; ties broken by file name for deterministic ranking.
    candidates.sort_by(|left, right| {
        right
            .moment
            .cmp(&left.moment)
            .then_with(|| left.path.cmp(&right.path))
    });
    for (rank, candidate) in candidates.iter().enumerate() {
        if retain(now - candidate.moment, retention_days, rank, keep_latest) {
            continue;
        }
        let month_dir = archive_reports_root.join(month_slug(candidate.moment));
        let target = month_dir.join(
            candidate
                .path
                .file_name()
                .unwrap_or_else(|| std::ffi::OsStr::new("report.md")),
        );
        if target.exists() {
            outcome.warnings.push(format!(
                "retention target already exists, leaving source in place: {}",
                target.display()
            ));
            continue;
        }
        if let Err(error) = fs::create_dir_all(&month_dir) {
            outcome.warnings.push(format!(
                "retention could not create {}: {error}",
                month_dir.display()
            ));
            continue;
        }
        match fs::rename(&candidate.path, &target) {
            Ok(()) => outcome.archived.push(target.display().to_string()),
            Err(error) => outcome.warnings.push(format!(
                "retention could not archive {}: {error}",
                candidate.path.display()
            )),
        }
    }
    Ok(outcome)
}

/// Derived count: number of archived report files actually present under the
/// archive tree, so status.json always agrees with the filesystem.
pub fn count_archived_reports(archive_reports_root: &Path) -> usize {
    let mut count = 0;
    let mut stack = vec![archive_reports_root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
                count += 1;
            }
        }
    }
    count
}

/// Retention decision: keep only while fresh enough AND within the newest
/// `keep_latest` reports (rank 0 = newest).
fn retain(age: Duration, retention_days: u64, newest_rank: usize, keep_latest: u64) -> bool {
    age <= Duration::days(retention_days as i64) && (newest_rank as u64) < keep_latest
}

/// `YYYY-MM` archive bucket for a report moment.
fn month_slug(moment: OffsetDateTime) -> String {
    let date = moment.date();
    format!("{:04}-{:02}", date.year(), date.month() as u8)
}

/// Report time: parsed from the `tick-YYYYMMDDTHHMMSSZ` file name first, with
/// the file mtime as fallback (both are tick-written timestamps).
fn report_moment(path: &Path) -> Option<OffsetDateTime> {
    parse_name_timestamp(path).or_else(|| modified_at(path))
}

fn parse_name_timestamp(path: &Path) -> Option<OffsetDateTime> {
    let stem = path.file_stem()?.to_str()?;
    let slug = stem.strip_prefix("tick-")?;
    let format = format_description!("[year][month][day]T[hour][minute][second]Z");
    let parsed = PrimitiveDateTime::parse(slug, &format).ok()?;
    Some(parsed.assume_utc())
}

fn modified_at(path: &Path) -> Option<OffsetDateTime> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    Some(OffsetDateTime::from(modified))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_report(dir: &Path, name: &str) -> PathBuf {
        fs::create_dir_all(dir).expect("create reports dir");
        let path = dir.join(name);
        fs::write(&path, "# report\n").expect("write report");
        path
    }

    #[test]
    fn retain_keeps_only_fresh_and_latest_reports() {
        let fresh = Duration::hours(1);
        let old = Duration::days(30);
        assert!(retain(fresh, 14, 0, 50)); // fresh AND newest rank
        assert!(retain(fresh, 14, 49, 50)); // fresh AND last kept slot
        assert!(!retain(fresh, 14, 50, 50)); // fresh but past keep_latest archives
        assert!(!retain(old, 14, 0, 50)); // old archives even at the best rank
        assert!(!retain(old, 14, 49, 50));
        assert!(retain(Duration::days(14), 14, 0, 50)); // boundary day kept
        assert!(!retain(
            Duration::days(14) + Duration::seconds(1),
            14,
            0,
            50
        ));
        assert!(!retain(Duration::seconds(1), 0, 0, 50)); // 0-day retention archives
        assert!(!retain(fresh, 14, 0, 0)); // keep_latest 0 archives everything
    }

    #[test]
    fn month_slug_groups_by_report_month() {
        let dir =
            std::env::temp_dir().join(format!("harvis-retention-name-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let june = write_report(&dir, "tick-20260625T012805Z.md");
        let july = write_report(&dir, "tick-20260717T235959Z.md");
        assert_eq!(
            month_slug(report_moment(&june).expect("june moment")),
            "2026-06"
        );
        assert_eq!(
            month_slug(report_moment(&july).expect("july moment")),
            "2026-07"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn archive_reports_moves_old_reports_into_month_dirs() {
        let root =
            std::env::temp_dir().join(format!("harvis-retention-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let reports = root.join("reports");
        let archive = root.join("archive/reports");
        write_report(&reports, "tick-20200601T000000Z.md");
        write_report(&reports, "tick-20200615T000000Z.md");
        write_report(&reports, "tick-20200701T000000Z.md");
        let slug_of = |moment: OffsetDateTime| {
            format!(
                "tick-{:04}{:02}{:02}T{:02}{:02}{:02}Z.md",
                moment.year(),
                moment.month() as u8,
                moment.day(),
                moment.hour(),
                moment.minute(),
                moment.second()
            )
        };
        let now = OffsetDateTime::now_utc();
        let fresh_slug = slug_of(now);
        let fresh_overflow_slug = slug_of(now - Duration::seconds(2));
        write_report(&reports, &fresh_slug);
        write_report(&reports, &fresh_overflow_slug);

        let outcome = archive_reports(&reports, &archive, 14, 1).expect("archive run");
        assert_eq!(outcome.warnings, Vec::<String>::new());
        // AND semantics: only the newest fresh report survives keep_latest=1;
        // the second fresh report archives despite being within the age window,
        // alongside the three ancient 2020 reports.
        assert_eq!(outcome.archived.len(), 4);
        assert!(!reports.join("tick-20200601T000000Z.md").exists());
        assert!(!reports.join("tick-20200615T000000Z.md").exists());
        assert!(!reports.join("tick-20200701T000000Z.md").exists());
        assert!(reports.join(&fresh_slug).exists());
        assert!(!reports.join(&fresh_overflow_slug).exists());
        assert!(archive.join("2020-06/tick-20200601T000000Z.md").exists());
        assert!(archive.join("2020-06/tick-20200615T000000Z.md").exists());
        assert!(archive.join("2020-07/tick-20200701T000000Z.md").exists());
        assert_eq!(count_archived_reports(&archive), 4);

        // Second run is idempotent: nothing left to archive.
        let second = archive_reports(&reports, &archive, 14, 1).expect("second run");
        assert!(second.archived.is_empty());
        assert_eq!(count_archived_reports(&archive), 4);

        // 0/0 retention archives everything older than the current second.
        std::thread::sleep(std::time::Duration::from_secs(1));
        let third = archive_reports(&reports, &archive, 0, 0).expect("third run");
        assert_eq!(third.archived.len(), 1);
        assert_eq!(count_archived_reports(&archive), 5);

        let _ = fs::remove_dir_all(&root);
    }
}
