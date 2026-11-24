#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_then_late_confirmation_cannot_rearm_input() {
        let guard = Guard {
            state: Default::default(),
            thread: thread::current(),
        };
        let permit = Some(Permit {
            id: [7; 16],
            checked: clock(),
            expires: None,
            deadline: None,
        });
        guard.publish(0, permit);
        assert!(guard.state.lock().unwrap().key().is_some());
        guard.revoke(1);
        guard.publish(0, permit);
        assert!(guard.state.lock().unwrap().key().is_none());
        guard.publish(1, permit);
        guard.stop();
        guard.publish(1, permit);
        assert!(guard.state.lock().unwrap().key().is_none());
    }

    #[test]
    fn mixed_displays_retry_only_for_a_confirmed_awake_screen() {
        assert_eq!(summarize([None, Some(false), Some(true)]), Some(true));
        assert_eq!(summarize([Some(false), Some(false)]), Some(false));
        assert_eq!(summarize([Some(false), None]), None);
        assert_eq!(summarize([]), None);
    }
    #[test]
    fn expired_or_unknown_authority_never_authorizes_a_display_retry() {
        let p = Permit {
            id: [2; 16],
            checked: 30.,
            expires: Some(36.),
            deadline: Some(124.),
        };
        assert!(p.valid(30., 120.));
        for (now, wall) in [(29., 121.), (36., 122.), (32., 124.), (f64::NAN, 120.)] {
            assert!(!p.valid(now, wall));
        }
        let p = Permit {
            expires: None,
            deadline: None,
            ..p
        };
        assert!(!p.valid(38., 121.));
    }
    #[test]
    fn independent_media_controls_do_not_get_seized() {
        assert!(!crate::external_input::capture_interface(
            false, true, false
        ));
        assert!(crate::external_input::capture_interface(false, true, true));
        assert!(crate::external_input::capture_interface(true, false, false));
        assert!(!crate::external_input::capture_interface(
            false, false, true
        ));
    }
    #[test]
    fn only_retry_awake_displays_after_cooldown_and_rearm_on_open() {
        let mut g = Throttle::default();
        assert!(g.request(1., None));
        assert!(!g.request(2., Some(true)));
        assert!(!g.request(6., None));
        assert!(!g.request(6., Some(false)));
        assert!(g.request(6., Some(true)));
        assert!(!g.request(6., Some(true)));
        g = Throttle::default();
        assert!(g.request(7., Some(false)));
    }

    #[test]
    fn only_external_input_interfaces_are_eligible() {
        for (page, usage) in [(1, 1), (1, 2), (1, 6), (1, 7), (12, 1)] {
            assert!(eligible("USB", false, page, usage));
            assert!(eligible("Bluetooth Low Energy", false, page, usage));
            assert!(!eligible("USB", true, page, usage));
            assert!(!eligible("SPI", false, page, usage));
        }
        assert!(!eligible("USB", false, 1, 0x80));
        assert!(!eligible("USB", false, 0xff00, 1));
    }
}

#[cfg(test)]
use crate::external_input::eligible;
use crate::{
    external_input::Inputs,
    host::nespat_continuous_seconds as clock,
    observation::{nespat_active_uid, nespat_lid_closed, nespat_sleep_disabled},
};
use std::{
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const INTERVAL: f64 = 5.;
static DISPLAY_CHANGED: AtomicBool = AtomicBool::new(false);
static WORKER: Mutex<Option<thread::Thread>> = Mutex::new(None);
pub(crate) fn wake_worker() {
    if let Ok(worker) = WORKER.lock() {
        if let Some(t) = worker.as_ref() {
            t.unpark()
        }
    }
}
pub(crate) fn display_changed() {
    DISPLAY_CHANGED.store(true, Ordering::Release);
    wake_worker();
}
extern "C" fn reconfigured(_: u32, _: u32, _: *mut std::ffi::c_void) {
    display_changed()
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGGetOnlineDisplayList(max: u32, ids: *mut u32, count: *mut u32) -> i32;
    fn CGDisplayIsActive(id: u32) -> u32;
    fn CGDisplayIsAsleep(id: u32) -> u32;
    fn CGDisplayRegisterReconfigurationCallback(
        cb: extern "C" fn(u32, u32, *mut std::ffi::c_void),
        ctx: *mut std::ffi::c_void,
    ) -> i32;
    fn CGDisplayRemoveReconfigurationCallback(
        cb: extern "C" fn(u32, u32, *mut std::ffi::c_void),
        ctx: *mut std::ffi::c_void,
    ) -> i32;
}

fn any_awake() -> Option<bool> {
    let mut count = 0;
    if unsafe { CGGetOnlineDisplayList(0, std::ptr::null_mut(), &mut count) } != 0 || count == 0 {
        return None;
    }
    let mut ids = vec![0; count as usize];
    if unsafe { CGGetOnlineDisplayList(count, ids.as_mut_ptr(), &mut count) } != 0 || count == 0 {
        return None;
    }
    summarize(ids.into_iter().take(count as usize).map(|id| unsafe {
        if CGDisplayIsAsleep(id) != 0 {
            Some(false)
        } else if CGDisplayIsActive(id) != 0 {
            Some(true)
        } else {
            None
        }
    }))
}

fn summarize(states: impl IntoIterator<Item = Option<bool>>) -> Option<bool> {
    let mut result = None;
    let mut unknown = false;
    for state in states {
        match state {
            Some(true) => return Some(true),
            Some(false) => result = Some(false),
            None => unknown = true,
        }
    }
    if unknown {
        None
    } else {
        result
    }
}

#[derive(Default)]
struct Throttle {
    last: Option<f64>,
}
impl Throttle {
    fn request(&mut self, now: f64, awake: Option<bool>) -> bool {
        if self.last.is_none() || (awake == Some(true) && now - self.last.unwrap() >= INTERVAL) {
            self.last = Some(now);
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Permit {
    pub id: [u8; 16],
    pub checked: f64,
    pub expires: Option<f64>,
    pub deadline: Option<f64>,
}
impl Permit {
    fn valid(self, now: f64, wall: f64) -> bool {
        // A stalled XPC worker cannot leave external input seized indefinitely.
        (0.0..8.0).contains(&(now - self.checked))
            && self.expires.is_none_or(|end| now < end)
            && self.deadline.is_none_or(|end| wall < end)
    }
}
fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(f64::NAN, |d| d.as_secs_f64() - 978307200.)
}
fn closed() -> bool {
    nespat_lid_closed() == 1
        && nespat_sleep_disabled() == 1
        && nespat_active_uid() == unsafe { libc::getuid() }
}
#[derive(Default)]
struct State {
    generation: u64,
    permit: Option<Permit>,
    stop: bool,
    notice: Option<&'static str>,
}
impl State {
    fn key(&self) -> Option<(u64, [u8; 16])> {
        self.permit
            .filter(|p| !self.stop && p.valid(clock(), wall()))
            .map(|p| (self.generation, p.id))
    }
}

#[derive(Clone)]
pub(crate) struct Guard {
    state: Arc<Mutex<State>>,
    thread: thread::Thread,
}
impl Guard {
    pub fn start() -> Self {
        let state = Arc::new(Mutex::new(State::default()));
        let shared = state.clone();
        let thread = thread::spawn(move || monitor(shared)).thread().clone();
        Self { state, thread }
    }
    pub fn publish(&self, generation: u64, permit: Option<Permit>) {
        let mut s = self.state.lock().unwrap();
        if !s.stop && s.generation == generation {
            s.permit = permit;
        }
        self.thread.unpark();
    }
    pub fn revoke(&self, generation: u64) {
        let mut s = self.state.lock().unwrap();
        s.generation = generation;
        s.permit = None;
        s.notice = None;
        self.thread.unpark();
    }
    pub fn stop(&self) {
        self.state.lock().unwrap().stop = true;
        self.thread.unpark();
    }
    pub fn notice(&self) -> Option<&'static str> {
        self.state.lock().unwrap().notice
    }
}

#[derive(Default)]
struct ClosedSession {
    key: Option<(u64, [u8; 16])>,
    inputs: Inputs,
    throttle: Throttle,
    next_check: f64,
    input_ok: bool,
    command_ok: bool,
    child: Option<Child>,
}
impl Drop for ClosedSession {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn monitor(shared: Arc<Mutex<State>>) {
    *WORKER.lock().unwrap() = Some(thread::current());
    let _lid = crate::lid_notifications::LidNotifications::register();
    let registered =
        unsafe { CGDisplayRegisterReconfigurationCallback(reconfigured, std::ptr::null_mut()) }
            == 0;
    let mut active = ClosedSession::default();
    loop {
        let (stop, key) = {
            let s = shared.lock().unwrap();
            (s.stop, s.key())
        };
        if stop {
            break;
        }
        let current = key.filter(|_| closed());
        if current != active.key {
            active = ClosedSession::default();
            active.key = current;
            active.command_ok = true;
        }
        if let Some(key) = current {
            let now = clock();
            let changed = DISPLAY_CHANGED.swap(false, Ordering::AcqRel);
            if let Some(child) = active.child.as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        active.command_ok = status.success();
                        active.child = None;
                    }
                    Ok(None) if active.throttle.last.is_some_and(|t| now - t < INTERVAL) => {}
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        active.command_ok = false;
                        active.child = None;
                    }
                }
            }
            if now >= active.next_check || changed {
                if now >= active.next_check {
                    active.input_ok = active.inputs.refresh();
                    active.next_check = now + INTERVAL;
                }
                if active.child.is_none() && active.throttle.request(now, any_awake()) {
                    let s = shared.lock().unwrap();
                    if s.key() == Some(key) && closed() {
                        active.child = Command::new("/usr/bin/pmset")
                            .arg("displaysleepnow")
                            .stdin(Stdio::null())
                            .stdout(Stdio::null())
                            .stderr(Stdio::null())
                            .spawn()
                            .ok();
                        active.command_ok = active.child.is_some();
                    }
                }
            }
        }
        let mut s = shared.lock().unwrap();
        s.notice = if current.is_none() || s.key() != current {
            None
        } else if !active.input_ok {
            Some("Не удалось заблокировать часть устройств ввода. Проверяем сон экранов.")
        } else if !active.command_ok {
            Some("Не удалось погасить экраны. Следующая проверка через 5 секунд.")
        } else {
            None
        };
        drop(s);
        thread::park_timeout(if key.is_some() {
            Duration::from_millis(150)
        } else {
            Duration::from_secs(5)
        });
    }
    drop(active);
    *WORKER.lock().unwrap() = None;
    if registered {
        unsafe {
            CGDisplayRemoveReconfigurationCallback(reconfigured, std::ptr::null_mut());
        }
    }
}
