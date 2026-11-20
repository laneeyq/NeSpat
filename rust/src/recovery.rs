// The journal owner commits each returned transition while holding its original
// transaction. A repaired clock starts a fresh cooldown at the observed time.
#[repr(C)]
#[derive(Debug, PartialEq)]
pub enum Retry {
    Reserve,
    Wait,
    ClockFault,
    RepairClock,
    InvalidHistory,
}
#[no_mangle]
pub extern "C" fn nespat_retry_decision(
    now: f64,
    since: f64,
    last: f64,
    clock_fault: bool,
    was_emergency: bool,
    emergency: bool,
    manual: bool,
    interval: f64,
) -> Retry {
    if !since.is_finite() || !last.is_finite() || since < 0.0 || last < since {
        return Retry::InvalidHistory;
    }
    if !now.is_finite() || now < last {
        return Retry::ClockFault;
    }
    if clock_fault {
        return Retry::RepairClock;
    }
    if manual || (emergency && !was_emergency) || now - since >= interval {
        Retry::Reserve
    } else {
        Retry::Wait
    }
}

extern "C" {
    fn IOPMFindPowerManagement(port: u32) -> u32;
    fn IOPMSleepSystem(connection: u32) -> i32;
    fn IOServiceClose(connection: u32) -> i32;
}
#[no_mangle]
pub extern "C" fn nespat_emergency_sleep() -> i32 {
    if unsafe { libc::geteuid() } != 0 {
        return -1;
    }
    let connection = unsafe { IOPMFindPowerManagement(0) };
    if connection == 0 {
        return -1;
    }
    let result = unsafe { IOPMSleepSystem(connection) };
    unsafe {
        IOServiceClose(connection);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn urgent_retry_bypasses_only_first_ordinary_cooldown() {
        assert_eq!(
            nespat_retry_decision(10., 1., 9., false, false, true, false, 30.),
            Retry::Reserve
        );
        assert_eq!(
            nespat_retry_decision(10., 1., 9., false, true, true, false, 30.),
            Retry::Wait
        );
        assert_eq!(
            nespat_retry_decision(31., 1., 9., false, true, true, false, 30.),
            Retry::Reserve
        );
    }
    #[test]
    fn manual_retry_requires_valid_clock_history() {
        assert_eq!(
            nespat_retry_decision(1., 2., 3., false, false, false, true, 300.),
            Retry::ClockFault
        );
        assert_eq!(
            nespat_retry_decision(10., 5., 3., false, false, false, true, 300.),
            Retry::InvalidHistory
        );
        assert_eq!(
            nespat_retry_decision(10., 1., 3., true, false, false, true, 300.),
            Retry::RepairClock
        );
    }
}
