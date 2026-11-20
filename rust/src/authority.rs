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
    maximum.is_finite() && duration.is_finite() && duration > 0.0 && duration <= maximum
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_grant_is_finite_and_never_truncated() {
        assert!(nespat_valid_grant(10., 110., 100.));
        for (issued, end, max) in [
            (10., 110f64.next_up(), 100.),
            (10., 10., 1.),
            (0., 1., 0.),
            (0., 1., f64::NAN),
            (0., 1., f64::INFINITY),
            (-f64::MAX, f64::MAX, f64::MAX),
            (f64::NAN, 50., 50.),
            (0., f64::INFINITY, f64::MAX),
        ] {
            assert!(
                !nespat_valid_grant(issued, end, max),
                "{issued} {end} {max}"
            );
        }
    }
    #[test]
    fn expiry_clock_regression_and_heartbeat_timeout_retire_authority() {
        let mut g = AuthorityClock {
            expiry: 200.,
            last_observation: 101.,
            last_heartbeat: 100.,
            timeout: 20.,
            has_expiry: true,
            has_observation: true,
            has_heartbeat: true,
            has_timeout: true,
            full: true,
        };
        assert!(!nespat_authority_expired(&g, 119.999));
        for t in [100., 120., 200., f64::NAN, f64::INFINITY] {
            assert!(nespat_authority_expired(&g, t));
        }
        g.full = false;
        assert!(!nespat_authority_expired(&g, 150.));
        assert!(nespat_authority_expired(&g, 200.));
        g.has_heartbeat = false;
        assert!(nespat_authority_expired(&g, 110.));
    }
    #[test]
    fn request_budget_and_heartbeat_sequence_are_independent() {
        let mut ledger = ReplayLedger::default();
        let mut r = RequestAdmission {
            id: [1; 16],
            sequence: 0,
            last_sequence: 0,
            requests: 4095,
            has_sequence: false,
            selected: true,
            matching_session: true,
            recovery: false,
        };
        assert!(matches!(
            nespat_admit_request(&mut ledger, &mut r),
            Admission::Allowed
        ));
        assert!(matches!(
            nespat_admit_request(&mut ledger, &mut r),
            Admission::Replayed
        ));
        r.id = [2; 16];
        assert!(matches!(
            nespat_admit_request(&mut ledger, &mut r),
            Admission::Exhausted
        ));
        r.has_sequence = true;
        r.sequence = 1;
        for (selected, matching) in [(false, true), (true, false)] {
            r.selected = selected;
            r.matching_session = matching;
            assert!(matches!(
                nespat_admit_request(&mut ledger, &mut r),
                Admission::Replayed
            ));
        }
        r.matching_session = true;
        assert!(matches!(
            nespat_admit_request(&mut ledger, &mut r),
            Admission::Allowed
        ));
        assert!(matches!(
            nespat_admit_request(&mut ledger, &mut r),
            Admission::Replayed
        ));
        assert_eq!(r.requests, 4096);
    }
}
