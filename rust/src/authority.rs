// All times here are readings from the same boot's continuous clock.
#[repr(C)]
pub struct AuthorityClock {
    expiry: f64,
    last_observation: f64,
    last_heartbeat: f64,
    timeout: f64,
    has_expiry: bool,
    has_observation: bool,
    has_heartbeat: bool,
    has_timeout: bool,
    full: bool,
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
    id: [u8; 16],
    sequence: i64,
    last_sequence: i64,
    requests: u32,
    has_sequence: bool,
    selected: bool,
    matching_session: bool,
    recovery: bool,
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
