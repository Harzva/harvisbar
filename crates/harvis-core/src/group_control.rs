//! Thin same-user client for the Swift process. Never reads or writes group ledgers.
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

pub const MAX_MESSAGE_BYTES: usize = 1_048_576;
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
#[derive(Debug)]
pub struct ControlError { pub code: String, pub message: String }
impl std::fmt::Display for ControlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}: {}", self.code, self.message) }
}
impl std::error::Error for ControlError {}
fn failure(code: &str, message: &str) -> ControlError { ControlError { code: code.into(), message: message.into() } }
pub fn default_socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("HARVIS_GROUP_SOCKET").filter(|p| !p.is_empty()) { return path.into(); }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Library/Application Support/HarvisBar/GroupChat/control.sock")
}
pub fn call(method: &str, params: Value) -> Result<Value, ControlError> { call_at(&default_socket_path(), method, params) }

#[cfg(unix)]
pub fn call_at(path: &Path, method: &str, params: Value) -> Result<Value, ControlError> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    use std::os::fd::AsRawFd;
    let uid = unsafe { libc::getuid() };
    let metadata = std::fs::symlink_metadata(path).map_err(|_| failure("unavailable", "HarvisBar group control is unavailable. Keep the app running."))?;
    let parent = path.parent().and_then(|p| std::fs::symlink_metadata(p).ok());
    if !metadata.file_type().is_socket() || metadata.uid() != uid || metadata.mode() & 0o077 != 0
        || !parent.is_some_and(|m| m.is_dir() && m.uid() == uid && m.mode() & 0o077 == 0) {
        return Err(failure("unsafe_socket", "Group control must use a private socket owned by this user."));
    }
    if !matches!(method, "groups.list" | "groups.status" | "groups.send" | "groups.results" | "groups.cancel" | "groups.recover") || !params.is_object() {
        return Err(failure("invalid_request", "Unknown group method or invalid parameters."));
    }
    let id = format!("{}-{}", std::process::id(), NEXT_ID.fetch_add(1, Ordering::Relaxed));
    let mut request = serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})).map_err(|_| failure("invalid_request", "Cannot encode group request."))?;
    if request.len() > MAX_MESSAGE_BYTES { return Err(failure("request_too_large", "Group request exceeds the control limit.")); }
    request.push(b'\n');
    let mut stream = connect_bounded(path)?;
    #[cfg(target_os = "macos")]
    {
        let mut peer_uid = 0; let mut peer_gid = 0;
        if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut peer_uid, &mut peer_gid) } != 0 || peer_uid != uid {
            return Err(failure("unsafe_socket", "Group control peer belongs to another user."));
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = stream.as_raw_fd();
    stream.set_read_timeout(Some(Duration::from_secs(35))).map_err(|_| failure("transport", "Cannot set group response timeout."))?;
    stream.set_write_timeout(Some(Duration::from_secs(10))).map_err(|_| failure("transport", "Cannot set group request timeout."))?;
    stream.write_all(&request).map_err(|_| failure("transport", "Group request transport failed; retry only with the same requestID."))?;
    let mut bytes = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(35);
    while bytes.len() <= MAX_MESSAGE_BYTES {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() { return Err(failure("transport", "Group response timed out; retry only with the same requestID.")); }
        stream.set_read_timeout(Some(Duration::from_millis(remaining.as_millis().max(1) as u64))).map_err(|_| failure("transport", "Cannot bound group response timeout."))?;
        let mut buffer = [0u8; 8192];
        let capacity = buffer.len().min(MAX_MESSAGE_BYTES + 1 - bytes.len());
        let count = match stream.read(&mut buffer[..capacity]) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(failure("transport", "Group response was interrupted; retry only with the same requestID.")),
        };
        if count == 0 { break; }
        bytes.extend_from_slice(&buffer[..count]);
        if bytes.contains(&b'\n') { break; }
    }
    if bytes.last() != Some(&b'\n') || bytes.len() > MAX_MESSAGE_BYTES + 1 { return Err(failure("invalid_response", "Group response exceeds the limit or is incomplete.")); }
    let response: Value = serde_json::from_slice(&bytes).map_err(|_| failure("invalid_response", "Malformed group response."))?;
    if response["jsonrpc"] != "2.0" || response["id"] != id || response.get("result").is_some() == response.get("error").is_some() {
        return Err(failure("invalid_response", "Group response does not match the request."));
    }
    if let Some(error) = response.get("error") {
        return Err(ControlError { code: error["code"].as_i64().map(|v| v.to_string()).unwrap_or_else(|| "group_error".into()),
            message: error["message"].as_str().unwrap_or("Group request was rejected.").into() });
    }
    Ok(response["result"].clone())
}
#[cfg(unix)]
fn connect_bounded(path: &Path) -> Result<std::os::unix::net::UnixStream, ControlError> {
    use std::os::{fd::{AsRawFd, FromRawFd}, unix::ffi::OsStrExt};
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() { return Err(failure("invalid_socket_path", "Group socket path exceeds the platform limit.")); }
    address.sun_family = libc::AF_UNIX as _;
    #[cfg(target_os = "macos")]
    { address.sun_len = std::mem::size_of::<libc::sockaddr_un>() as _; }
    for (target, source) in address.sun_path.iter_mut().zip(bytes) { *target = *source as _; }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 { return Err(failure("transport", "Cannot create group control connection.")); }
    let stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC); }
    stream.set_nonblocking(true).map_err(|_| failure("transport", "Cannot bound group connect timeout."))?;
    let result = unsafe { libc::connect(fd, &address as *const _ as *const libc::sockaddr, std::mem::size_of_val(&address) as _) };
    if result < 0 {
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINPROGRESS) { return Err(failure("unavailable", "HarvisBar group control is unavailable. Keep the app running.")); }
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() { return Err(failure("unavailable", "Group control connect timed out.")); }
            let mut event = libc::pollfd { fd: stream.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
            let result = unsafe { libc::poll(&mut event, 1, remaining.as_millis().min(2000) as _) };
            if result < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) { continue; }
            if result <= 0 || stream.take_error().map_err(|_| failure("transport", "Cannot inspect group connection."))?.is_some() {
                return Err(failure("unavailable", "Group control connection failed or timed out."));
            }
            break;
        }
    }
    stream.set_nonblocking(false).map_err(|_| failure("transport", "Cannot initialize group control connection."))?;
    Ok(stream)
}
#[cfg(not(unix))]
pub fn call_at(_: &Path, _: &str, _: Value) -> Result<Value, ControlError> { Err(failure("unsupported", "Group control requires a local Unix socket.")) }

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::{fs::PermissionsExt, net::UnixListener};
    fn fixture() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("hgc-{}-{}", std::process::id(), NEXT_ID.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir(&dir).unwrap(); std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap(); dir
    }
    #[test]
    fn forwards_exact_request_and_checks_response_identity() {
        let dir = fixture(); let path = dir.join("c.sock"); let listener = UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap(); let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "groups.send"); assert_eq!(request["params"]["requestID"], "stable-id");
            writeln!(stream, "{}", json!({"jsonrpc":"2.0","id":request["id"],"result":{"messageID":"durable"}})).unwrap();
        });
        assert_eq!(call_at(&path, "groups.send", json!({"requestID":"stable-id"})).unwrap()["messageID"], "durable");
        server.join().unwrap(); std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rejects_mismatched_or_unframed_response() {
        for wrong_id in [true, false] {
            let dir = fixture(); let path = dir.join("c.sock"); let listener = UnixListener::bind(&path).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap(); let mut line = String::new();
                BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                let response = json!({"jsonrpc":"2.0","id":if wrong_id {json!("wrong")} else {request["id"].clone()},"result":{}});
                write!(stream, "{}{}", response, if wrong_id {"\n"} else {""}).unwrap();
                stream.shutdown(std::net::Shutdown::Write).unwrap();
            });
            assert_eq!(call_at(&path, "groups.list", json!({})).unwrap_err().code, "invalid_response");
            server.join().unwrap(); std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[test]
    fn rejects_public_socket_and_missing_runtime() {
        let dir = fixture(); let path = dir.join("c.sock");
        assert_eq!(call_at(&path, "groups.list", json!({})).unwrap_err().code, "unavailable");
        let _listener = UnixListener::bind(&path).unwrap(); std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(call_at(&path, "groups.list", json!({})).unwrap_err().code, "unsafe_socket"); std::fs::remove_dir_all(dir).unwrap();
    }
}
