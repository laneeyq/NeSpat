use crate::{
    battery::nespat_current_battery,
    driver::{Phase, Status},
    format::duration,
    host::boot,
    observation::nespat_sleep_disabled,
    profile::{nespat_profile_enabled, Profile},
    pulse,
    stats::*,
};
use objc2_foundation::NSProcessInfo;
#[derive(Clone)]
pub(crate) struct Readings {
    pub values: [String; 4],
    pub fractions: [f64; 4],
    pub header: String,
    pub note: String,
    pub power: i8,
    pub helper: bool,
    pub watchdog: bool,
    pub permitted: bool,
}
impl Default for Readings {
    fn default() -> Self {
        Self {
            values: std::array::from_fn(|_| "—".into()),
            fractions: [f64::NAN; 4],
            header: "— — —".into(),
            note: String::new(),
            power: -1,
            helper: false,
            watchdog: false,
            permitted: false,
        }
    }
}
fn percent(n: f64, suffix: &str) -> String {
    if n.is_finite() {
        format!("{n:.0}{suffix}")
    } else {
        "—".into()
    }
}
fn memory(bytes: u64) -> String {
    let gb = bytes as f64 / 1073741824.;
    if gb < 10. {
        format!("{gb:.1} ГБ")
    } else {
        format!("{gb:.0} ГБ")
    }
}
impl Readings {
    pub(crate) fn sample(sampler: &mut Sampler) -> Self {
        let cpu = unsafe { nespat_sampler_cpu(sampler) };
        let temp = crate::nespat_chip_temperature();
        let total = NSProcessInfo::processInfo().physicalMemory();
        let used = nespat_used_memory(unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as u64);
        let mem = used as f64 / total as f64;
        let battery = nespat_current_battery();
        let source = match battery.external {
            1 => "внешнее питание",
            0 => "от батареи",
            _ => "источник неизвестен",
        };
        let mut note = Vec::new();
        if battery.charging == 1 {
            note.push("Заряжается".into());
        } else if battery.charged == 1 {
            note.push("Заряжена".into());
        }
        if battery.minutes > 0 {
            note.push(format!(
                "{} ≈ {} ч {} мин",
                if battery.charging == 1 {
                    "До зарядки"
                } else {
                    "Осталось"
                },
                battery.minutes / 60,
                battery.minutes % 60
            ));
        }
        let mut r = Self {
            values: [
                percent(temp, " °C"),
                percent(cpu, "%"),
                format!("{} из {}", memory(used), memory(total)),
                if battery.percent.is_finite() {
                    format!("{} · {source}", percent(battery.percent, "%"))
                } else {
                    "—".into()
                },
            ],
            fractions: [(temp - 25.) / 60., cpu / 100., mem, battery.percent / 100.],
            header: format!(
                "{} {} {}",
                percent(temp, "°"),
                percent(cpu, "%"),
                percent(mem * 100., "%")
            ),
            note: note.join("   "),
            power: nespat_sleep_disabled(),
            ..Self::default()
        };
        if let (Some(p), Some(b)) = (Profile::load(), boot()) {
            r.permitted = nespat_profile_enabled(&p);
            r.helper = pulse::available(b, p.setup, false);
            r.watchdog = pulse::available(b, p.setup, true);
        }
        r
    }
    pub fn active(&self, state: &Status) -> bool {
        self.power == 1 && matches!(state.phase, Phase::Prepared | Phase::Closed)
    }
    pub fn title(&self, state: &Status) -> String {
        let bad = state.error.is_some()
            || !self.helper
            || !self.watchdog
            || self.power < 0
            || matches!(
                state.phase,
                Phase::Blocked | Phase::Fault | Phase::Recovering
            );
        let prefix = if bad {
            "⚠ "
        } else if self.active(state) {
            "☕ "
        } else if self.power == 1 {
            "⚠ "
        } else {
            ""
        };
        format!("{prefix}{}", self.header)
    }
    pub fn summary(&self, state: &Status, requested: bool, now: f64) -> String {
        if self.active(state) {
            return state.deadline.map_or_else(
                || "Включено · без лимита".into(),
                |end| format!("Включено · осталось {}", duration(end - now)),
            );
        }
        (if !self.helper {
            "Служба NeSpat недоступна"
        } else if !self.watchdog {
            "Служба восстановления недоступна"
        } else if state.error.is_some() && self.power == 0 {
            "Сон разрешён · проверяем завершение сессии"
        } else if requested || state.phase == Phase::Recovering {
            state.title()
        } else if self.power == 1 {
            "Запрет сна включён · владение не подтверждено"
        } else if self.power < 0 {
            "Не удалось подтвердить состояние сна"
        } else if self.permitted {
            "Выключено · обычный сон"
        } else {
            "Выключено · требуется разрешение администратора"
        })
        .into()
    }
}
pub(crate) struct Monitor {
    sample: std::sync::Arc<std::sync::Mutex<Readings>>,
    _stop: std::sync::mpsc::Sender<()>,
}
impl Monitor {
    pub(crate) fn new() -> Self {
        let sample = std::sync::Arc::new(std::sync::Mutex::new(Readings::default()));
        let target = sample.clone();
        let (stop, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut sampler = unsafe { Box::from_raw(nespat_sampler_create()) };
            loop {
                let fresh = objc2::rc::autoreleasepool(|_| Readings::sample(&mut sampler));
                *target.lock().unwrap() = fresh;
                if !matches!(
                    rx.recv_timeout(std::time::Duration::from_secs(2)),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
        });
        Self {
            sample,
            _stop: stop,
        }
    }
    pub fn read(&self) -> Readings {
        self.sample.lock().unwrap().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn countdown_renders_from_deadline_without_extending_the_session() {
        let r = Readings {
            power: 1,
            helper: true,
            watchdog: true,
            ..Default::default()
        };
        let mut state = Status {
            phase: Phase::Prepared,
            deadline: Some(3661.),
            ..Default::default()
        };
        assert!(r.summary(&state, true, 0.).ends_with("1 ч 01 мин 01 с"));
        assert!(r.summary(&state, true, 3659.9).ends_with("2 с"));
        assert!(r.summary(&state, true, 3700.).ends_with("0 с"));
        assert_eq!(state.deadline, Some(3661.));
        assert!(r.title(&state).starts_with("☕"));
        state.error = Some("проверка".into());
        assert!(r.title(&state).starts_with("⚠"));
        state.deadline = None;
        assert!(r.summary(&state, true, 3700.).ends_with("без лимита"));
    }
}
