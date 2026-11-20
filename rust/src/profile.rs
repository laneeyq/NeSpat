use crate::{
    host::{boot, nespat_continuous_seconds},
    journal::trust_profile,
    request::uuid,
    signing::pin,
};
use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::{mem::ManuallyDrop, ptr};

struct Document {
    version: i32,
    setup: String,
    uid: u32,
    gui_hash: String,
    helper_hash: String,
    enabled: bool,
    acceptance_only: Option<bool>,
    exclusive_control: Option<bool>,
    host_model: Option<String>,
    os_build: Option<String>,
    selected_lifetime: Option<bool>,
    trial_only: Option<bool>,
    trial_on_battery: Option<bool>,
    trial_boot: Option<String>,
    trial_expires: Option<f64>,
}
impl Document {
    fn read(bytes: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(bytes).ok()?;
        let fields = value.as_object()?;
        fn optional<T: DeserializeOwned>(
            fields: &serde_json::Map<String, Value>,
            key: &str,
        ) -> Option<Option<T>> {
            match fields.get(key) {
                None | Some(Value::Null) => Some(None),
                Some(value) => T::deserialize(value).ok().map(Some),
            }
        }
        Some(Self {
            version: i32::try_from(value["version"].as_i64()?).ok()?,
            setup: value["setup"].as_str()?.to_owned(),
            uid: u32::try_from(value["allowedUID"].as_u64()?).ok()?,
            gui_hash: value["guiHash"].as_str()?.to_owned(),
            helper_hash: value["helperHash"].as_str()?.to_owned(),
            enabled: value["enabled"].as_bool()?,
            acceptance_only: optional(fields, "acceptanceOnly")?,
            exclusive_control: optional(fields, "exclusiveControl")?,
            host_model: optional(fields, "hostModel")?,
            os_build: optional(fields, "osBuild")?,
            selected_lifetime: optional(fields, "selectedLifetime")?,
            trial_only: optional(fields, "trialOnly")?,
            trial_on_battery: optional(fields, "trialOnBattery")?,
            trial_boot: optional(fields, "trialBoot")?,
            trial_expires: optional(fields, "trialExpires")?,
        })
    }
}
pub struct Profile {
    doc: Document,
    pub(crate) setup: [u8; 16],
    trial_boot: Option<[u8; 16]>,
}
impl Profile {
    pub(crate) fn load() -> Option<Self> {
        let doc = Document::read(&trust_profile()?)?;
        if doc.version != 1 || doc.uid == 0 {
            return None;
        }
        pin(&doc.gui_hash, "local.nespat.app")?;
        pin(&doc.helper_hash, "local.nespat.privilege-helper")?;
        let setup = uuid(&doc.setup)?;
        let trial_boot = match &doc.trial_boot {
            Some(s) => Some(uuid(s)?),
            None => None,
        };
        Some(Self {
            doc,
            setup,
            trial_boot,
        })
    }
    pub(crate) fn client_requirements(&self) -> Option<(String, String)> {
        if self.doc.uid != unsafe { libc::getuid() } {
            return None;
        }
        Some((
            pin(&self.doc.gui_hash, "local.nespat.app")?,
            pin(&self.doc.helper_hash, "local.nespat.privilege-helper")?,
        ))
    }
    pub(crate) fn verified_recovery_helper(&self) -> Option<&'static str> {
        use core_foundation::url::CFURL;
        const HELPER:&str="/Library/Application Support/NeSpatPrivileged/NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper";
        let (_, requirement) = self.client_requirements()?;
        (self.exclusive()
            && crate::signing::nespat_matches_code(
                CFURL::from_path(HELPER, false)?.as_concrete_TypeRef(),
                CFString::new(&requirement).as_concrete_TypeRef(),
                true,
            ))
        .then_some(HELPER)
    }
    pub(crate) fn trial_only(&self) -> bool {
        self.doc.trial_only == Some(true)
    }
    fn exclusive(&self) -> bool {
        self.doc.exclusive_control == Some(true) && self.doc.acceptance_only != Some(true)
    }
    fn selected(&self) -> bool {
        self.exclusive()
            && self.doc.trial_only != Some(true)
            && self.doc.selected_lifetime == Some(true)
    }
    fn matches_host(&self) -> bool {
        let (Some(model), Some(build)) = (&self.doc.host_model, &self.doc.os_build) else {
            return false;
        };
        unsafe {
            crate::host::nespat_matches_host(
                CFString::new(model).as_concrete_TypeRef(),
                CFString::new(build).as_concrete_TypeRef(),
            )
        }
    }
    fn enabled_with(&self, current: &Self) -> bool {
        if !current.exclusive()
            || !current.matches_host()
            || !current.doc.enabled
            || current.setup != self.setup
            || current.doc.uid != self.doc.uid
            || current.doc.gui_hash != self.doc.gui_hash
            || current.doc.helper_hash != self.doc.helper_hash
            || current.selected() != self.selected()
            || (current.doc.trial_only == Some(true)) != (self.doc.trial_only == Some(true))
            || current.doc.trial_on_battery != self.doc.trial_on_battery
        {
            return false;
        }
        if self.doc.trial_only != Some(true) {
            return true;
        }
        let remaining = current.doc.trial_expires.unwrap_or(f64::NAN) - nespat_continuous_seconds();
        current.trial_boot.is_some()
            && current.trial_boot == boot()
            && remaining > 0.0
            && remaining <= 120.0
    }
}
#[repr(C)]
pub struct ProfileInfo {
    setup: [u8; 16],
    uid: u32,
    trial_expires: f64,
    exclusive: bool,
    selected: bool,
    trial: bool,
    on_battery: bool,
    acceptance: bool,
    acceptance_only: bool,
}
#[no_mangle]
pub extern "C" fn nespat_profile_load(info: &mut ProfileInfo) -> *mut Profile {
    let Some(p) = Profile::load() else {
        return ptr::null_mut();
    };
    let d = &p.doc;
    *info = ProfileInfo {
        setup: p.setup,
        uid: d.uid,
        trial_expires: d.trial_expires.unwrap_or(f64::NAN),
        exclusive: p.exclusive(),
        selected: p.selected(),
        trial: d.trial_only == Some(true),
        on_battery: d.trial_on_battery == Some(true),
        acceptance: d.acceptance_only == Some(true) && !d.enabled,
        acceptance_only: d.acceptance_only == Some(true),
    };
    Box::into_raw(Box::new(p))
}
#[no_mangle]
pub unsafe extern "C" fn nespat_profile_drop(p: *mut Profile) {
    drop(Box::from_raw(p));
}
#[no_mangle]
pub extern "C" fn nespat_profile_enabled(p: &Profile) -> bool {
    Profile::load().is_some_and(|q| p.enabled_with(&q))
}
#[no_mangle]
pub extern "C" fn nespat_profile_host(p: &Profile) -> bool {
    p.matches_host()
}
#[no_mangle]
pub extern "C" fn nespat_profile_hash(p: &Profile, helper: bool) -> CFStringRef {
    ManuallyDrop::new(CFString::new(if helper {
        &p.doc.helper_hash
    } else {
        &p.doc.gui_hash
    }))
    .as_concrete_TypeRef()
}
