// All names are relative to the already pinned journal directory. The caller
// holds the journal lock throughout validation, replacement and directory fsync.
use std::{
    ffi::{CStr, CString},
    fs::File,
    io::{Read, Write},
    mem::MaybeUninit,
    os::fd::{AsRawFd, FromRawFd, RawFd},
    slice,
};
const MAX: usize = 8192;
const AUTHORITY: &CStr = c"authority.json";
extern "C" {
    fn acl_get_fd_np(fd: i32, kind: i32) -> *mut libc::c_void;
    fn acl_free(acl: *mut libc::c_void) -> i32;
}

#[no_mangle]
pub extern "C" fn nespat_journal_check(fd: RawFd, directory: bool, uid: u32) -> bool {
    let mut stat = MaybeUninit::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return false;
    }
    let stat = unsafe { stat.assume_init() };
    let kind = stat.st_mode & libc::S_IFMT;
    if stat.st_uid != uid || stat.st_mode & 0o022 != 0 {
        return false;
    }
    if directory {
        if kind != libc::S_IFDIR {
            return false;
        }
    } else if kind != libc::S_IFREG || stat.st_nlink != 1 || stat.st_mode & 0o077 != 0 {
        return false;
    }
    // Darwin reports ENOENT for an absent extended ACL; reject all other errors.
    unsafe {
        *libc::__error() = 0;
    }
    let acl = unsafe { acl_get_fd_np(fd, 0x100) };
    if acl.is_null() {
        std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
    } else {
        unsafe {
            acl_free(acl);
        }
        false
    }
}

// Return -2 only for the initial missing file, distinct from all read errors.
#[no_mangle]
pub unsafe extern "C" fn nespat_journal_read(
    dir: RawFd,
    uid: u32,
    out: *mut u8,
    capacity: usize,
) -> i32 {
    if out.is_null() || capacity < MAX + 1 {
        return -1;
    }
    let fd = libc::openat(
        dir,
        AUTHORITY.as_ptr(),
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
    );
    if fd < 0 {
        return if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            -2
        } else {
            -1
        };
    }
    let mut file = File::from_raw_fd(fd);
    if !nespat_journal_check(fd, false, uid) {
        return -1;
    }
    let buf = slice::from_raw_parts_mut(out, MAX + 1);
    let mut used = 0;
    while used <= MAX {
        match file.read(&mut buf[used..]) {
            Ok(0) => return used as i32,
            Ok(n) => used += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return -1,
        }
    }
    -1
}

struct Staging<'a> {
    dir: RawFd,
    name: &'a CStr,
}
impl Drop for Staging<'_> {
    fn drop(&mut self) {
        unsafe {
            libc::unlinkat(self.dir, self.name.as_ptr(), 0);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn nespat_journal_write(
    dir: RawFd,
    uid: u32,
    input: *const u8,
    len: usize,
) -> bool {
    if input.is_null() || len == 0 || len > MAX {
        return false;
    }
    let mut random = [0u8; 16];
    libc::arc4random_buf(random.as_mut_ptr().cast(), random.len());
    let hex = u128::from_be_bytes(random);
    let name = CString::new(format!(".authority-{hex:032x}")).expect("hex name");
    let fd = libc::openat(
        dir,
        name.as_ptr(),
        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0o600 as libc::c_int,
    );
    if fd < 0 {
        return false;
    }
    let _stage = Staging { dir, name: &name };
    let mut file = File::from_raw_fd(fd);
    nespat_journal_check(file.as_raw_fd(), false, uid)
        && file.write_all(slice::from_raw_parts(input, len)).is_ok()
        && file.sync_all().is_ok()
        && libc::renameat(dir, name.as_ptr(), dir, AUTHORITY.as_ptr()) == 0
        && libc::fsync(dir) == 0
}
