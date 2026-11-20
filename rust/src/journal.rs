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
    no_acl(fd)
}

fn no_acl(fd: RawFd) -> bool {
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

use base64::{engine::general_purpose::STANDARD, Engine as _};
use core_foundation::{
    base::TCFType,
    data::{CFData, CFDataRef},
    string::{CFString, CFStringRef},
};
use sha2::{Digest, Sha256};
use std::{mem::ManuallyDrop, ptr};

fn cf_data(bytes: &[u8]) -> CFDataRef {
    ManuallyDrop::new(CFData::from_buffer(bytes)).as_concrete_TypeRef()
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
#[no_mangle]
pub unsafe extern "C" fn nespat_journal_digest(bytes: CFDataRef) -> CFStringRef {
    ManuallyDrop::new(CFString::new(&digest(
        CFData::wrap_under_get_rule(bytes).bytes(),
    )))
    .as_concrete_TypeRef()
}
fn integrity(payload: &[u8]) -> Vec<u8> {
    format!(
        r#"{{"payload":"{}","sha256":"{}"}}"#,
        STANDARD.encode(payload),
        digest(payload)
    )
    .into_bytes()
}
#[no_mangle]
pub unsafe extern "C" fn nespat_journal_integrity(bytes: CFDataRef, unwrap: bool) -> CFDataRef {
    let raw = CFData::wrap_under_get_rule(bytes);
    let bytes = raw.bytes();
    if bytes.len() > MAX {
        return ptr::null();
    }
    if !unwrap {
        let out = integrity(bytes);
        return if out.len() <= MAX {
            cf_data(&out)
        } else {
            ptr::null()
        };
    }
    let parse = || {
        let obj: serde_json::Value = serde_json::from_slice(bytes).ok()?;
        let payload = STANDARD.decode(obj["payload"].as_str()?).ok()?;
        (bytes == integrity(&payload)).then(|| cf_data(&payload))
    };
    parse().unwrap_or(ptr::null())
}

fn open_file(fd: i32) -> Option<File> {
    if fd < 0 {
        None
    } else {
        Some(unsafe { File::from_raw_fd(fd) })
    }
}
pub(crate) fn trust_profile() -> Option<Vec<u8>> {
    let flags = libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
    let mut dir = open_file(unsafe { libc::open(c"/".as_ptr(), flags | libc::O_DIRECTORY) })?;
    for name in [
        c"Library",
        c"Application Support",
        c"NeSpatPrivileged",
        c"LocalTrust",
    ] {
        if !nespat_journal_check(dir.as_raw_fd(), true, 0) {
            return None;
        }
        dir = open_file(unsafe {
            libc::openat(dir.as_raw_fd(), name.as_ptr(), flags | libc::O_DIRECTORY)
        })?;
    }
    if !nespat_journal_check(dir.as_raw_fd(), true, 0) {
        return None;
    }
    let file = open_file(unsafe {
        libc::openat(
            dir.as_raw_fd(),
            c"profile.json".as_ptr(),
            flags | libc::O_NONBLOCK,
        )
    })?;
    use std::os::unix::fs::MetadataExt;
    let meta = file.metadata().ok()?;
    if !meta.is_file()
        || meta.uid() != 0
        || meta.mode() & 0o022 != 0
        || meta.nlink() != 1
        || meta.len() > 4096
        || !no_acl(file.as_raw_fd())
    {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(4097).read_to_end(&mut bytes).ok()?;
    (1..=4096).contains(&bytes.len()).then_some(bytes)
}

use std::os::fd::IntoRawFd;
#[repr(C)]
pub struct JournalFiles {
    directory: i32,
    lock: i32,
}
fn finish_open(directory: File, owner: u32) -> Option<JournalFiles> {
    if !nespat_journal_check(directory.as_raw_fd(), true, owner) {
        return None;
    }
    let lock = open_file(unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"lock".as_ptr(),
            libc::O_CREAT | libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            0o600 as libc::c_int,
        )
    })?;
    if !nespat_journal_check(lock.as_raw_fd(), false, owner) {
        return None;
    }
    Some(JournalFiles {
        directory: directory.into_raw_fd(),
        lock: lock.into_raw_fd(),
    })
}
fn open_journal(path: &str, owner: u32) -> Option<JournalFiles> {
    if !path.starts_with('/') {
        return None;
    }
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
    let mut directory = open_file(unsafe { libc::open(c"/".as_ptr(), flags) })?;
    for part in path.split('/').filter(|s| !s.is_empty()) {
        if part == ".." || !nespat_journal_check(directory.as_raw_fd(), true, owner) {
            return None;
        }
        let name = CString::new(part).ok()?;
        directory =
            open_file(unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) })?;
    }
    finish_open(directory, owner)
}
#[no_mangle]
pub unsafe extern "C" fn nespat_open_journal(
    path: CFStringRef,
    owner: u32,
    out: &mut JournalFiles,
) -> bool {
    let Some(files) = open_journal(&CFString::wrap_under_get_rule(path).to_string(), owner) else {
        return false;
    };
    *out = files;
    true
}
#[no_mangle]
pub extern "C" fn nespat_open_pinned_journal(fd: i32, owner: u32, out: &mut JournalFiles) -> bool {
    let Some(files) = open_file(unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) })
        .and_then(|file| finish_open(file, owner))
    else {
        return false;
    };
    *out = files;
    true
}
