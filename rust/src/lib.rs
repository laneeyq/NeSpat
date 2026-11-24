use core_foundation::{
    array::CFArray,
    base::{CFType, CFTypeRef, TCFType},
    dictionary::CFDictionary,
    number::CFNumber,
    string::{CFString, CFStringRef},
};
use std::{ffi::c_void, ptr};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOServiceMatching(name: *const i8) -> *mut c_void;
    fn IOServiceGetMatchingService(port: u32, matching: *mut c_void) -> u32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IORegistryEntryCreateCFProperty(
        entry: u32,
        key: CFStringRef,
        allocator: *const c_void,
        options: u32,
    ) -> CFTypeRef;
}

struct Entry(u32);
impl Drop for Entry {
    fn drop(&mut self) {
        unsafe { IOObjectRelease(self.0) };
    }
}
impl Entry {
    fn matching(name: &std::ffi::CStr) -> Option<Self> {
        let matching = unsafe { IOServiceMatching(name.as_ptr()) };
        if matching.is_null() {
            return None;
        }
        let entry = unsafe { IOServiceGetMatchingService(0, matching) };
        (entry != 0).then(|| Entry(entry))
    }
    fn property(&self, key: &str) -> Option<CFType> {
        let key = CFString::new(key);
        let value = unsafe {
            IORegistryEntryCreateCFProperty(self.0, key.as_concrete_TypeRef(), ptr::null(), 0)
        };
        owned(value)
    }
}
fn owned(value: CFTypeRef) -> Option<CFType> {
    if value.is_null() {
        None
    } else {
        Some(unsafe { CFType::wrap_under_create_rule(value) })
    }
}

#[repr(C)]
#[derive(Debug)]
pub struct BatteryDetails {
    pub cycles: i64,
    pub design: i64,
    pub full: i64,
    pub remaining: i64,
}
#[no_mangle]
pub extern "C" fn nespat_battery_details() -> BatteryDetails {
    let device = Entry::matching(c"AppleSmartBattery");
    let data = device
        .as_ref()
        .and_then(|d| d.property("BatteryData"))
        .and_then(|v| v.downcast::<CFDictionary>());
    let read = |key: &str, min: i64| {
        let field = device.as_ref().and_then(|d| d.property(key)).or_else(|| {
            let key = CFString::new(key);
            data.as_ref()?
                .find(key.as_CFTypeRef())
                .map(|p| unsafe { CFType::wrap_under_get_rule(*p) })
        })?;
        field.downcast::<CFNumber>()?.to_i64().filter(|v| *v >= min)
    };
    BatteryDetails {
        cycles: read("CycleCount", 0).unwrap_or(-1),
        design: read("DesignCapacity", 1).unwrap_or(-1),
        full: read("NominalChargeCapacity", 1)
            .or_else(|| read("AppleRawMaxCapacity", 1))
            .unwrap_or(-1),
        remaining: read("AppleRawCurrentCapacity", 0).unwrap_or(-1),
    }
}

struct Hid {
    create: unsafe extern "C" fn(*const c_void) -> CFTypeRef,
    matching: unsafe extern "C" fn(CFTypeRef, *const c_void) -> i32,
    services: unsafe extern "C" fn(CFTypeRef) -> CFTypeRef,
    property: unsafe extern "C" fn(CFTypeRef, CFStringRef) -> CFTypeRef,
    event: unsafe extern "C" fn(CFTypeRef, i64, i32, i64) -> CFTypeRef,
    value: unsafe extern "C" fn(CFTypeRef, i32) -> f64,
}
impl Hid {
    fn load() -> Option<Self> {
        // Private symbols vary by OS release. Missing functions mean missing readings.
        macro_rules! sym {
            ($s:literal) => {{
                let p =
                    unsafe { libc::dlsym(libc::RTLD_DEFAULT, concat!($s, "\0").as_ptr().cast()) };
                if p.is_null() {
                    return None;
                }
                unsafe { std::mem::transmute(p) }
            }};
        }
        Some(Self {
            create: sym!("IOHIDEventSystemClientCreate"),
            matching: sym!("IOHIDEventSystemClientSetMatching"),
            services: sym!("IOHIDEventSystemClientCopyServices"),
            property: sym!("IOHIDServiceClientCopyProperty"),
            event: sym!("IOHIDServiceClientCopyEvent"),
            value: sym!("IOHIDEventGetFloatValue"),
        })
    }
    fn sample(&self, mut visit: impl FnMut(String, f64)) -> Option<()> {
        let client = owned(unsafe { (self.create)(ptr::null()) })?;
        let filter = CFDictionary::from_CFType_pairs(&[
            (CFString::new("PrimaryUsagePage"), CFNumber::from(0xff00)),
            (CFString::new("PrimaryUsage"), CFNumber::from(5)),
        ]);
        unsafe { (self.matching)(client.as_CFTypeRef(), filter.as_CFTypeRef()) };
        let services =
            owned(unsafe { (self.services)(client.as_CFTypeRef()) })?.downcast::<CFArray>()?;
        let product = CFString::new("Product");
        for raw in services.iter() {
            let service = *raw;
            let Some(name) =
                owned(unsafe { (self.property)(service, product.as_concrete_TypeRef()) })
                    .and_then(|v| v.downcast::<CFString>())
            else {
                continue;
            };
            let Some(event) = owned(unsafe { (self.event)(service, 15, 0, 0) }) else {
                continue;
            };
            let value = unsafe { (self.value)(event.as_CFTypeRef(), 15 << 16) };
            visit(name.to_string(), value);
        }
        Some(())
    }
}
fn chip_channel(name: &str, value: f64) -> bool {
    name.strip_prefix("PMU tdie")
        .is_some_and(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()))
        && value > 0.0
        && value < 150.0
}
#[no_mangle]
pub extern "C" fn nespat_chip_temperature() -> f64 {
    let mut maximum = f64::NAN;
    if let Some(hid) = Hid::load() {
        hid.sample(|name, value| {
            if chip_channel(&name, value) {
                maximum = maximum.max(value);
            }
        });
    }
    maximum
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_die_channels_enter_power_decisions() {
        for (n, t) in [
            ("PMU tcal", 100.),
            ("PMU tdie", 90.),
            ("PMU tdie1", f64::NAN),
            ("PMU tdie2", 150.),
            ("PMU tdie-1", 96.),
        ] {
            assert!(!chip_channel(n, t));
        }
        assert!(chip_channel("PMU tdie12", 95.0));
    }
}

pub mod policy;

pub mod updates;

mod stats;

mod observation;

mod automatic;
mod battery;
mod battery_panel;
mod duration_control;
mod format;
mod journal;
mod login;
mod recovery;
mod request;
mod setter;
mod signing;
mod status_item;
mod xpc;

mod wire;

mod transport;

mod host;

mod pulse;

mod authority;

mod profile;

pub mod client;

mod session;

pub mod driver;
pub mod panel;
pub mod panel_cli;
mod panel_meter;
mod panel_preferences;
mod panel_readings;
mod panel_view;
pub mod panel_worker;
mod service_engine;
pub mod service_host;
mod service_listener;
mod service_platform;
mod service_record;
mod service_recovery;
mod service_store;

mod display_guard;
mod external_input;

mod lid_notifications;
mod display_layout;
mod display_reconnect;
