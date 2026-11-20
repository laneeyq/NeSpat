use super::owned;
use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    dictionary::CFDictionary,
    number::CFNumber,
    string::{CFString, CFStringRef},
    url::CFURLRef,
};
use std::ptr;

// Security.framework's Create/Copy return retained CF objects. Keep the same
// SecStaticCode alive for validity and entitlement inspection.
#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecRequirementCreateWithString(text: CFStringRef, flags: u32, out: *mut CFTypeRef) -> i32;
    fn SecStaticCodeCreateWithPath(path: CFURLRef, flags: u32, out: *mut CFTypeRef) -> i32;
    fn SecStaticCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> i32;
    fn SecCodeCopySigningInformation(code: CFTypeRef, flags: u32, out: *mut CFTypeRef) -> i32;
    static kSecCodeInfoFlags: CFStringRef;
    static kSecCodeInfoEntitlementsDict: CFStringRef;
}
fn created(f: impl FnOnce(*mut CFTypeRef) -> i32) -> Option<CFType> {
    let mut value = ptr::null();
    let status = f(&mut value);
    let value = owned(value);
    if status == 0 {
        value
    } else {
        None
    }
}
fn requirement(text: CFStringRef) -> Option<CFType> {
    if text.is_null() {
        return None;
    }
    created(|out| unsafe { SecRequirementCreateWithString(text, 0, out) })
}
#[no_mangle]
pub extern "C" fn nespat_valid_requirement(text: CFStringRef) -> bool {
    requirement(text).is_some()
}

fn field(dict: &CFDictionary, key: CFStringRef) -> Option<CFType> {
    dict.find(key.cast())
        .map(|v| unsafe { CFType::wrap_under_get_rule(*v) })
}
fn hardened(code: &CFType) -> Option<bool> {
    let info =
        created(|out| unsafe { SecCodeCopySigningInformation(code.as_CFTypeRef(), 1 << 1, out) })?
            .downcast::<CFDictionary>()?;
    let flags = field(&info, unsafe { kSecCodeInfoFlags })?
        .downcast::<CFNumber>()?
        .to_i64()?;
    if flags & 0x10000 == 0 {
        return Some(false);
    }
    let Some(raw) = field(&info, unsafe { kSecCodeInfoEntitlementsDict }) else {
        return Some(true);
    };
    let entitlements = raw.downcast::<CFDictionary>()?;
    Some(
        [
            "com.apple.security.get-task-allow",
            "get-task-allow",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.allow-unsigned-executable-memory",
        ]
        .iter()
        .all(|key| !entitlements.contains_key(&CFString::new(key).as_CFTypeRef())),
    )
}
#[no_mangle]
pub extern "C" fn nespat_matches_code(
    url: CFURLRef,
    text: CFStringRef,
    require_hardened: bool,
) -> bool {
    if url.is_null() {
        return false;
    }
    let Some(req) = requirement(text) else {
        return false;
    };
    let Some(code) = created(|out| unsafe { SecStaticCodeCreateWithPath(url, 0, out) }) else {
        return false;
    };
    let status =
        unsafe { SecStaticCodeCheckValidity(code.as_CFTypeRef(), 1 << 4, req.as_CFTypeRef()) };
    status == 0 && (!require_hardened || hardened(&code) == Some(true))
}

use std::mem::ManuallyDrop;
pub(crate) fn pin(hash: &str, id: &str) -> Option<String> {
    if hash.len() != 40
        || !hash.bytes().all(|b| b.is_ascii_hexdigit())
        || !(1..=255).contains(&id.len())
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_'))
    {
        return None;
    }
    let text = format!(
        "cdhash H\"{}\" and identifier \"{id}\"",
        hash.to_ascii_lowercase()
    );
    nespat_valid_requirement(CFString::new(&text).as_concrete_TypeRef()).then_some(text)
}
#[no_mangle]
pub unsafe extern "C" fn nespat_code_pin(hash: CFStringRef, id: CFStringRef) -> CFStringRef {
    pin(
        &CFString::wrap_under_get_rule(hash).to_string(),
        &CFString::wrap_under_get_rule(id).to_string(),
    )
    .map_or(ptr::null(), |s| {
        ManuallyDrop::new(CFString::new(&s)).as_concrete_TypeRef()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, process::Command};
    fn accepts(path: &std::path::Path, requirement: &str, hardened: bool) -> bool {
        let url = core_foundation::url::CFURL::from_path(path, false).unwrap();
        nespat_matches_code(
            url.as_concrete_TypeRef(),
            CFString::new(requirement).as_concrete_TypeRef(),
            hardened,
        )
    }
    #[test]
    fn only_exact_hardened_signed_fixture_matches_its_pin() {
        let folder = tempfile::tempdir().unwrap();
        let binary = folder.path().join("signed");
        fs::copy("/bin/echo", &binary).unwrap();
        let sign = |runtime: bool| {
            let mut cmd = Command::new("/usr/bin/codesign");
            cmd.args(["-fs", "-", "--identifier", "local.nespat.fixture"]);
            if runtime {
                cmd.args(["--options", "runtime"]);
            }
            assert!(cmd.arg(&binary).output().unwrap().status.success());
            let out = Command::new("/usr/bin/codesign")
                .args(["-dv", "--verbose=4"])
                .arg(&binary)
                .output()
                .unwrap();
            let text = String::from_utf8(out.stderr).unwrap();
            text.lines()
                .find_map(|l| l.strip_prefix("CDHash="))
                .unwrap()
                .to_owned()
        };
        let hash = sign(true);
        let req = pin(&hash, "local.nespat.fixture").unwrap();
        assert!(accepts(&binary, &req, true));
        assert!(!accepts(
            &binary,
            &pin(&hash, "local.nespat.other").unwrap(),
            true
        ));
        assert!(!accepts(
            &binary,
            &pin(&"0".repeat(40), "local.nespat.fixture").unwrap(),
            true
        ));
        let bare = pin(&sign(false), "local.nespat.fixture").unwrap();
        assert!(accepts(&binary, &bare, false));
        assert!(!accepts(&binary, &bare, true));
        assert!(!accepts(&binary, &req, true));
        fs::write(&binary, b"unsigned").unwrap();
        assert!(!accepts(&binary, &bare, false));
    }
    #[test]
    fn malformed_pins_and_identifiers_are_rejected() {
        for h in ["", "ff", &"f".repeat(39), &"f".repeat(41), &"g".repeat(40)] {
            assert!(pin(h, "app").is_none());
        }
        for id in ["", "invalid name", "a/b", "a\"b", &"a".repeat(256)] {
            assert!(pin(&"a".repeat(40), id).is_none());
        }
    }
}
