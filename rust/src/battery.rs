use super::owned;
use core_foundation::{
    array::CFArray,
    base::{CFType, CFTypeRef, TCFType},
    boolean::CFBoolean,
    dictionary::{CFDictionary, CFDictionaryRef},
    number::CFNumber,
    string::CFString,
};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
    fn IOPSCopyPowerSourcesList(info: CFTypeRef) -> CFTypeRef;
    fn IOPSGetPowerSourceDescription(info: CFTypeRef, source: CFTypeRef) -> CFDictionaryRef;
}
#[repr(C)]
pub struct Battery {
    percent: f64,
    minutes: i64,
    external: i8,
    charging: i8,
    charged: i8,
}
impl Default for Battery {
    fn default() -> Self {
        Self {
            percent: f64::NAN,
            minutes: -1,
            external: -1,
            charging: -1,
            charged: -1,
        }
    }
}
fn field(d: &CFDictionary, name: &str) -> Option<CFType> {
    d.find(CFString::new(name).as_CFTypeRef())
        .map(|v| unsafe { CFType::wrap_under_get_rule(*v) })
}
fn parse(d: &CFDictionary) -> Battery {
    let boolean = |name| {
        field(d, name)?
            .downcast::<CFBoolean>()
            .map(|b| bool::from(b) as i8)
    };
    let value = |name| {
        field(d, name)?
            .downcast::<CFNumber>()?
            .to_f64()
            .filter(|n| n.is_finite() && *n >= 0.0)
    };
    let external = match field(d, "Power Source State")
        .and_then(|v| v.downcast::<CFString>())
        .map(|v| v.to_string())
        .as_deref()
    {
        Some("AC Power") => 1,
        Some("Battery Power") => 0,
        _ => -1,
    };
    let percent = match (value("Current Capacity"), value("Max Capacity")) {
        (Some(n), Some(m)) if m > 0.0 && n <= m => n / m * 100.0,
        _ => f64::NAN,
    };
    let charging = boolean("Is Charging").unwrap_or(-1);
    let time_key = if charging == 1 {
        Some("Time to Full Charge")
    } else if external == 0 {
        Some("Time to Empty")
    } else {
        None
    };
    let minutes = time_key
        .and_then(|key| field(d, key)?.downcast::<CFNumber>()?.to_i64())
        .filter(|n| *n > 0)
        .unwrap_or(-1);
    Battery {
        percent,
        minutes,
        external,
        charging,
        charged: boolean("Is Charged").unwrap_or(-1),
    }
}
#[no_mangle]
pub unsafe extern "C" fn nespat_parse_battery(d: CFDictionaryRef) -> Battery {
    if d.is_null() {
        return Battery::default();
    }
    parse(&CFDictionary::wrap_under_get_rule(d))
}
fn current() -> Option<Battery> {
    let info = owned(unsafe { IOPSCopyPowerSourcesInfo() })?;
    let list =
        owned(unsafe { IOPSCopyPowerSourcesList(info.as_CFTypeRef()) })?.downcast::<CFArray>()?;
    for source in list.iter() {
        let raw = unsafe { IOPSGetPowerSourceDescription(info.as_CFTypeRef(), *source) };
        if raw.is_null() {
            continue;
        }
        let d = unsafe { CFDictionary::wrap_under_get_rule(raw) };
        if field(&d, "Type")
            .and_then(|v| v.downcast::<CFString>())
            .is_some_and(|v| v.to_string() == "InternalBattery")
        {
            return Some(parse(&d));
        }
    }
    None
}
#[no_mangle]
pub extern "C" fn nespat_current_battery() -> Battery {
    current().unwrap_or_default()
}
