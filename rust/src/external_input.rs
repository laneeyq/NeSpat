// Only seize HID interfaces. No input callbacks are installed and no reports are read.
use crate::{Entry, IOServiceMatching};
use core_foundation::{
    base::{CFRelease, CFTypeRef},
    boolean::CFBoolean,
    number::CFNumber,
    string::CFString,
};
use std::{
    collections::{HashMap, HashSet},
    ffi::c_void,
    ptr,
};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOServiceGetMatchingServices(port: u32, matching: *mut c_void, iter: *mut u32) -> i32;
    fn IOIteratorNext(iter: u32) -> u32;
    fn IORegistryEntryGetRegistryEntryID(service: u32, id: *mut u64) -> i32;
    fn IOHIDDeviceCreate(allocator: *const c_void, service: u32) -> CFTypeRef;
    fn IOHIDDeviceConformsTo(device: CFTypeRef, page: u32, usage: u32) -> u8;
    fn IOHIDDeviceOpen(device: CFTypeRef, options: u32) -> i32;
    fn IOHIDDeviceClose(device: CFTypeRef, options: u32) -> i32;
}

pub(super) fn eligible(transport: &str, builtin: bool, page: i64, usage: i64) -> bool {
    !builtin
        && matches!(transport, "USB" | "Bluetooth" | "Bluetooth Low Energy")
        && matches!((page, usage), (1, 1 | 2 | 6 | 7) | (12, 1))
}

// Consumer-control interfaces on keyboards may be separate. Leave standalone
// headset, monitor and remote-control interfaces alone.
pub(super) fn capture_interface(pointer_or_keyboard: bool, consumer: bool, related: bool) -> bool {
    pointer_or_keyboard || (consumer && related)
}

fn number(entry: &Entry, key: &str) -> Option<i64> {
    entry.property(key)?.downcast::<CFNumber>()?.to_i64()
}
fn string(entry: &Entry, key: &str) -> Option<String> {
    Some(entry.property(key)?.downcast::<CFString>()?.to_string())
}

fn physical_device(entry: &Entry, transport: &str) -> Option<(String, i64, i64, String)> {
    let connection = if transport == "USB" {
        number(entry, "LocationID").filter(|v| *v != 0)?.to_string()
    } else {
        string(entry, "DeviceAddress")
            .or_else(|| string(entry, "SerialNumber"))
            .filter(|s| !s.is_empty())?
    };
    Some((
        transport.into(),
        number(entry, "VendorID")?,
        number(entry, "ProductID")?,
        connection,
    ))
}

struct Device(CFTypeRef);
impl Device {
    fn seize(entry: &Entry) -> Option<Self> {
        unsafe {
            let device = IOHIDDeviceCreate(ptr::null(), entry.0);
            if device.is_null() {
                return None;
            }
            if IOHIDDeviceOpen(device, 1) != 0 {
                CFRelease(device);
                return None;
            }
            Some(Self(device))
        }
    }
}
fn consumer_contains_input(entry: &Entry) -> bool {
    unsafe {
        let device = IOHIDDeviceCreate(ptr::null(), entry.0);
        if device.is_null() {
            return false;
        }
        let input = [1, 2, 6, 7]
            .into_iter()
            .any(|usage| IOHIDDeviceConformsTo(device, 1, usage) != 0);
        CFRelease(device);
        input
    }
}
impl Drop for Device {
    fn drop(&mut self) {
        unsafe {
            IOHIDDeviceClose(self.0, 1);
            CFRelease(self.0);
        }
    }
}
#[derive(Default)]
pub(super) struct Inputs {
    devices: HashMap<u64, Device>,
}
impl Inputs {
    pub fn refresh(&mut self) -> bool {
        let mut iter = 0;
        let matching = unsafe { IOServiceMatching(c"IOHIDDevice".as_ptr()) };
        if matching.is_null()
            || unsafe { IOServiceGetMatchingServices(0, matching, &mut iter) } != 0
        {
            self.devices.clear();
            return false;
        }
        let iter = Entry(iter);
        let mut present = HashSet::new();
        let mut interfaces = Vec::new();
        let mut input_devices = HashSet::new();
        let mut complete = true;
        loop {
            let raw = unsafe { IOIteratorNext(iter.0) };
            if raw == 0 {
                break;
            }
            let entry = Entry(raw);
            let transport = string(&entry, "Transport").unwrap_or_default();
            let builtin = entry.property("Built-In").is_some_and(|v| {
                v.downcast::<CFBoolean>()
                    .map(bool::from)
                    .or_else(|| v.downcast::<CFNumber>()?.to_i64().map(|n| n != 0))
                    .unwrap_or(true)
            });
            let page = number(&entry, "PrimaryUsagePage").unwrap_or(-1);
            let usage = number(&entry, "PrimaryUsage").unwrap_or(-1);
            if !eligible(&transport, builtin, page, usage) {
                continue;
            }
            let physical = physical_device(&entry, &transport);
            let input = page == 1 || consumer_contains_input(&entry);
            if input {
                if let Some(key) = physical.as_ref() {
                    input_devices.insert(key.clone());
                }
            }
            interfaces.push((entry, input, page == 12, physical));
        }
        for (entry, input, consumer, physical) in interfaces {
            if !capture_interface(
                input,
                consumer,
                physical.is_some_and(|key| input_devices.contains(&key)),
            ) {
                continue;
            }
            let mut id = 0;
            if unsafe { IORegistryEntryGetRegistryEntryID(entry.0, &mut id) } != 0 {
                complete = false;
                continue;
            }
            present.insert(id);
            if let std::collections::hash_map::Entry::Vacant(slot) = self.devices.entry(id) {
                if let Some(device) = Device::seize(&entry) {
                    slot.insert(device);
                } else {
                    complete = false;
                }
            }
        }
        self.devices.retain(|id, _| present.contains(id));
        complete
    }
}
