// All times here are readings from the same boot's continuous clock.
#[repr(C)]
pub struct AuthorityClock {
    pub(crate) expiry: f64,
    pub(crate) last_observation: f64,
    pub(crate) last_heartbeat: f64,
    pub(crate) timeout: f64,
    pub(crate) has_expiry: bool,
    pub(crate) has_observation: bool,
    pub(crate) has_heartbeat: bool,
    pub(crate) has_timeout: bool,
    pub(crate) full: bool,
}
#[no_mangle]
pub extern "C" fn nespat_authority_expired(g: &AuthorityClock, now: f64) -> bool {
    if !now.is_finite()
        || (g.has_expiry && !(g.expiry > now))
        || (g.has_observation && now < g.last_observation)
    {
        return true;
    }
    if !g.has_heartbeat {
        return g.has_timeout;
    }
    let elapsed = now - g.last_heartbeat;
    !elapsed.is_finite() || elapsed < 0.0 || (g.full && g.has_timeout && elapsed >= g.timeout)
}
#[no_mangle]
pub extern "C" fn nespat_valid_grant(issued: f64, expires: f64, maximum: f64) -> bool {
    let duration = expires - issued;
    duration.is_finite() && duration > 0.0 && duration <= maximum
}

use std::collections::HashSet;
#[derive(Default)]
pub struct ReplayLedger {
    seen: HashSet<[u8; 16]>,
}
#[no_mangle]
pub extern "C" fn nespat_ledger_new() -> *mut ReplayLedger {
    Box::into_raw(Box::default())
}
#[no_mangle]
pub unsafe extern "C" fn nespat_ledger_drop(ledger: *mut ReplayLedger) {
    drop(Box::from_raw(ledger));
}
#[repr(C)]
pub struct RequestAdmission {
    pub(crate) id: [u8; 16],
    pub(crate) sequence: i64,
    pub(crate) last_sequence: i64,
    pub(crate) requests: u32,
    pub(crate) has_sequence: bool,
    pub(crate) selected: bool,
    pub(crate) matching_session: bool,
    pub(crate) recovery: bool,
}
#[repr(u8)]
pub enum Admission {
    Allowed,
    Replayed,
    Exhausted,
}
#[no_mangle]
pub extern "C" fn nespat_admit_request(
    ledger: &mut ReplayLedger,
    r: &mut RequestAdmission,
) -> Admission {
    if ledger.seen.contains(&r.id) {
        return Admission::Replayed;
    }
    if r.has_sequence {
        if !r.selected || !r.matching_session || r.sequence <= r.last_sequence {
            return Admission::Replayed;
        }
        r.last_sequence = r.sequence;
    } else {
        let limit = if r.recovery { 266240 } else { 262144 };
        if ledger.seen.len() >= limit || r.requests >= 4096 {
            return Admission::Exhausted;
        }
        ledger.seen.insert(r.id);
        r.requests += 1;
    }
    Admission::Allowed
}
