#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn list_only_connected_devices_preserving_real_zero_and_unknown() {
        let data = json!({"SPBluetoothDataType":[{"device_connected":[{"Mouse":{"device_minorType":"Mouse","device_batteryLevelMain":"0%"}},{"Headset":{"device_batteryLevelLeft":"28%","device_batteryLevelRight":"71%","device_batteryLevelCase":"101%"}},{"Keyboard":{"device_batteryLevelMain":"invalid"}}],"device_not_connected":[{"Old":{"device_batteryLevelMain":"99%"}}]}]});
        let rows = bluetooth(&data).unwrap();
        assert_eq!(
            rows.iter().map(|r| r.percent).collect::<Vec<_>>(),
            vec![Some(0), Some(28), Some(71), None]
        );
        assert!(rows[1].name.contains("лев"));
        assert!(bluetooth(&json!({})).is_none());
    }

    #[test]
    fn lamzu_accepts_only_correlated_well_formed_battery_responses() {
        let reply = [0xa1, 0, 2, 2, 0, 0x83, 0, 42];
        assert_eq!(lamzu_reply(&reply), Some((42, false)));
        let mut prefixed = vec![0];
        prefixed.extend(reply);
        assert_eq!(lamzu_reply(&prefixed), Some((42, false)));
        for i in [0, 1, 2, 3, 4, 5, 6, 7] {
            let mut bad = reply;
            bad[i] = 255;
            assert_eq!(lamzu_reply(&bad), None);
        }
    }
}

use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    dictionary::CFDictionary,
    number::CFNumber,
    set::{CFSet, CFSetRef},
    string::CFString,
};
use serde_json::Value;
use std::{
    cell::RefCell,
    ffi::c_void,
    process::Command,
    ptr,
    sync::mpsc::{channel, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Device {
    pub name: String,
    pub icon: &'static str,
    pub percent: Option<u8>,
    pub charging: bool,
}

fn percent(v: &Value) -> Option<u8> {
    let n = if let Some(n) = v.as_u64() {
        u8::try_from(n).ok()?
    } else {
        v.as_str()?
            .trim()
            .trim_end_matches('%')
            .trim()
            .parse()
            .ok()?
    };
    (n <= 100).then_some(n)
}
fn bluetooth(data: &Value) -> Option<Vec<Device>> {
    let controllers = data["SPBluetoothDataType"].as_array()?;
    if !controllers
        .iter()
        .any(|c| c.get("controller_properties").is_some() || c.get("device_connected").is_some())
    {
        return None;
    }
    let mut rows = Vec::new();
    for entry in controllers
        .iter()
        .filter_map(|c| c["device_connected"].as_array())
        .flatten()
    {
        for (name, info) in entry.as_object().into_iter().flatten() {
            let kind = format!(
                "{} {}",
                name,
                info["device_minorType"].as_str().unwrap_or("")
            )
            .to_lowercase();
            let icon = if kind.contains("airpods") {
                "airpodspro"
            } else if kind.contains("keyboard") {
                "keyboard"
            } else if kind.contains("mouse") || kind.contains("mx master") {
                "computermouse"
            } else if kind.contains("head") || kind.contains("audio") {
                "headphones"
            } else {
                "dot.radiowaves.left.and.right"
            };
            let mut components = false;
            for (key, label, symbol) in [
                ("device_batteryLevelLeft", "левый", icon),
                ("device_batteryLevelRight", "правый", icon),
                ("device_batteryLevelCase", "кейс", "airpods.chargingcase"),
            ] {
                if let Some(p) = percent(&info[key]) {
                    rows.push(Device {
                        name: format!("{name} · {label}"),
                        icon: symbol,
                        percent: Some(p),
                        charging: false,
                    });
                    components = true;
                }
            }
            if !components {
                rows.push(Device {
                    name: name.clone(),
                    icon,
                    percent: percent(&info["device_batteryLevelMain"])
                        .or_else(|| percent(&info["device_batteryLevel"])),
                    charging: false,
                });
            }
        }
    }
    Some(rows)
}

// Maya X 8K dongle, vendor collection only; 0x83 queries the battery.
fn lamzu_reply(bytes: &[u8]) -> Option<(u8, bool)> {
    let frame = bytes.strip_prefix(&[0]).unwrap_or(bytes);
    let tail = frame.strip_prefix(&[0xa1, 0, 2, 2, 0, 0x83])?;
    let (&charging, &level) = (tail.first()?, tail.get(1)?);
    (charging <= 1 && level <= 100).then_some((level, charging == 1))
}
#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOHIDManagerCreate(allocator: *const c_void, options: u32) -> CFTypeRef;
    fn IOHIDManagerSetDeviceMatching(
        manager: CFTypeRef,
        dict: core_foundation::dictionary::CFDictionaryRef,
    );
    fn IOHIDManagerCopyDevices(manager: CFTypeRef) -> CFSetRef;
    fn IOHIDDeviceOpen(d: CFTypeRef, options: u32) -> i32;
    fn IOHIDDeviceClose(d: CFTypeRef, options: u32) -> i32;
    fn IOHIDDeviceSetReport(d: CFTypeRef, kind: u32, id: isize, data: *const u8, len: isize)
        -> i32;
    fn IOHIDDeviceGetReport(
        d: CFTypeRef,
        kind: u32,
        id: isize,
        data: *mut u8,
        len: *mut isize,
    ) -> i32;
}
fn query_mouse(d: CFTypeRef) -> Option<(u8, bool)> {
    let mut query = [0u8; 64];
    query[..6].copy_from_slice(&[0, 0, 2, 2, 0, 0x83]);
    unsafe {
        if IOHIDDeviceOpen(d, 0) != 0 {
            return None;
        }
        let mut answer = None;
        if IOHIDDeviceSetReport(d, 2, 0, query.as_ptr(), 64) == 0 {
            for _ in 0..5 {
                thread::sleep(Duration::from_millis(60));
                let mut buf = [0u8; 65];
                let mut len = 65;
                if IOHIDDeviceGetReport(d, 2, 0, buf.as_mut_ptr(), &mut len) == 0 {
                    answer = usize::try_from(len)
                        .ok()
                        .and_then(|n| buf.get(..n))
                        .and_then(lamzu_reply);
                    if answer.is_some() {
                        break;
                    }
                }
            }
        }
        IOHIDDeviceClose(d, 0);
        answer
    }
}
fn mice() -> Vec<Device> {
    let Some(m) = crate::owned(unsafe { IOHIDManagerCreate(ptr::null(), 0) }) else {
        return Vec::new();
    };
    let filters = [
        ("VendorID", 0x373e),
        ("ProductID", 0x1e),
        ("PrimaryUsagePage", 65535),
        ("PrimaryUsage", 0),
    ]
    .map(|(k, v)| (CFString::new(k), CFNumber::from(v)));
    let dict = CFDictionary::from_CFType_pairs(&filters);
    unsafe { IOHIDManagerSetDeviceMatching(m.as_CFTypeRef(), dict.as_concrete_TypeRef()) };
    let raw = unsafe { IOHIDManagerCopyDevices(m.as_CFTypeRef()) };
    if raw.is_null() {
        return Vec::new();
    }
    let devices = unsafe { CFSet::<CFType>::wrap_under_create_rule(raw) };
    let mut entries = vec![ptr::null(); devices.len()];
    unsafe {
        core_foundation::set::CFSetGetValues(raw, entries.as_mut_ptr());
    }
    entries
        .into_iter()
        .map(|d| {
            let reply = query_mouse(d);
            Device {
                name: "LAMZU Maya X".into(),
                icon: "computermouse",
                percent: reply.map(|r| r.0),
                charging: reply.is_some_and(|r| r.1),
            }
        })
        .collect()
}

#[derive(Default, Clone, PartialEq)]
pub(crate) struct Reading {
    pub devices: Vec<Device>,
    pub note: String,
}
pub(crate) fn read() -> Reading {
    let bt = Command::new("/usr/sbin/system_profiler")
        .args(["-timeout", "6", "-json", "SPBluetoothDataType"])
        .output()
        .ok()
        .filter(|r| r.status.success())
        .and_then(|r| serde_json::from_slice(&r.stdout).ok())
        .and_then(|v| bluetooth(&v));
    let unavailable = bt.is_none();
    let mut devices = bt.unwrap_or_default();
    devices.extend(mice());
    devices.sort_by(|a, b| a.name.cmp(&b.name));
    let note = if unavailable {
        "Данные Bluetooth недоступны"
    } else if devices.is_empty() {
        "Нет подключённых устройств"
    } else {
        ""
    };
    Reading {
        devices,
        note: note.into(),
    }
}
struct Poll {
    last: Option<Instant>,
    rx: Option<Receiver<Reading>>,
    value: Reading,
}
pub(crate) struct ChargeMonitor(RefCell<Poll>);
impl Default for ChargeMonitor {
    fn default() -> Self {
        Self(RefCell::new(Poll {
            last: None,
            rx: None,
            value: Reading {
                devices: vec![],
                note: "Обновление…".into(),
            },
        }))
    }
}
impl ChargeMonitor {
    pub fn poll(&self, visible: bool) -> Reading {
        let mut p = self.0.borrow_mut();
        if let Some(rx) = &p.rx {
            match rx.try_recv() {
                Ok(v) => {
                    p.value = v;
                    p.rx = None;
                }
                Err(TryRecvError::Disconnected) => {
                    p.value = Reading {
                        devices: vec![],
                        note: "Не удалось прочитать заряд".into(),
                    };
                    p.rx = None;
                }
                Err(TryRecvError::Empty) => {}
            }
        }
        if visible
            && p.rx.is_none()
            && p.last
                .is_none_or(|t| t.elapsed() >= Duration::from_secs(30))
        {
            let (tx, rx) = channel();
            p.last = Some(Instant::now());
            p.rx = Some(rx);
            thread::spawn(move || {
                let _ = tx.send(read());
            });
        }
        p.value.clone()
    }
}
