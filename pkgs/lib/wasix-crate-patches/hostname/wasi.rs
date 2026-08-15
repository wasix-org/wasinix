#[cfg(feature = "set")]
use std::ffi::OsStr;
use std::ffi::OsString;
use std::io;
use std::os::wasi::ffi::OsStringExt;

// wasix-libc has no sysconf(_SC_HOST_NAME_MAX).
const _POSIX_HOST_NAME_MAX: usize = 255;

extern "C" {
    fn gethostname(name: *mut std::ffi::c_char, len: usize) -> std::ffi::c_int;
}

pub fn get() -> io::Result<OsString> {
    let mut buffer = vec![0u8; _POSIX_HOST_NAME_MAX + 1];

    let result = unsafe { gethostname(buffer.as_mut_ptr().cast(), _POSIX_HOST_NAME_MAX) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }

    // A name that does not fit is truncated without its trailing nul.
    let end = buffer
        .iter()
        .position(|&byte| byte == 0x00)
        .unwrap_or(buffer.len());
    buffer.truncate(end);

    Ok(OsString::from_vec(buffer))
}

#[cfg(feature = "set")]
pub fn set(_hostname: &OsStr) -> io::Result<()> {
    // wasix-libc declares sethostname but defines no symbol for it, so a call
    // fails at link time.
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "sethostname is not implemented on wasix",
    ))
}
