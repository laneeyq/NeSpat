// The opened file description serializes helper and watchdog setters. The child
// inherits it on stdin so the lock survives a crash or timeout in the parent.
use std::{
    fs::{File, OpenOptions},
    io,
    os::{
        fd::{AsRawFd, BorrowedFd, IntoRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    process::{Command, Stdio},
    thread,
    time::Duration,
};

const LOCK: &str = "/Library/Application Support/NeSpatPrivileged/State/setter.lock";
extern "C" {
    fn acl_get_fd_np(fd: i32, kind: i32) -> *mut libc::c_void;
    fn acl_free(acl: *mut libc::c_void) -> i32;
    fn clock_gettime_nsec_np(clock: libc::clockid_t) -> u64;
}
fn lock_file(create: bool) -> io::Result<File> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let file = OpenOptions::new()
        .read(true)
        .write(create)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(LOCK)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.nlink() != 1 || meta.uid() != 0 || meta.mode() & 0o077 != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), 0x100) };
    if !acl.is_null() {
        unsafe {
            acl_free(acl);
        }
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    if io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(file)
}

#[no_mangle]
pub extern "C" fn nespat_setter_ready() -> bool {
    lock_file(true).is_ok()
}

#[no_mangle]
pub extern "C" fn nespat_setter_lock() -> i32 {
    let Ok(file) = lock_file(false) else {
        return -1;
    };
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return -1;
    }
    file.into_raw_fd()
}

fn now() -> u64 {
    unsafe { clock_gettime_nsec_np(libc::CLOCK_MONOTONIC_RAW) }
}
#[no_mangle]
pub unsafe extern "C" fn nespat_setter_run(fd: i32, disabled: bool) -> bool {
    if fd < 0 || libc::geteuid() != 0 {
        return false;
    }
    let Ok(input) = BorrowedFd::borrow_raw(fd).try_clone_to_owned() else {
        return false;
    };
    let start = now();
    if start == 0 {
        return false;
    }
    let Ok(mut child) = Command::new("/usr/bin/pmset")
        .args(["-a", "disablesleep", if disabled { "1" } else { "0" }])
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::from(input))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None)
                if now()
                    .checked_sub(start)
                    .is_some_and(|elapsed| elapsed < 3_000_000_000) =>
            {
                thread::sleep(Duration::from_millis(20));
            }
            _ => {
                libc::kill(child.id() as i32, libc::SIGTERM);
                // Reap asynchronously. The child's own lock remains until it exits.
                let _ = thread::Builder::new()
                    .name("power-reaper".into())
                    .spawn(move || child.wait());
                return false;
            }
        }
    }
}
