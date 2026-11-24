// IOPMrootDomain posts clamshell changes as general interest notifications.
// The callback only wakes the worker; it always reads the current lid state.
use crate::Entry;
use core_foundation::runloop::{
    kCFRunLoopCommonModes, CFRunLoopAddSource, CFRunLoopGetMain, CFRunLoopRemoveSource,
    CFRunLoopSourceRef,
};
use std::{
    ffi::{c_char, c_void},
    ptr,
};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IONotificationPortCreate(port: u32) -> *mut c_void;
    fn IONotificationPortDestroy(port: *mut c_void);
    fn IONotificationPortGetRunLoopSource(port: *mut c_void) -> CFRunLoopSourceRef;
    fn IOServiceAddInterestNotification(
        port: *mut c_void,
        service: u32,
        interest: *const c_char,
        callback: extern "C" fn(*mut c_void, u32, u32, *mut c_void),
        context: *mut c_void,
        notifier: *mut u32,
    ) -> i32;
}
extern "C" fn changed(_: *mut c_void, _: u32, _: u32, _: *mut c_void) {
    crate::display_guard::wake_worker();
}
pub(super) struct LidNotifications {
    port: *mut c_void,
    source: CFRunLoopSourceRef,
    notifier: Option<Entry>,
}
impl LidNotifications {
    pub fn register() -> Option<Self> {
        let root = Entry::matching(c"IOPMrootDomain")?;
        unsafe {
            let port = IONotificationPortCreate(0);
            if port.is_null() {
                return None;
            }
            let source = IONotificationPortGetRunLoopSource(port);
            let mut n = 0;
            if source.is_null()
                || IOServiceAddInterestNotification(
                    port,
                    root.0,
                    c"IOGeneralInterest".as_ptr(),
                    changed,
                    ptr::null_mut(),
                    &mut n,
                ) != 0
            {
                IONotificationPortDestroy(port);
                return None;
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            Some(Self {
                port,
                source,
                notifier: Some(Entry(n)),
            })
        }
    }
}
impl Drop for LidNotifications {
    fn drop(&mut self) {
        unsafe {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
            drop(self.notifier.take());
            IONotificationPortDestroy(self.port);
        }
    }
}
