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
pub struct Driver {
    backend: Session,
    known: Option<Lease>,
    last: f64,
    exhausted: bool,
    displayed: Option<[u8; 16]>,
    display_error: bool,
    pub status: Status,
}
impl Default for Driver {
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
impl Driver {
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
                if !prepared && !nespat_session_heartbeat(&mut self.backend, &id) {
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
