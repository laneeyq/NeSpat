#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn largest_intersection_uses_correct_monitor_on_negative_desktop() {
        let r = Rect {
            x: -75.,
            y: 30.,
            w: 100.,
            h: 50.,
        };
        let left = Rect {
            x: -200.,
            y: 0.,
            w: 200.,
            h: 200.,
        };
        let right = Rect { x: 0., ..left };
        assert!(r.overlap(left) > r.overlap(right));
        assert_eq!(r.relative_to(left).restored(left, right).x, 125.);
        assert_eq!(r.overlap(Rect { x: 200., ..left }), 0.);
    }
    #[test]
    fn restored_window_fits_smaller_monitor() {
        let window = Rect {
            x: 150.,
            y: 120.,
            w: 300.,
            h: 90.,
        };
        let screen = Rect {
            x: 100.,
            y: -100.,
            w: 200.,
            h: 100.,
        };
        assert_eq!(
            window.placed_on(screen),
            Rect {
                x: 100.,
                y: -90.,
                w: 200.,
                h: 90.
            }
        );
    }
}

use core_foundation::{
    array::CFArray,
    base::{CFType, CFTypeRef, TCFType},
    dictionary::CFDictionary,
    number::CFNumber,
    string::CFString,
    uuid::{CFUUIDCreateFromString, CFUUIDCreateString, CFUUIDRef},
};
use std::{collections::BTreeMap, ffi::c_void, ptr};

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub(super) struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}
impl Rect {
    fn valid(self) -> bool {
        [self.x, self.y, self.w, self.h]
            .iter()
            .all(|v| v.is_finite())
            && self.w > 0.
            && self.h > 0.
    }
    fn overlap(self, s: Self) -> f64 {
        ((self.x + self.w).min(s.x + s.w) - self.x.max(s.x)).max(0.)
            * ((self.y + self.h).min(s.y + s.h) - self.y.max(s.y)).max(0.)
    }
    fn relative_to(self, s: Self) -> Self {
        Self {
            x: self.x - s.x,
            y: self.y - s.y,
            ..self
        }
    }
    fn restored(self, old: Self, new: Self) -> Self {
        if old.w == new.w && old.h == new.h {
            Self {
                x: new.x + self.x,
                y: new.y + self.y,
                ..self
            }
        } else {
            self.placed_on(new)
        }
    }
    fn placed_on(self, s: Self) -> Self {
        let w = self.w.min(s.w);
        let h = self.h.min(s.h);
        Self {
            x: s.x + self.x.clamp(0., s.w - w),
            y: s.y + self.y.clamp(0., s.h - h),
            w,
            h,
        }
    }
}
#[derive(Clone, PartialEq)]
pub(super) struct Screen {
    pub id: u32,
    pub builtin: bool,
    pub rect: Rect,
}
pub(super) type Screens = BTreeMap<String, Screen>;
type Config = *mut c_void;
type Enable = unsafe extern "C" fn(Config, u32, bool) -> i32;
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGDisplayBounds(id: u32) -> Rect;
    fn CGDisplayIsBuiltin(id: u32) -> u32;
    fn CGDisplayIsOnline(id: u32) -> u32;
    fn CGDisplayCreateUUIDFromDisplayID(id: u32) -> CFUUIDRef;
    fn CGDisplayGetDisplayIDFromUUID(uuid: CFUUIDRef) -> u32;
    fn CGBeginDisplayConfiguration(config: *mut Config) -> i32;
    fn CGCompleteDisplayConfiguration(config: Config, option: u32) -> i32;
    fn CGCancelDisplayConfiguration(config: Config) -> i32;
    fn CGWindowListCopyWindowInfo(option: u32, relative: u32)
        -> core_foundation::array::CFArrayRef;
}
fn enable_fn() -> Option<Enable> {
    let p = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"CGSConfigureDisplayEnabled".as_ptr()) };
    (!p.is_null()).then(|| unsafe { std::mem::transmute::<*mut c_void, Enable>(p) })
}
pub(super) fn supported() -> bool {
    enable_fn().is_some()
}
fn uuid(id: u32) -> Option<String> {
    let u = crate::owned(unsafe { CGDisplayCreateUUIDFromDisplayID(id) }.cast())?;
    let s = unsafe { CFUUIDCreateString(ptr::null(), u.as_CFTypeRef().cast()) };
    (!s.is_null()).then(|| unsafe { CFString::wrap_under_create_rule(s) }.to_string())
}
pub(super) fn screens() -> Option<Screens> {
    let mut out = Screens::new();
    for id in crate::display_guard::online_ids()? {
        let rect = unsafe { CGDisplayBounds(id) };
        if !rect.valid() {
            return None;
        }
        if out
            .insert(
                uuid(id)?,
                Screen {
                    id,
                    builtin: unsafe { CGDisplayIsBuiltin(id) } != 0,
                    rect,
                },
            )
            .is_some()
        {
            return None;
        }
    }
    Some(out)
}
fn resolve(key: &str, last: u32) -> Option<u32> {
    if uuid(last).as_deref() == Some(key) {
        return Some(last);
    }
    let s = CFString::new(key);
    let u = crate::owned(
        unsafe { CFUUIDCreateFromString(ptr::null(), s.as_concrete_TypeRef()) }.cast(),
    )?;
    let id = unsafe { CGDisplayGetDisplayIDFromUUID(u.as_CFTypeRef().cast()) };
    (id != 0 && uuid(id).as_deref() == Some(key)).then_some(id)
}
pub(super) fn switch(key: &str, last: u32, on: bool) -> bool {
    let Some(id) = resolve(key, last) else {
        return false;
    };
    if unsafe { CGDisplayIsBuiltin(id) } != 0 {
        return false;
    }
    if on && unsafe { CGDisplayIsOnline(id) } != 0 {
        return true;
    }
    let Some(enable) = enable_fn() else {
        return false;
    };
    unsafe {
        let mut config = ptr::null_mut();
        if CGBeginDisplayConfiguration(&mut config) != 0 {
            return false;
        }
        if enable(config, id, on) != 0 {
            CGCancelDisplayConfiguration(config);
            return false;
        }
        CGCompleteDisplayConfiguration(config, 0) == 0 // kCGConfigureForAppOnly
    }
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: core_foundation::dictionary::CFDictionaryRef)
        -> bool;
    static kAXTrustedCheckOptionPrompt: core_foundation::string::CFStringRef;
    fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    fn AXUIElementSetMessagingTimeout(element: CFTypeRef, timeout: f32) -> i32;
    fn AXUIElementCopyAttributeValue(
        element: CFTypeRef,
        attr: core_foundation::string::CFStringRef,
        out: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementSetAttributeValue(
        element: CFTypeRef,
        attr: core_foundation::string::CFStringRef,
        value: CFTypeRef,
    ) -> i32;
    fn AXValueGetTypeID() -> usize;
    fn AXValueGetValue(value: CFTypeRef, kind: u32, data: *mut c_void) -> bool;
    fn AXValueCreate(kind: u32, data: *const c_void) -> CFTypeRef;
}
pub(super) fn trusted() -> bool {
    unsafe { AXIsProcessTrusted() }
}
pub(super) fn request_access_if_needed() {
    static REQUESTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if trusted()
        || !supported()
        || !screens().is_some_and(|ds| ds.values().any(|s| !s.builtin))
        || REQUESTED.swap(true, std::sync::atomic::Ordering::Relaxed)
    {
        return;
    }
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let options = CFDictionary::from_CFType_pairs(&[(
            key,
            core_foundation::boolean::CFBoolean::true_value(),
        )]);
        AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef());
    }
}
fn attribute(e: &CFType, key: &str) -> Option<CFType> {
    let mut value = ptr::null();
    (unsafe {
        AXUIElementCopyAttributeValue(
            e.as_CFTypeRef(),
            CFString::new(key).as_concrete_TypeRef(),
            &mut value,
        )
    } == 0)
        .then(|| crate::owned(value))
        .flatten()
}
fn pair(e: &CFType, key: &str, kind: u32) -> Option<[f64; 2]> {
    let value = attribute(e, key)?;
    if value.type_of() != unsafe { AXValueGetTypeID() } {
        return None;
    }
    let mut out = [0.; 2];
    unsafe { AXValueGetValue(value.as_CFTypeRef(), kind, out.as_mut_ptr().cast()) }.then_some(out)
}
fn set_pair(e: &CFType, key: &str, kind: u32, pair: [f64; 2]) -> bool {
    let Some(v) = crate::owned(unsafe { AXValueCreate(kind, pair.as_ptr().cast()) }) else {
        return false;
    };
    unsafe {
        AXUIElementSetAttributeValue(
            e.as_CFTypeRef(),
            CFString::new(key).as_concrete_TypeRef(),
            v.as_CFTypeRef(),
        ) == 0
    }
}
pub(super) struct Window {
    element: CFType,
    pub(super) screen: String,
    old: Rect,
    relative: Rect,
}
impl Window {
    pub fn restore(&self, displays: &Screens) {
        if let Some(s) = displays.get(&self.screen) {
            let r = self.relative.restored(self.old, s.rect);
            set_pair(&self.element, "AXPosition", 1, [r.x, r.y]);
            set_pair(&self.element, "AXSize", 2, [r.w, r.h]);
            set_pair(&self.element, "AXPosition", 1, [r.x, r.y]);
        }
    }
}
pub(super) fn snapshot(displays: &Screens) -> Option<Vec<Window>> {
    if !trusted() {
        return None;
    }
    let raw = unsafe { CGWindowListCopyWindowInfo(1 | 16, 0) };
    if raw.is_null() {
        return None;
    }
    let list: CFArray<CFType> = unsafe { CFArray::wrap_under_create_rule(raw) };
    let mut pids = std::collections::BTreeSet::new();
    for v in list.iter() {
        let Some(d) = v.downcast::<CFDictionary>() else {
            continue;
        };
        let num = |k: &str| {
            let raw = *d.find(CFString::new(k).as_CFTypeRef())?;
            unsafe { CFType::wrap_under_get_rule(raw) }
                .downcast::<CFNumber>()?
                .to_i64()
        };
        if num("kCGWindowLayer") == Some(0) {
            if let Some(pid) = num("kCGWindowOwnerPID") {
                pids.insert(pid as i32);
            }
        }
    }
    let mut windows = Vec::new();
    for pid in pids {
        let app = crate::owned(unsafe { AXUIElementCreateApplication(pid) })?;
        unsafe {
            AXUIElementSetMessagingTimeout(app.as_CFTypeRef(), 0.15);
        }
        let Some(arr) = attribute(&app, "AXWindows").and_then(|v| v.downcast::<CFArray>()) else {
            continue;
        };
        for raw in arr.iter() {
            let element = unsafe { CFType::wrap_under_get_rule(*raw) };
            unsafe {
                AXUIElementSetMessagingTimeout(element.as_CFTypeRef(), 0.15);
            }
            let flag = |key: &str| {
                attribute(&element, key)
                    .and_then(|v| v.downcast::<core_foundation::boolean::CFBoolean>())
                    .is_some_and(bool::from)
            };
            if flag("AXMinimized") || flag("AXFullScreen") {
                continue;
            }
            if attribute(&element, "AXSubrole")
                .and_then(|v| v.downcast::<CFString>())
                .map(|s| s.to_string())
                .as_deref()
                != Some("AXStandardWindow")
            {
                continue;
            }
            let (Some([x, y]), Some([w, h])) =
                (pair(&element, "AXPosition", 1), pair(&element, "AXSize", 2))
            else {
                continue;
            };
            let rect = Rect { x, y, w, h };
            if !rect.valid() {
                continue;
            }
            if let Some((key, s)) = displays
                .iter()
                .max_by(|(_, a), (_, b)| rect.overlap(a.rect).total_cmp(&rect.overlap(b.rect)))
            {
                if !s.builtin && rect.overlap(s.rect) > 0. {
                    windows.push(Window {
                        element,
                        screen: key.clone(),
                        old: s.rect,
                        relative: rect.relative_to(s.rect),
                    });
                }
            }
        }
    }
    Some(windows)
}
