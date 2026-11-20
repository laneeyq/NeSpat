// Decisions use one authenticated observation. The async host must obtain a fresh
// observation and current user intent after prepare returns.
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct Observation {
    now: f64,
    wall: f64,
    last_time: f64,
    expires: f64,
    deadline: f64,
    maximum: f64,
    has_expiry: bool,
    has_deadline: bool,
    has_lease: bool,
    selected_lifetime: bool,
    service_verified: bool,
    authorized: bool,
    active_user: bool,
    recovery_only: bool,
    foreign_owner: bool,
    known: bool,
    boot_matches: bool,
    known_boot_matches: bool,
    lease_matches: bool,
    start_safe: bool,
    running_safe: bool,
    desired: bool,
    exhausted: bool,
    lid_closed: i8,
    sleep_disabled: i8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Off,
    Prepare,
    KeepActive,
    Restore,
    Unverified,
    Clock,
    Ownership,
    Replaced,
    Lost,
    Foreign,
    Finished,
    Unauthorized,
    OpenLid,
    Unsafe,
    Unconfirmed,
}
#[repr(C)]
pub struct Decision {
    action: Action,
    record_time: bool,
    adopt_lease: bool,
    forget_lease: bool,
    mark_finished: bool,
}

impl Observation {
    fn valid_lifetime(&self) -> bool {
        match (self.has_expiry, self.has_deadline) {
            (false, false) => self.selected_lifetime,
            (true, true) => {
                self.expires.is_finite()
                    && self.deadline.is_finite()
                    && (self.selected_lifetime
                        || (self.expires - self.now <= self.maximum
                            && self.deadline - self.wall <= self.maximum))
            }
            _ => false,
        }
    }
    fn active_action(&self, expired: bool) -> Action {
        if self.desired
            && self.authorized
            && self.active_user
            && self.running_safe
            && !self.recovery_only
            && !expired
            && matches!(self.lid_closed, 0 | 1)
            && self.sleep_disabled == 1
        {
            Action::KeepActive
        } else {
            Action::Restore
        }
    }
}

#[no_mangle]
pub extern "C" fn nespat_auto_decide(s: Observation, after_prepare: bool) -> Decision {
    let clock_valid = s.now.is_finite() && s.now >= 0.0 && s.now >= s.last_time;
    let expired = (s.has_expiry && s.expires <= s.now) || (s.has_deadline && s.deadline <= s.wall);
    let owned = s.has_lease && s.boot_matches && !s.foreign_owner && s.valid_lifetime();
    let mut decision = Decision {
        action: Action::Unconfirmed,
        record_time: false,
        adopt_lease: false,
        forget_lease: false,
        mark_finished: false,
    };
    if after_prepare {
        if s.service_verified && clock_valid && owned && !expired {
            decision.record_time = true;
            decision.adopt_lease = true;
            decision.action = s.active_action(false);
        }
        return decision;
    }
    decision.record_time = s.service_verified && clock_valid;
    decision.action = if !s.service_verified {
        Action::Unverified
    } else if !clock_valid {
        // Restoration still goes through the independently authenticated backend.
        if s.has_lease {
            Action::Restore
        } else {
            Action::Clock
        }
    } else if s.has_lease {
        if !owned {
            Action::Ownership
        } else if s.known && !s.lease_matches {
            Action::Replaced
        } else {
            decision.adopt_lease = true;
            decision.mark_finished = expired;
            s.active_action(expired)
        }
    } else if s.known && (!s.known_boot_matches || s.sleep_disabled != 0) {
        Action::Lost
    } else if s.sleep_disabled != 0 || s.foreign_owner {
        Action::Foreign
    } else {
        decision.forget_lease = s.known;
        decision.mark_finished = s.known;
        if !s.desired {
            Action::Off
        } else if s.known || s.exhausted {
            Action::Finished
        } else if !s.authorized {
            Action::Unauthorized
        } else if !s.active_user || s.lid_closed != 0 {
            Action::OpenLid
        } else if !s.start_safe {
            Action::Unsafe
        } else {
            Action::Prepare
        }
    };
    decision
}

#[cfg(test)]
mod tests {
    use super::*;
    fn active() -> Observation {
        Observation {
            now: 100.0,
            wall: 100.0,
            has_lease: true,
            selected_lifetime: true,
            service_verified: true,
            authorized: true,
            active_user: true,
            boot_matches: true,
            running_safe: true,
            desired: true,
            sleep_disabled: 1,
            ..Observation::default()
        }
    }
    #[test]
    fn rechecks_current_intent_after_preparation() {
        let s = active();
        assert_eq!(nespat_auto_decide(s, true).action, Action::KeepActive);
        let revoked = Observation {
            desired: false,
            ..s
        };
        assert_eq!(nespat_auto_decide(revoked, true).action, Action::Restore);
    }
    #[test]
    fn expiry_exhausts_but_corrupt_lease_never_adopted() {
        let s = Observation {
            has_expiry: true,
            has_deadline: true,
            expires: 100.0,
            deadline: 200.0,
            ..active()
        };
        let decision = nespat_auto_decide(s, false);
        assert!(decision.adopt_lease && decision.mark_finished);
        assert_eq!(decision.action, Action::Restore);
        let invalid = Observation {
            expires: f64::NAN,
            ..s
        };
        assert!(!nespat_auto_decide(invalid, false).adopt_lease);
        assert_eq!(
            nespat_auto_decide(invalid, true).action,
            Action::Unconfirmed
        );
    }
}
