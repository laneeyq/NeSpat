use super::{owned, Entry};
use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    boolean::CFBoolean,
    number::{CFNumber, CFNumberIsFloatType},
};
use std::{ffi::c_void, ptr};

#[link(name = "SystemConfiguration", kind = "framework")]
extern "C" {
    fn SCDynamicStoreCopyConsoleUser(
        store: *const c_void,
        uid: *mut u32,
        gid: *mut u32,
    ) -> CFTypeRef;
}

#[no_mangle]
pub extern "C" fn nespat_active_uid() -> u32 {
    let (mut uid, mut gid) = (0, 0);
    let name = owned(unsafe { SCDynamicStoreCopyConsoleUser(ptr::null(), &mut uid, &mut gid) });
    if name.is_some() && uid != u32::MAX {
        uid
    } else {
        0
    }
}

fn property(key: &str) -> Option<CFType> {
    Entry::matching(c"IOPMrootDomain")?.property(key)
}
fn flag(value: Option<&CFType>, allow_integer: bool) -> i8 {
    let Some(value) = value else {
        return -1;
    };
    if let Some(boolean) = value.downcast::<CFBoolean>() {
        return bool::from(boolean) as i8;
    }
    if allow_integer {
        if let Some(n) = value.downcast::<CFNumber>() {
            if unsafe { CFNumberIsFloatType(n.as_concrete_TypeRef()) } == 0 {
                match n.to_i64() {
                    Some(0) => return 0,
                    Some(1) => return 1,
                    _ => {}
                }
            }
        }
    }
    -1
}
#[no_mangle]
pub extern "C" fn nespat_lid_closed() -> i8 {
    flag(property("AppleClamshellState").as_ref(), false)
}
#[no_mangle]
pub extern "C" fn nespat_sleep_disabled() -> i8 {
    flag(property("SleepDisabled").as_ref(), true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn strict_types_for_lid_and_sleep_observation() {
        let one = CFNumber::from(1).as_CFType();
        let float = CFNumber::from(1.0).as_CFType();
        let boolean = CFBoolean::false_value().as_CFType();
        assert_eq!(flag(Some(&one), false), -1);
        assert_eq!(flag(Some(&one), true), 1);
        assert_eq!(flag(Some(&float), true), -1);
        assert_eq!(flag(Some(&boolean), false), 0);
        assert_eq!(flag(None, true), -1);
    }
}
