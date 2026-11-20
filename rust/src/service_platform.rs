#[cfg(not(test))]
pub(crate) use crate::{
    host::nespat_continuous_seconds as clock,
    observation::nespat_sleep_disabled as power,
    profile::nespat_profile_enabled,
    recovery::nespat_emergency_sleep as emergency_sleep,
    setter::{nespat_set_power, nespat_setter_idle as idle},
};
#[cfg(test)]
pub(crate) use fake::*;
#[cfg(test)]
mod fake {
    use crate::{profile::Profile, setter::SetterResult};
    use std::cell::Cell;
    thread_local! {
        pub static SETTER_HOOK:Cell<Option<fn(bool)->SetterResult>>=const{Cell::new(None)};
        pub static PULSE:Cell<Option<[u8;16]>>=const{Cell::new(None)};
        pub static WALL:Cell<f64>=const{Cell::new(1000.)};
        pub static IDLE:Cell<bool>=const{Cell::new(true)};
        pub static TIME:Cell<f64>=const{Cell::new(100.)};
        pub static POWER:Cell<i8>=const{Cell::new(0)};
        pub static SAFETY:Cell<(u8,i8)>=const{Cell::new((0,1))};
        pub static ARM:Cell<bool>=const{Cell::new(true)};
        pub static SLEEP:Cell<u32>=const{Cell::new(0)};
        pub static SETTERS:Cell<u32>=const{Cell::new(0)};
    }
    pub fn clock() -> f64 {
        TIME.get()
    }
    pub fn power() -> i8 {
        POWER.get()
    }
    pub fn nespat_profile_enabled(_: &Profile) -> bool {
        ARM.get()
    }
    pub fn idle() -> bool {
        IDLE.get()
    }
    pub fn nespat_set_power(disabled: bool) -> SetterResult {
        SETTERS.set(SETTERS.get() + 1);
        if let Some(set) = SETTER_HOOK.get() {
            return set(disabled);
        }
        POWER.set(disabled as i8);
        SetterResult::Confirmed
    }
    pub fn emergency_sleep() -> i32 {
        SLEEP.set(SLEEP.get() + 1);
        0
    }
}
