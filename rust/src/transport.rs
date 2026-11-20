// One instance per channel. Its owner serializes all accesses on the transport actor.
use std::collections::HashSet;
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Unverified,
    Verified,
    Active,
    Closed,
}

pub struct Transport {
    phase: Phase,
    started: bool,
    peer: i32,
    deadline: f64,
    requests: HashSet<[u8; 16]>,
    sequence: i64,
}
#[no_mangle]
pub extern "C" fn nespat_transport_new() -> *mut Transport {
    Box::into_raw(Box::new(Transport {
        phase: Phase::Unverified,
        started: false,
        peer: 0,
        deadline: 0.0,
        requests: HashSet::new(),
        sequence: 0,
    }))
}
#[no_mangle]
pub unsafe extern "C" fn nespat_transport_drop(t: *mut Transport) {
    drop(Box::from_raw(t));
}
#[no_mangle]
pub extern "C" fn nespat_transport_close(t: &mut Transport) {
    t.phase = Phase::Closed;
    t.peer = 0;
}
#[no_mangle]
pub extern "C" fn nespat_transport_phase(t: &Transport) -> u8 {
    t.phase as u8
}
#[no_mangle]
pub extern "C" fn nespat_transport_start(t: &mut Transport) -> bool {
    if t.phase != Phase::Unverified || t.started {
        return false;
    }
    t.started = true;
    true
}
#[no_mangle]
pub extern "C" fn nespat_transport_arm(t: &mut Transport, now: f64, timeout: f64) -> bool {
    let deadline = now + timeout;
    if !deadline.is_finite() || !(timeout > 0.0 && timeout <= 60.0) {
        return false;
    }
    t.deadline = deadline;
    true
}
#[no_mangle]
pub extern "C" fn nespat_transport_timely(t: &Transport, now: f64) -> bool {
    now.is_finite() && now < t.deadline
}
#[no_mangle]
pub extern "C" fn nespat_transport_verify(t: &mut Transport, pid: i32, uid: u32) -> bool {
    if t.phase != Phase::Unverified || !t.started || pid <= 0 || uid != 0 {
        return false;
    }
    t.peer = pid;
    t.phase = Phase::Verified;
    true
}
#[no_mangle]
pub extern "C" fn nespat_transport_peer(t: &Transport, pid: i32, uid: u32) -> bool {
    t.phase == Phase::Active && pid == t.peer && pid > 0 && uid == 0
}
#[no_mangle]
pub extern "C" fn nespat_transport_reserve(
    t: &mut Transport,
    id: &[u8; 16],
    has_sequence: bool,
    sequence: i64,
) -> bool {
    if !matches!(t.phase, Phase::Verified | Phase::Active) || t.requests.contains(id) {
        return false;
    }
    if has_sequence {
        if sequence <= t.sequence {
            return false;
        }
        t.sequence = sequence;
    } else {
        if t.requests.len() >= 4096 {
            return false;
        }
        t.requests.insert(*id);
    }
    t.phase = Phase::Active;
    true
}
