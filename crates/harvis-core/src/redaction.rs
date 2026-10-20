const SENSITIVE_MARKERS: &[&str] = &[
    ".env",
    "authorization",
    "bearer ",
    "cookie",
    "password",
    "private_key",
    "secret",
    "token",
];

pub fn contains_sensitive_marker(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    SENSITIVE_MARKERS
        .iter()
        .any(|marker| lowered.contains(marker))
}

pub fn redact_sensitive_text(value: &str) -> String {
    value
        .lines()
        .map(|line| {
            if contains_sensitive_marker(line) {
                "[REDACTED]"
            } else {
                line
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_common_sensitive_markers() {
        assert!(contains_sensitive_marker("Authorization: Bearer abc"));
        assert!(contains_sensitive_marker("HARVIS_HTTP_AUTH_TOKEN=abc"));
        assert!(!contains_sensitive_marker("normal status line"));
    }

    #[test]
    fn redacts_only_sensitive_lines() {
        let redacted = redact_sensitive_text("ok\nsecret=value\nstill ok");
        assert_eq!(redacted, "ok\n[REDACTED]\nstill ok");
    }
}
