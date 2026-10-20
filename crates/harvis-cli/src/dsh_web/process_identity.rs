//! Private, bounded process inspection. Never serialize or log raw environments.
use std::path::PathBuf;

const MAX_BYTES: usize = 1024 * 1024;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Snapshot {
    pub command: String,
    pub home: Option<PathBuf>,
    pub started: (u64, u64),
}

fn home_from_environment(bytes: &[u8]) -> Option<Option<PathBuf>> {
    if bytes.len() > MAX_BYTES || (!bytes.is_empty() && bytes.last() != Some(&0)) {
        return None;
    }
    let mut home = None;
    for entry in bytes.split(|byte| *byte == 0) {
        if let Some(value) = entry.strip_prefix(b"DSH_HOME=") {
            // Duplicate assignments are ambiguous, including identical duplicates.
            if home.is_some() {
                return None;
            }
            let value = std::str::from_utf8(value).ok()?;
            let path = PathBuf::from(value);
            if !path.is_absolute() {
                return None;
            }
            home = Some(path);
        }
    }
    Some(home)
}

#[cfg(any(target_os = "macos", test))]
fn take_c_string<'a>(bytes: &'a [u8], offset: &mut usize) -> Option<&'a [u8]> {
    let remaining = bytes.get(*offset..)?;
    let count = remaining.iter().position(|byte| *byte == 0)?;
    *offset += count + 1;
    Some(&remaining[..count])
}

#[cfg(any(target_os = "macos", test))]
fn parse_procargs(bytes: &[u8]) -> Option<(String, Option<PathBuf>)> {
    if bytes.len() > MAX_BYTES {
        return None;
    }
    let argc = i32::from_ne_bytes(bytes.get(..4)?.try_into().ok()?);
    if argc <= 0 || argc as usize > bytes.len() {
        return None;
    }
    let mut offset = 4;
    if take_c_string(bytes, &mut offset)?.is_empty() {
        return None;
    }
    while bytes.get(offset) == Some(&0) {
        offset += 1;
    }
    let mut args = Vec::new();
    for _ in 0..argc {
        args.push(std::str::from_utf8(take_c_string(bytes, &mut offset)?).ok()?);
    }
    let home = home_from_environment(bytes.get(offset..)?)?;
    Some((args.join(" "), home))
}

#[cfg(target_os = "macos")]
fn started(pid: u32) -> Option<(u64, u64)> {
    let pid = i32::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: buffer has the exact native structure size; read only on full success.
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if read != size {
        return None;
    }
    let info = unsafe { info.assume_init() };
    if info.pbi_pid != pid as u32 {
        return None;
    }
    Some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

#[cfg(target_os = "macos")]
pub(super) fn read(pid: u32) -> Option<Snapshot> {
    let initial = started(pid)?;
    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        i32::try_from(pid).ok()?,
    ];
    let mut bytes = vec![0u8; MAX_BYTES];
    let mut length = bytes.len();
    // SAFETY: sysctl receives a bounded valid byte buffer, no input mutation data.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            bytes.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || length > bytes.len() {
        return None;
    }
    let (command, home) = parse_procargs(&bytes[..length])?;
    if started(pid)? != initial {
        return None;
    }
    Some(Snapshot {
        command,
        home,
        started: initial,
    })
}

#[cfg(target_os = "linux")]
fn bounded_read(path: &str) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= MAX_BYTES).then_some(bytes)
}

#[cfg(target_os = "linux")]
fn started(pid: u32) -> Option<(u64, u64)> {
    let bytes = bounded_read(&format!("/proc/{pid}/stat"))?;
    let text = std::str::from_utf8(&bytes).ok()?;
    // comm may itself contain spaces and parentheses. Field 22 is starttime.
    let (_, rest) = text.rsplit_once(')')?;
    Some((rest.split_whitespace().nth(19)?.parse().ok()?, 0))
}

#[cfg(target_os = "linux")]
pub(super) fn read(pid: u32) -> Option<Snapshot> {
    let initial = started(pid)?;
    let bytes = bounded_read(&format!("/proc/{pid}/cmdline"))?;
    if bytes.last() != Some(&0) {
        return None;
    }
    let command = bytes[..bytes.len() - 1]
        .split(|byte| *byte == 0)
        .map(std::str::from_utf8)
        .collect::<Result<Vec<_>, _>>()
        .ok()?
        .join(" ");
    let home = home_from_environment(&bounded_read(&format!("/proc/{pid}/environ"))?)?;
    if started(pid)? != initial {
        return None;
    }
    Some(Snapshot {
        command,
        home,
        started: initial,
    })
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn read(_pid: u32) -> Option<Snapshot> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn environment_preserves_spaces_and_rejects_ambiguous_or_truncated_values() {
        assert_eq!(
            home_from_environment(b"TOKEN=ignored\0DSH_HOME=/tmp/user space/.dsh\0"),
            Some(Some(PathBuf::from("/tmp/user space/.dsh")))
        );
        assert_eq!(home_from_environment(b"OTHER=1\0"), Some(None));
        for bytes in [
            b"DSH_HOME=\0".as_slice(),
            b"DSH_HOME=relative\0",
            b"DSH_HOME=/a",
            b"DSH_HOME=/a\0DSH_HOME=/b\0",
            b"DSH_HOME=/a\0DSH_HOME=/a\0",
            b"DSH_HOME=/\xff\0",
        ] {
            assert!(home_from_environment(bytes).is_none());
        }
        assert!(home_from_environment(&vec![0; MAX_BYTES + 1]).is_none());
    }
    #[test]
    fn procargs_uses_argc_and_ignores_home_like_arguments() {
        let mut bytes = 3i32.to_ne_bytes().to_vec();
        bytes.extend_from_slice(b"/bin/node\0\0node\0DSH_HOME=/wrong\0\0TOKEN=ignored\0DSH_HOME=/tmp/user space/.dsh\0\0");
        let (command, home) = parse_procargs(&bytes).unwrap();
        assert_eq!(command, "node DSH_HOME=/wrong ");
        assert_eq!(home, Some(PathBuf::from("/tmp/user space/.dsh")));
        assert!(parse_procargs(&bytes[..8]).is_none());
        bytes[..4].copy_from_slice(&(-1i32).to_ne_bytes());
        assert!(parse_procargs(&bytes).is_none());
        assert!(parse_procargs(&[0; 3]).is_none());
    }
}
