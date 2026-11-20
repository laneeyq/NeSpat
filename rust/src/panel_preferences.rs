use core_foundation::{base::TCFType, string::CFString, url::CFURL};
use objc2::rc::Retained;
use objc2_foundation::{NSBundle, NSString, NSUserDefaults};
use std::{fs, os::unix::fs::MetadataExt, path::Path};
pub(crate) const AUTO: &str = "automaticMode.requested.v1";
pub(crate) const UPDATES: &str = "updates.automatic";
pub(crate) const CHOICE: &str = "exclusive.durationChoice";
pub(crate) const CUSTOM: &str = "exclusive.customMinutes";
pub(crate) fn ns(s: &str) -> Retained<NSString> {
    NSString::from_str(s)
}
fn prefs() -> Retained<NSUserDefaults> {
    NSUserDefaults::standardUserDefaults()
}
pub(crate) fn flag(k: &str, initial: bool) -> bool {
    let p = prefs();
    let k = ns(k);
    if p.objectForKey(&k).is_some() {
        p.boolForKey(&k)
    } else {
        initial
    }
}
pub(crate) fn set_flag(k: &str, v: bool) {
    prefs().setBool_forKey(v, &ns(k));
}
pub(crate) fn choice() -> i64 {
    let p = prefs();
    let k = ns(CHOICE);
    if p.objectForKey(&k).is_some() {
        p.integerForKey(&k) as i64
    } else {
        60
    }
}
pub(crate) fn set_choice(v: i64) {
    prefs().setInteger_forKey(v as isize, &ns(CHOICE));
}
pub(crate) fn custom() -> String {
    prefs()
        .stringForKey(&ns(CUSTOM))
        .map_or_else(|| "30".into(), |v| v.to_string())
}
pub(crate) fn set_custom(v: i64) {
    unsafe {
        prefs().setObject_forKey(Some(&ns(&v.to_string())), &ns(CUSTOM));
    }
    set_choice(-1);
}
pub(crate) fn migrate() {
    let p = prefs();
    if p.objectForKey(&ns(CHOICE)).is_some() {
        return;
    }
    let old = p.integerForKey(&ns("exclusive.durationMinutes"));
    if matches!(old, 60 | 180 | 480) {
        set_choice(old as i64);
        return;
    }
    if let Some(v) = p.stringForKey(&ns("durationChoice.v6")) {
        let v = v.to_string();
        if let Some(d) = v.strip_prefix("custom:") {
            let seconds = unsafe { crate::policy::nespat_parse_minutes(d.as_ptr(), d.len()) };
            if seconds > 0 {
                set_custom(seconds / 60);
            }
        } else if let Some(n) = ["Без лимита", "1 ч", "3 ч", "8 ч"]
            .iter()
            .position(|s| *s == v)
        {
            set_choice(crate::duration_control::nespat_preset_minutes(n as isize));
        }
    }
}
pub(crate) fn login_context() -> (bool, bool) {
    let path = NSBundle::mainBundle().bundlePath().to_string();
    let installed = path == "/Library/Application Support/NeSpatPrivileged/NeSpat.app";
    let ok = || -> Option<bool> {
        let (pin, _) = crate::profile::Profile::load()?.client_requirements()?;
        let file =
            fs::symlink_metadata(Path::new("/Library/LaunchAgents/local.nespat.gui.plist")).ok()?;
        Some(
            file.is_file()
                && file.uid() == 0
                && file.mode() & 0o022 == 0
                && crate::signing::nespat_matches_code(
                    CFURL::from_path(path, true)?.as_concrete_TypeRef(),
                    CFString::new(&pin).as_concrete_TypeRef(),
                    true,
                ),
        )
    };
    (ok() == Some(true), installed)
}
