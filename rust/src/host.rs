use crate::request::uuid;
use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};
use std::{ffi::CStr, mem::MaybeUninit, ptr};

fn sysctl_text(key: &CStr) -> Option<Vec<u8>> {
    let mut bytes = [0u8; 128];
    let mut len = bytes.len();
    let status = unsafe {
        libc::sysctlbyname(
            key.as_ptr(),
            bytes.as_mut_ptr().cast(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if status != 0 || !(2..=bytes.len()).contains(&len) || bytes[len - 1] != 0 {
        return None;
    }
    Some(bytes[..len - 1].to_vec())
}
pub fn boot() -> Option<[u8; 16]> {
    uuid(std::str::from_utf8(&sysctl_text(c"kern.bootsessionuuid")?).ok()?)
}
#[no_mangle]
pub extern "C" fn nespat_boot(out: &mut [u8; 16]) -> bool {
    let Some(value) = boot() else {
        return false;
    };
    *out = value;
    true
}
#[no_mangle]
pub unsafe extern "C" fn nespat_matches_host(model: CFStringRef, build: CFStringRef) -> bool {
    let matches = |key, text| {
        sysctl_text(key).as_deref()
            == Some(CFString::wrap_under_get_rule(text).to_string().as_bytes())
    };
    matches(c"hw.model", model) && matches(c"kern.osversion", build)
}
#[repr(C)]
pub struct ProcessStamp {
    uid: u32,
    seconds: u64,
    micros: u64,
}
#[no_mangle]
pub extern "C" fn nespat_snapshot(pid: i32, out: &mut ProcessStamp) -> i8 {
    if pid <= 0 {
        return -1;
    }
    let mut info = MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    let n = unsafe {
        *libc::__error() = 0;
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if n != size {
        return if std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            0
        } else {
            -1
        };
    }
    let info = unsafe { info.assume_init() };
    if info.pbi_pid != pid as u32
        || info.pbi_uid == 0
        || info.pbi_start_tvsec == 0
        || info.pbi_start_tvusec >= 1_000_000
    {
        return -1;
    }
    *out = ProcessStamp {
        uid: info.pbi_uid,
        seconds: info.pbi_start_tvsec,
        micros: info.pbi_start_tvusec,
    };
    1
}
#[no_mangle]
pub extern "C" fn nespat_continuous_seconds() -> f64 {
    let n = unsafe { crate::setter::clock_gettime_nsec_np(libc::CLOCK_MONOTONIC_RAW) };
    if n == 0 {
        f64::NAN
    } else {
        n as f64 / 1e9
    }
}
