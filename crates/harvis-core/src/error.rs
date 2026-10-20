use thiserror::Error;

#[derive(Debug, Error)]
pub enum HarvisError {
    #[error("invalid root: {0}")]
    InvalidRoot(String),
    #[error("invalid path outside root: {0}")]
    InvalidPath(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("time format error: {0}")]
    TimeFormat(#[from] time::error::Format),
}

pub type HarvisResult<T> = Result<T, HarvisError>;
