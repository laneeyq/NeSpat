use crate::{
    automatic::{nespat_auto_decide, Action, Observation},
    policy::nespat_assess,
    session::{nespat_session_heartbeat, Session, SessionObservation},
};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(f64::NAN, |t| t.as_secs_f64() - 978307200.0)
}
#[derive(Clone, Copy, PartialEq)]
struct Lease {
    id: [u8; 16],
    boot: [u8; 16],
    deadline: Option<f64>,
    expires: Option<f64>,
    selected: bool,
}
impl SessionObservation {
    fn lease(&self) -> Option<Lease> {
        self.has_session.then_some(Lease {
            id: self.id,
            boot: self.boot,
            deadline: self.deadline.is_finite().then_some(self.deadline),
            expires: self.expires.is_finite().then_some(self.expires),
            selected: self.selected,
        })
    }
}
#[derive(Clone, Default)]
pub struct Status {
    pub phase: Phase,
    pub reason: Option<String>,
    pub error: Option<String>,
    pub deadline: Option<f64>,
    pub finished: bool,
    pub power: i8,
}
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub enum Phase {
    #[default]
    Off,
    Preparing,
    Prepared,
    Closed,
    Recovering,
    Blocked,
    Fault,
}
impl Status {
    pub fn title(&self) -> &str {
        match self.phase {
            Phase::Off => "Автоматический режим выключен",
            Phase::Preparing => "Подготовка Mac к закрытию крышки",
            Phase::Prepared => "Mac подготовлен",
            Phase::Closed => "Крышка закрыта · запрет сна подтверждён",
            Phase::Recovering => "Восстановление сна ещё не подтверждено",
            Phase::Blocked | Phase::Fault => self
                .reason
                .as_deref()
                .unwrap_or("Состояние не подтверждено"),
        }
    }
}
pub trait SessionBackend {
    fn observe(&mut self) -> Option<SessionObservation>;
    fn prepare(&mut self) -> bool;
    fn keep_alive(&mut self, id: [u8; 16]) -> bool;
    fn display(&mut self, id: [u8; 16]) -> bool;
    fn recover(&mut self, id: [u8; 16], manual: bool) -> bool;
}
impl SessionBackend for Session {
    fn observe(&mut self) -> Option<SessionObservation> {
        Session::observe(self)
    }
    fn prepare(&mut self) -> bool {
        Session::prepare(self)
    }
    fn keep_alive(&mut self, id: [u8; 16]) -> bool {
        nespat_session_heartbeat(self, &id)
    }
    fn display(&mut self, id: [u8; 16]) -> bool {
        Session::display(self, id)
    }
    fn recover(&mut self, id: [u8; 16], manual: bool) -> bool {
        Session::recover(self, id, manual)
    }
}
pub type Driver = SessionDriver<Session>;
pub struct SessionDriver<B> {
    backend: B,
    known: Option<Lease>,
    last: f64,
    exhausted: bool,
    displayed: Option<[u8; 16]>,
    display_error: bool,
    pub status: Status,
}
impl<B: Default> Default for SessionDriver<B> {
    fn default() -> Self {
        Self {
            backend: Default::default(),
            known: None,
            last: 0.0,
            exhausted: false,
            displayed: None,
            display_error: false,
            status: Status {
                power: -1,
                ..Default::default()
            },
        }
    }
}
impl<B: SessionBackend> SessionDriver<B> {
    fn phase(&mut self, phase: Phase, reason: Option<&str>) {
        self.status.phase = phase;
        self.status.reason = reason.map(str::to_owned);
    }
    pub fn can_exit(&self) -> bool {
        self.known.is_none() && self.status.error.is_none()
    }
    pub fn new_intent(&mut self) {
        self.exhausted = false;
        self.status.finished = false;
    }
    pub fn poll(&mut self, desired: &AtomicBool) {
        if self.known.is_none() && !desired.load(Ordering::Acquire) && self.status.error.is_none() {
            self.phase(Phase::Off, None);
            return;
        }
        if self.known.is_none() && self.exhausted {
            self.phase(
                Phase::Blocked,
                Some("Предыдущая сессия завершена; требуется новое разрешение"),
            );
            return;
        }
        if self.evaluate(desired, false).is_none() {
            self.status.power = -1;
            let msg = "Операция не подтверждена; обычный сон необходимо проверить";
            self.status.error = Some(msg.into());
            self.phase(Phase::Fault, Some(msg));
        }
        self.status.finished = self.exhausted && self.known.is_none();
        self.status.deadline = self.known.and_then(|r| r.deadline);
    }
    fn evaluate(&mut self, desired: &AtomicBool, prepared: bool) -> Option<()> {
        let o = self.backend.observe()?;
        self.status.power = o.power;
        let lease = o.lease();
        let input = Observation {
            now: o.now,
            wall: wall(),
            last_time: self.last,
            expires: o.expires,
            deadline: o.deadline,
            maximum: 43200.0,
            has_expiry: o.expires.is_finite(),
            has_deadline: o.deadline.is_finite(),
            has_lease: lease.is_some(),
            selected_lifetime: o.selected,
            service_verified: true,
            authorized: o.permitted,
            active_user: o.active_user,
            recovery_only: o.recovery_only,
            foreign_owner: o.foreign_owner,
            known: self.known.is_some(),
            boot_matches: lease.is_some_and(|r| r.boot == o.boot),
            known_boot_matches: self.known.is_some_and(|r| r.boot == o.boot),
            lease_matches: lease == self.known,
            start_safe: nespat_assess(o.battery, o.ac, o.temp, o.thermal, true) == 0,
            running_safe: nespat_assess(o.battery, o.ac, o.temp, o.thermal, false) == 0,
            desired: desired.load(Ordering::Acquire),
            exhausted: self.exhausted,
            lid_closed: o.lid,
            sleep_disabled: o.power,
        };
        let decision = nespat_auto_decide(input, prepared);
        if decision.record_time {
            self.last = o.now;
        }
        if decision.adopt_lease {
            self.known = lease;
        }
        if decision.forget_lease {
            self.known = None;
            self.status.error = None;
        }
        if decision.mark_finished {
            self.exhausted = true;
        }
        match decision.action {
            Action::Prepare => {
                self.phase(Phase::Preparing, None);
                if !self.backend.prepare() {
                    return None;
                }
                return self.evaluate(desired, true);
            }
            Action::Off => {
                self.phase(Phase::Off, None);
                self.status.error = None;
            }
            Action::Restore => {
                self.restore(lease?, false, desired);
            }
            Action::KeepActive => {
                let id = lease?.id;
                if !prepared && !self.backend.keep_alive(id) {
                    return None;
                }
                if o.lid == 0 {
                    self.displayed = None;
                    self.display_error = false;
                } else if self.displayed != Some(id) {
                    self.displayed = Some(id);
                    self.display_error = !self.backend.display(id);
                }
                self.status.error = self
                    .display_error
                    .then(|| "Не удалось погасить экран. Сессия продолжается.".into());
                self.phase(
                    if o.lid == 1 {
                        Phase::Closed
                    } else {
                        Phase::Prepared
                    },
                    None,
                );
            }
            action => {
                let reason = match action {
                    Action::Unverified => "Фоновая служба не проверена",
                    Action::Clock => "Неподтверждённое время",
                    Action::Ownership => "Владение автоматической сессией не подтверждено",
                    Action::Replaced => "Запись автоматической сессии изменилась",
                    Action::Lost => "Журнал утрачен; сон не подтверждён",
                    Action::Foreign => "Системный сон или чужое владение не подтверждены",
                    Action::Finished => "Предыдущая сессия завершена; требуется новое разрешение",
                    Action::Unauthorized => "Требуется подтверждённая первоначальная настройка",
                    Action::OpenLid => {
                        "Для подготовки нужен активный пользователь и открытая крышка"
                    }
                    Action::Unsafe => "Датчики неполны или условия небезопасны",
                    _ => "Подготовка или владение не подтверждены",
                };
                self.phase(
                    if action == Action::Unconfirmed {
                        Phase::Fault
                    } else {
                        Phase::Blocked
                    },
                    Some(reason),
                );
            }
        }
        Some(())
    }
    pub fn manual(&mut self, desired: &AtomicBool) {
        let Some(o) = self.backend.observe() else {
            self.status.power = -1;
            self.status.error = Some("Ручное восстановление не подтверждено".into());
            return;
        };
        self.status.power = o.power;
        let Some(lease) = o
            .lease()
            .filter(|v| !o.foreign_owner && (self.known.is_none() || self.known == Some(*v)))
        else {
            self.phase(Phase::Blocked, Some("Владение не подтверждено"));
            return;
        };
        self.known = Some(lease);
        self.restore(lease, true, desired);
        self.status.deadline = self.known.and_then(|r| r.deadline);
    }
    fn restore(&mut self, lease: Lease, manual: bool, desired: &AtomicBool) {
        self.phase(Phase::Recovering, None);
        if let Some(o) = self
            .backend
            .recover(lease.id, manual)
            .then(|| self.backend.observe())
            .flatten()
        {
            self.status.power = o.power;
            if o.boot == lease.boot && o.power == 0 && !o.has_session && !o.foreign_owner {
                if !manual {
                    self.exhausted = desired.load(Ordering::Acquire);
                }
                self.known = None;
                self.status.error = None;
                self.phase(Phase::Off, None);
                return;
            }
            self.status.error = Some("Обычный сон ещё не подтверждён".into());
        } else {
            self.status.power = -1;
            self.status.error = Some(
                if manual {
                    "Ручное восстановление не подтверждено"
                } else {
                    "Восстановление не подтверждено; повтор контролирует фоновая служба"
                }
                .into(),
            );
        }
    }
}

#[cfg(test)]
mod regression {
    use super::*;
    use std::collections::VecDeque;
    #[derive(Default)]
    struct Backend {
        observations: VecDeque<Option<SessionObservation>>,
        actions: Vec<&'static str>,
        reject_display: bool,
        reject_heartbeat: bool,
        reject_recovery: bool,
    }
    impl SessionBackend for Backend {
        fn observe(&mut self) -> Option<SessionObservation> {
            self.observations
                .pop_front()
                .expect("unexpected observation")
        }
        fn prepare(&mut self) -> bool {
            self.actions.push("prepare");
            true
        }
        fn keep_alive(&mut self, _: [u8; 16]) -> bool {
            self.actions.push("heartbeat");
            !self.reject_heartbeat
        }
        fn display(&mut self, _: [u8; 16]) -> bool {
            self.actions.push("display");
            !self.reject_display
        }
        fn recover(&mut self, _: [u8; 16], manual: bool) -> bool {
            self.actions.push(if manual { "manual" } else { "restore" });
            !self.reject_recovery
        }
    }
    fn observed(active: bool, lid: i8) -> SessionObservation {
        SessionObservation {
            boot: [1; 16],
            id: [2; 16],
            now: 100.,
            deadline: f64::NAN,
            expires: f64::NAN,
            temp: 40.,
            battery: 90.,
            ac: 0,
            thermal: 0,
            lid,
            power: active as i8,
            has_session: active,
            selected: true,
            active_user: true,
            permitted: true,
            ..Default::default()
        }
    }
    type Model = SessionDriver<Backend>;
    fn tick(m: &mut Model, o: SessionObservation) {
        m.backend.observations.push_back(Some(o));
        m.poll(&AtomicBool::new(true));
    }
    #[test]
    fn opening_a_lid_rearms_one_display_request_per_closure_even_after_failure() {
        for fail in [true, false] {
            let mut m = Model::default();
            m.backend.reject_display = fail;
            for lid in [0, 1, 1, 1, 0, 1, 1] {
                tick(&mut m, observed(true, lid));
            }
            assert_eq!(
                m.backend
                    .actions
                    .iter()
                    .filter(|&&v| v == "display")
                    .count(),
                2
            );
            assert_eq!(m.status.error.is_some(), fail);
            assert!(!m.can_exit());
        }
    }
    #[test]
    fn prepare_reobserves_and_adoption_never_restarts_the_timer() {
        let mut m = Model::default();
        m.backend.observations.push_back(Some(observed(false, 0)));
        let finite = || SessionObservation {
            expires: 4000.,
            deadline: wall().floor() + 3900.,
            ..observed(true, 0)
        };
        let first = finite();
        let deadline = first.deadline;
        m.backend.observations.push_back(Some(first));
        m.poll(&AtomicBool::new(true));
        assert_eq!(m.backend.actions, ["prepare"]);
        assert_eq!(m.status.deadline, Some(deadline));
        tick(
            &mut m,
            SessionObservation {
                expires: 4000.,
                deadline,
                ..observed(true, 1)
            },
        );
        assert_eq!(m.status.deadline, Some(deadline));
        assert_eq!(m.backend.actions, ["prepare", "heartbeat", "display"]);
    }
    #[test]
    fn missing_response_foreign_replacement_and_lost_journal_never_clear_owned_session() {
        for cause in [
            "transport",
            "foreign",
            "replaced",
            "missing",
            "boot",
            "unknown",
        ] {
            let mut m = Model::default();
            tick(&mut m, observed(true, 0));
            m.backend.actions.clear();
            let mut o = observed(true, 0);
            match cause {
                "transport" => m.backend.observations.push_back(None),
                _ => {
                    match cause {
                        "foreign" => o.foreign_owner = true,
                        "replaced" => o.id = [7; 16],
                        "missing" => o.has_session = false,
                        "boot" => o.boot = [9; 16],
                        "unknown" => {
                            o.has_session = false;
                            o.power = -1;
                        }
                        _ => unreachable!(),
                    }
                    m.backend.observations.push_back(Some(o));
                }
            }
            m.poll(&AtomicBool::new(true));
            assert!(!m.can_exit(), "{cause}");
            assert!(m.backend.actions.is_empty(), "{cause}");
        }
    }
    #[test]
    fn cancellation_or_unconfirmed_recovery_cannot_report_completion() {
        for fault in [
            "failed",
            "noReply",
            "stillDisabled",
            "newBoot",
            "stillOwned",
            "foreign",
            "confirmed",
        ] {
            let mut m = Model::default();
            tick(&mut m, observed(true, 0));
            m.backend.actions.clear();
            m.backend.observations.push_back(Some(observed(true, 0)));
            let mut after = observed(false, 0);
            match fault {
                "failed" => m.backend.reject_recovery = true,
                "noReply" => m.backend.observations.push_back(None),
                _ => {
                    match fault {
                        "stillDisabled" => after.power = 1,
                        "newBoot" => after.boot = [8; 16],
                        "stillOwned" => after.has_session = true,
                        "foreign" => after.foreign_owner = true,
                        _ => {}
                    }
                    m.backend.observations.push_back(Some(after));
                }
            }
            m.manual(&AtomicBool::new(false));
            assert_eq!(m.backend.actions, ["manual"]);
            assert_eq!(m.can_exit(), fault == "confirmed", "{fault}");
        }
    }
    #[test]
    fn threshold_crossing_and_loss_of_sensors_request_recovery_then_confirm() {
        for case in [
            "battery",
            "thermal",
            "temp",
            "unavailable",
            "disabled",
            "logout",
            "expired",
            "unknownLid",
            "recoveryOnly",
        ] {
            let mut m = Model::default();
            let mut o = observed(true, 1);
            match case {
                "battery" => o.battery = 10.,
                "thermal" => o.thermal = 1,
                "temp" => o.temp = 95.,
                "unavailable" => o.temp = f64::NAN,
                "disabled" => o.permitted = false,
                "logout" => o.active_user = false,
                "expired" => {
                    o.expires = 99.;
                    o.deadline = 1.;
                }
                "unknownLid" => o.lid = -1,
                "recoveryOnly" => o.recovery_only = true,
                _ => unreachable!(),
            }
            m.backend
                .observations
                .extend([Some(o), Some(observed(false, 0))]);
            m.poll(&AtomicBool::new(true));
            assert_eq!(m.backend.actions, ["restore"], "{case}");
            assert!(m.can_exit());
        }
    }
    #[test]
    fn expired_session_does_not_immediately_rearm_after_ordinary_sleep() {
        let mut m = Model::default();
        tick(&mut m, observed(true, 0));
        tick(&mut m, observed(false, 0));
        m.backend.actions.clear();
        m.poll(&AtomicBool::new(true));
        assert!(m.backend.actions.is_empty());
        assert!(m.status.finished);
        m.new_intent();
        m.backend
            .observations
            .extend([Some(observed(false, 0)), Some(observed(true, 0))]);
        m.poll(&AtomicBool::new(true));
        assert_eq!(m.backend.actions, ["prepare"]);
    }
}
