use super::*;
use crate::service_platform::{IDLE, SETTER_HOOK};
use crate::setter::SetterResult;

fn snapshot(f: &mut Fixture) -> crate::service_record::Envelope {
    f.server
        .store
        .transaction(|tx| Some(tx.state().clone()))
        .unwrap()
}

#[test]
fn enrollment_rejects_unproven_identity_before_a_power_write() {
    for field in [
        "uid",
        "audit",
        "pin",
        "missingPin",
        "process",
        "boot",
        "pid",
        "start",
        "disabledSetup",
        "unknownPower",
        "foreignPower",
    ] {
        let mut f = Fixture::new();
        match field {
            "uid" => f.peer.uid = 0,
            "audit" => f.peer.audit = 0,
            "pin" => f.peer.code = Some("other".into()),
            "missingPin" => f.peer.code = None,
            "process" => f.peer.process = None,
            "boot" => f.peer.process.as_mut().unwrap().boot = new_id(),
            "pid" => f.peer.process.as_mut().unwrap().pid = 0,
            "start" => f.peer.process.as_mut().unwrap().seconds += 1,
            "disabledSetup" => ARM.set(false),
            "unknownPower" => POWER.set(-1),
            "foreignPower" => POWER.set(1),
            _ => unreachable!(),
        }
        let before = snapshot(&mut f);
        assert!(f.req(1, None, None).is_none(), "{field}");
        assert_eq!(snapshot(&mut f), before);
        assert_eq!(SETTERS.get(), 0);
    }
}

#[test]
fn all_start_denials_leave_journal_and_power_untouched() {
    for risk in 1..=5 {
        let mut f = Fixture::new();
        SAFETY.set((risk, 0));
        let before = snapshot(&mut f);
        assert!(f.req(1, None, Some(1)).is_none());
        assert_eq!(snapshot(&mut f), before);
        assert_eq!(SETTERS.get(), 0);
    }
    for minutes in [-1, 0, i64::MAX] {
        let mut f = Fixture::new();
        assert!(f.req(1, None, Some(minutes)).is_none());
        assert_eq!(SETTERS.get(), 0);
        assert!(snapshot(&mut f).record.is_none());
    }
}

#[test]
fn heartbeat_updates_liveness_without_extending_the_timer_or_writing_to_disk() {
    let mut f = Fixture::new();
    let id = f.begin(Some(1));
    let before = snapshot(&mut f);
    let q = |seq| Request {
        id: new_id(),
        operation: 6,
        session: id,
        has_session: true,
        sequence: seq,
        has_sequence: true,
        ..Default::default()
    };
    for (t, seq) in [(116., 1), (130., 2), (146., 3), (159., 4)] {
        TIME.set(t);
        let beat = q(seq);
        assert!(f.server.request(&f.peer, &beat).is_some());
        assert!(f.server.request(&f.peer, &beat).is_none());
        assert_eq!(snapshot(&mut f), before);
    }
    TIME.set(160.);
    assert!(f.server.request(&f.peer, &q(5)).is_none());
    f.server.tick().unwrap();
    assert_eq!(snapshot(&mut f).completed, Some(id));
    assert_eq!((POWER.get(), SETTERS.get(), SLEEP.get()), (0, 2, 0));
}

#[test]
fn duplicate_owner_cannot_take_over_and_restart_only_gets_recovery() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    let before = snapshot(&mut f);
    f.peer.connection = new_id();
    for op in [0, 1, 3, 6] {
        assert!(f
            .req(op, if op > 1 { Some(id) } else { None }, None)
            .is_none());
    }
    assert_eq!(snapshot(&mut f), before);
    let mut h = f.watchdog();
    h.watchdog = false;
    f.server = Server::new(h, Store::fixture(f.folder.path()));
    let status = f.req(0, None, None).unwrap();
    assert_eq!(status["fullAuthority"], false);
    for op in [1, 2, 6] {
        assert!(f.req(op, Some(id), None).is_none());
    }
    f.req(7, Some(id), None).unwrap();
    assert_eq!(SETTERS.get(), 2);
    assert!(f.req(1, None, None).is_none());
}

#[test]
fn request_and_tick_clock_regression_disable_future_heartbeats() {
    for tick in [false, true] {
        let mut f = Fixture::new();
        let id = f.begin(None);
        TIME.set(115.);
        if tick {
            f.server.tick().unwrap();
        } else {
            f.req(0, None, None).unwrap();
        }
        TIME.set(114.);
        assert!(f.req(6, Some(id), None).is_none());
        TIME.set(116.);
        assert!(f.req(6, Some(id), None).is_none());
        assert_eq!((SETTERS.get(), POWER.get()), (1, 1));
        f.req(7, Some(id), None).unwrap();
        assert_eq!(POWER.get(), 0);
    }
}

#[test]
fn failed_recovery_persists_across_restart_and_retries_only_at_the_boundary() {
    for (risk, interval, sleeps) in [
        (0, 300., 0),
        (1, 30., 0),
        (2, 30., 1),
        (3, 30., 1),
        (5, 30., 1),
    ] {
        let mut f = Fixture::new();
        let id = f.begin(None);
        let h = f.watchdog();
        SAFETY.set((risk, 0));
        SETTER_HOOK.set(Some(|_| {
            TIME.set(105.);
            SetterResult::Unconfirmed
        }));
        let mut store = Store::fixture(f.folder.path());
        assert!(store.transaction(|t| reconcile(&h, t, None)).is_none());
        let first = snapshot(&mut f);
        let retry = first.retry.unwrap();
        assert_eq!(retry.failures, Some(1));
        assert_eq!(retry.since, 105.);
        assert_eq!(retry.record.id, id);
        assert_eq!(SLEEP.get(), 0);
        drop(store);
        let mut store = Store::fixture(f.folder.path());
        SETTER_HOOK.set(None);
        TIME.set(105. + interval - 0.01);
        store.transaction(|t| reconcile(&h, t, None)).unwrap();
        assert_eq!(SETTERS.get(), 2);
        TIME.set(105. + interval);
        store.transaction(|t| reconcile(&h, t, None)).unwrap();
        assert_eq!((POWER.get(), SETTERS.get(), SLEEP.get()), (0, 3, sleeps));
        assert_eq!(snapshot(&mut f).completed, Some(id));
    }
}

#[test]
fn late_activation_and_exit_success_without_observation_do_not_claim_success() {
    for hook in [
        (|_: bool| SetterResult::Confirmed) as fn(bool) -> SetterResult,
        |_| {
            POWER.set(1);
            TIME.set(10000000.);
            SetterResult::Confirmed
        },
    ] {
        let mut f = Fixture::new();
        SETTER_HOOK.set(Some(hook));
        assert!(f.req(1, None, Some(1)).is_none());
        let pending = snapshot(&mut f).record.unwrap();
        assert_eq!(pending.phase, Phase::Pending);
        assert!(pending.attempt.is_some());
        SETTER_HOOK.set(None);
        let h = f.watchdog();
        f.server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .unwrap();
        assert_eq!(POWER.get(), 0);
        assert!(snapshot(&mut f).record.is_none());
    }
}

#[test]
fn unsafe_state_clearing_during_restore_suppresses_forced_sleep() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    SAFETY.set((5, 0));
    SETTER_HOOK.set(Some(|disabled| {
        assert!(!disabled);
        POWER.set(0);
        SAFETY.set((0, 1));
        SetterResult::Confirmed
    }));
    f.server.tick().unwrap();
    assert_eq!(snapshot(&mut f).completed, Some(id));
    assert_eq!((SETTERS.get(), SLEEP.get()), (2, 0));
}

#[test]
fn independent_watchdog_refuses_unknown_power_busy_setter_and_other_boot() {
    for reason in ["unknown", "busy", "boot"] {
        let mut f = Fixture::new();
        f.begin(None);
        let mut h = f.watchdog();
        match reason {
            "unknown" => POWER.set(-1),
            "busy" => IDLE.set(false),
            "boot" => h.boot = new_id(),
            _ => unreachable!(),
        }
        let before = snapshot(&mut f);
        assert!(f
            .server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .is_none());
        assert_eq!(snapshot(&mut f), before);
        assert_eq!((SETTERS.get(), SLEEP.get()), (1, 0));
    }
}

#[test]
fn recovery_ticket_is_bound_to_exact_record_and_observed_ordinary_sleep() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    let h = f.watchdog();
    let ticket = f.server.store.transaction(|t| Some(t.ticket())).unwrap();
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, Some((new_id(), &ticket))))
        .is_none());
    POWER.set(0);
    TIME.set(f64::NAN);
    f.server
        .store
        .transaction(|t| reconcile(&h, t, Some((id, &ticket))))
        .unwrap();
    assert_eq!(snapshot(&mut f).completed, Some(id));
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, Some((id, &ticket))))
        .is_none());
    assert_eq!((SETTERS.get(), SLEEP.get()), (1, 0));
}

#[test]
fn failed_activation_and_manual_recovery_never_claim_foreign_interference() {
    let mut f = Fixture::new();
    SETTER_HOOK.set(Some(|_| SetterResult::Interference));
    assert!(f.req(1, None, None).is_none());
    let snapshot = snapshot(&mut f);
    let rec = snapshot.record.unwrap();
    assert_eq!(rec.interference, Some(true));
    POWER.set(1);
    let h = f.watchdog();
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .is_none());
    assert_eq!(SETTERS.get(), 1);
}

#[test]
fn changing_active_duration_is_rejected_without_modifying_original_lease() {
    let mut f = Fixture::new();
    let id = f.begin(Some(6000));
    let before = snapshot(&mut f);
    assert!(f.req(2, Some(id), Some(60)).is_none());
    assert!(f.req(1, None, None).is_none());
    assert_eq!(snapshot(&mut f), before);
    f.server.close(&f.peer);
    assert_eq!(snapshot(&mut f).completed, Some(id));
    f.server.close(&f.peer);
    assert!(f.req(1, None, None).is_none());
    assert_eq!(SETTERS.get(), 2);
}

#[test]
fn short_session_cannot_be_confirmed_after_its_monotonic_deadline_or_clock_regression() {
    for late in [99., 160., f64::NAN] {
        let mut f = Fixture::new();
        SETTER_HOOK.set(Some(|disabled| {
            assert!(disabled);
            POWER.set(1);
            TIME.set(FINISH.get());
            SetterResult::Confirmed
        }));
        thread_local! {static FINISH:std::cell::Cell<f64>=const{std::cell::Cell::new(0.)};}
        FINISH.set(late);
        assert!(
            f.req(1, None, Some(1)).is_none(),
            "activation confirmed with clock {late}"
        );
        assert_eq!(snapshot(&mut f).record.unwrap().phase, Phase::Pending);
        TIME.set(170.);
        SETTER_HOOK.set(None);
        let h = f.watchdog();
        f.server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .unwrap();
        assert_eq!((POWER.get(), SETTERS.get()), (0, 2));
    }
}

#[test]
fn retry_budget_survives_restarts_clock_faults_and_manual_approval() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    let h = f.watchdog();
    SETTER_HOOK.set(Some(|_| SetterResult::Unconfirmed));
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .is_none());
    let initial = snapshot(&mut f).retry.unwrap();
    assert_eq!(initial.since, 100.);
    let mut store = Store::fixture(f.folder.path());
    TIME.set(97.);
    assert!(store.transaction(|t| reconcile(&h, t, None)).is_none());
    // A clock earlier than the issuance cannot authorize either manual or automatic restoration.
    let ticket = store.transaction(|t| Some(t.ticket())).unwrap();
    assert!(store
        .transaction(|t| reconcile(&h, t, Some((id, &ticket))))
        .is_none());
    TIME.set(115.);
    store.transaction(|t| reconcile(&h, t, None)).unwrap();
    assert_eq!(SETTERS.get(), 2);
    SETTER_HOOK.set(None);
    let ticket = store.transaction(|t| Some(t.ticket())).unwrap();
    store
        .transaction(|t| reconcile(&h, t, Some((id, &ticket))))
        .unwrap();
    assert_eq!((POWER.get(), SETTERS.get()), (0, 3));
}

#[test]
fn emergency_may_preempt_an_ordinary_failed_attempt_only_once() {
    let mut f = Fixture::new();
    f.begin(None);
    let h = f.watchdog();
    SETTER_HOOK.set(Some(|_| SetterResult::Unconfirmed));
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .is_none());
    SAFETY.set((3, 1));
    TIME.set(101.);
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .is_none());
    assert_eq!(SETTERS.get(), 3);
    for now in [102., 130.999] {
        TIME.set(now);
        f.server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .unwrap();
        assert_eq!(SETTERS.get(), 3);
    }
    TIME.set(131.);
    SETTER_HOOK.set(None);
    f.server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .unwrap();
    assert_eq!((SETTERS.get(), SLEEP.get()), (4, 1));
}

#[test]
fn recorded_authority_cannot_be_restored_with_substituted_proof_fields() {
    let mut f = Fixture::new();
    f.begin(Some(5));
    let base = snapshot(&mut f).record.unwrap();
    let h = &f.server.host;
    let proven = |r: &Record| {
        r.proof(
            h.profile.setup,
            h.profile.uid(),
            &h.client,
            true,
            h.profile.maximum(),
        )
        .is_some()
    };
    assert!(proven(&base));
    for field in [
        "setup",
        "session",
        "boot",
        "owner",
        "baseline",
        "signer",
        "stamp",
        "reservation",
        "issued",
        "expiry",
        "deadline",
        "interference",
        "unlimited",
    ] {
        let mut r = base.clone();
        let a = r.attempt.as_mut().unwrap();
        match field {
            "setup" => a.setup = new_id(),
            "session" => a.session = new_id(),
            "boot" => a.boot = new_id(),
            "owner" => a.owner.connection = new_id(),
            "baseline" => r.baseline = false,
            "signer" => r.owner.code = None,
            "stamp" => r.owner.process = None,
            "reservation" => r.reservation = None,
            "issued" => a.issued = f64::NAN,
            "expiry" => a.expires = None,
            "deadline" => a.deadline = None,
            "interference" => r.interference = Some(true),
            "unlimited" => a.unlimited = Some(true),
            _ => unreachable!(),
        }
        assert!(!proven(&r), "{field}");
    }
}

#[test]
fn two_independent_stores_serialize_recovery_and_accept_external_normal_sleep() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    let h = f.watchdog();
    let mut watch = Store::fixture(f.folder.path());
    f.server
        .store
        .transaction(|_| {
            assert!(watch.transaction(|t| reconcile(&h, t, None)).is_none());
            Some(())
        })
        .unwrap();
    assert_eq!(SETTERS.get(), 1);
    POWER.set(0);
    TIME.set(f64::NAN);
    watch.transaction(|t| reconcile(&h, t, None)).unwrap();
    assert_eq!(snapshot(&mut f).completed, Some(id));
    assert_eq!(SETTERS.get(), 1);
}

#[test]
fn matching_live_helper_prevents_parallel_restoration_until_either_timer_expires() {
    use crate::service_platform::{PULSE, WALL};
    for expired in ["wall", "continuous", "neither"] {
        let mut f = Fixture::new();
        let id = f.begin(Some(1));
        let h = f.watchdog();
        PULSE.set(Some(f.server.host.epoch));
        TIME.set(if expired == "continuous" { 160. } else { 159. });
        WALL.set(if expired == "wall" { 1060. } else { 1059. });
        f.server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .unwrap();
        if expired == "neither" {
            assert_eq!(snapshot(&mut f).record.unwrap().id, id);
            assert_eq!(SETTERS.get(), 1);
        } else {
            assert_eq!(snapshot(&mut f).completed, Some(id));
            assert_eq!((SETTERS.get(), SLEEP.get()), (2, 0));
        }
    }
}

#[test]
fn unknown_power_and_failed_setter_never_refresh_a_lease() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    let before = snapshot(&mut f);
    TIME.set(118.);
    POWER.set(-1);
    assert!(f.req(6, Some(id), None).is_none());
    assert_eq!(snapshot(&mut f), before);
    TIME.set(120.);
    POWER.set(1);
    assert!(f.req(6, Some(id), None).is_none());
    SETTER_HOOK.set(Some(|_| SetterResult::Denied));
    assert!(f.server.tick().is_none());
    TIME.set(121.);
    assert!(f.req(6, Some(id), None).is_none());
    assert!(snapshot(&mut f).retry.is_some());
    POWER.set(0);
    f.server.tick().unwrap();
    assert_eq!(snapshot(&mut f).completed, Some(id));
    assert_eq!(SETTERS.get(), 2);
}

#[test]
fn early_crash_without_attempt_is_cleanup_only_after_confirmed_no() {
    for (power, busy, should_clear) in [
        (0, false, true),
        (0, true, false),
        (1, false, false),
        (-1, false, false),
    ] {
        let mut f = Fixture::new();
        let id = f.begin(None);
        let mut pending = snapshot(&mut f).record.unwrap();
        pending.phase = Phase::Pending;
        pending.attempt = None;
        f.server
            .store
            .transaction(|t| t.replace(Some(pending)))
            .unwrap();
        let h = f.watchdog();
        IDLE.set(!busy);
        POWER.set(power);
        assert_eq!(
            f.server
                .store
                .transaction(|t| reconcile(&h, t, None))
                .is_some(),
            should_clear
        );
        assert_eq!(snapshot(&mut f).completed == Some(id), should_clear);
        assert_eq!(SETTERS.get(), 1);
    }
}

#[test]
fn remembered_ownership_is_not_recreated_by_a_reappearing_or_replaced_record() {
    for same in [true, false] {
        let mut f = Fixture::new();
        let id = f.begin(None);
        let original = snapshot(&mut f).record.unwrap();
        f.server.store.transaction(|t| t.replace(None)).unwrap();
        assert!(f.req(6, Some(id), None).is_none());
        let mut replacement = original;
        if !same {
            replacement.id = new_id();
        }
        f.server
            .store
            .transaction(|t| t.replace(Some(replacement)))
            .unwrap();
        assert!(f.req(6, Some(id), None).is_none());
        assert!(f.req(3, Some(id), None).is_none());
        assert_eq!(SETTERS.get(), 1);
    }
}

#[test]
fn recovery_clock_fault_starts_a_fresh_interval_without_repeating_setter() {
    let mut f = Fixture::new();
    f.begin(None);
    let h = f.watchdog();
    TIME.set(110.);
    SETTER_HOOK.set(Some(|_| SetterResult::Unconfirmed));
    assert!(f
        .server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .is_none());
    for invalid in [f64::NAN, 109.] {
        TIME.set(invalid);
        assert!(f
            .server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .is_none());
        assert!(snapshot(&mut f).retry.unwrap().clock_fault);
    }
    TIME.set(120.);
    f.server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .unwrap();
    let r = snapshot(&mut f).retry.unwrap();
    assert_eq!(r.since, 120.);
    assert!(!r.clock_fault);
    SETTER_HOOK.set(None);
    TIME.set(419.999);
    f.server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .unwrap();
    assert_eq!(SETTERS.get(), 2);
    TIME.set(420.);
    f.server
        .store
        .transaction(|t| reconcile(&h, t, None))
        .unwrap();
    assert_eq!(POWER.get(), 0);
}

#[test]
fn live_process_identity_uses_same_boot_uid_and_start_stamp() {
    let f = Fixture::new();
    let real = f.peer.process.unwrap();
    assert_eq!(active(&real), Some(true));
    let mut old = real.clone();
    old.seconds += 1;
    assert_eq!(active(&old), Some(false));
    let mut other = real.clone();
    other.uid += 1;
    assert_eq!(active(&other), Some(false));
    let mut boot = real.clone();
    boot.boot = new_id();
    assert_eq!(active(&boot), None);
    let mut missing = real;
    missing.pid = -1;
    assert_eq!(active(&missing), None);
}

#[test]
fn changed_safety_does_not_revive_authority_after_failed_critical_restore() {
    let mut f = Fixture::new();
    let id = f.begin(None);
    SAFETY.set((3, 1));
    SETTER_HOOK.set(Some(|_| SetterResult::Unconfirmed));
    assert!(f.server.tick().is_none());
    let before = snapshot(&mut f);
    SAFETY.set((0, 1));
    TIME.set(101.);
    for op in [1, 2, 6] {
        assert!(f.req(op, Some(id), None).is_none());
    }
    assert_eq!(snapshot(&mut f), before);
    assert_eq!(SETTERS.get(), 2);
    let h = f.watchdog();
    SETTER_HOOK.set(None);
    let ticket = f.server.store.transaction(|t| Some(t.ticket())).unwrap();
    f.server
        .store
        .transaction(|t| reconcile(&h, t, Some((id, &ticket))))
        .unwrap();
    assert_eq!((POWER.get(), SLEEP.get()), (0, 0));
}

#[test]
fn failed_durable_commit_after_operation_does_not_synthesize_success() {
    thread_local! {static FILE:std::cell::RefCell<std::path::PathBuf>=Default::default();}
    let mut f = Fixture::new();
    let id = f.begin(None);
    let path = f.folder.path().join("authority.json");
    FILE.with(|p| *p.borrow_mut() = path.clone());
    SETTER_HOOK.set(Some(|_| {
        POWER.set(0);
        FILE.with(|p| std::fs::write(&*p.borrow(), b"changed").unwrap());
        SetterResult::Confirmed
    }));
    assert!(f.req(3, Some(id), None).is_none());
    assert!(f.req(7, Some(id), None).is_none());
    assert_eq!(std::fs::read(path).unwrap(), b"changed");
    assert_eq!((POWER.get(), SETTERS.get(), SLEEP.get()), (0, 2, 0));
}
