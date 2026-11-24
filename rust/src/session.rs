use crate::{
    battery::nespat_current_battery,
    client::{new_id, Client},
    host::{boot, nespat_continuous_seconds},
    observation::{nespat_active_uid, nespat_lid_closed, nespat_sleep_disabled},
    policy::nespat_parse_minutes,
    profile::{nespat_profile_enabled, Profile},
    request::{uuid, uuid_text, Request},
};
use objc2_foundation::{NSProcessInfo, NSString, NSUserDefaults};
use serde_json::Value;
use std::{
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Session {
    client: Option<Client>,
    cached: Option<Value>,
    last_rpc: Option<f64>,
    sequence: i64,
}

#[repr(C)]
#[derive(Default)]
pub struct SessionObservation {
    pub(crate) boot: [u8; 16],
    pub(crate) id: [u8; 16],
    pub(crate) now: f64,
    pub(crate) deadline: f64,
    pub(crate) expires: f64,
    pub(crate) battery: f64,
    pub(crate) temp: f64,
    pub(crate) has_session: bool,
    pub(crate) selected: bool,
    pub(crate) foreign_owner: bool,
    pub(crate) recovery_only: bool,
    pub(crate) permitted: bool,
    pub(crate) active_user: bool,
    pub(crate) lid: i8,
    pub(crate) power: i8,
    pub(crate) ac: i8,
    pub(crate) thermal: i8,
}
fn request(op: u8, session: Option<[u8; 16]>) -> Request {
    Request {
        id: new_id(),
        operation: op,
        session: session.unwrap_or_default(),
        has_session: session.is_some(),
        ..Default::default()
    }
}
fn session_id(reply: &Value) -> Option<[u8; 16]> {
    uuid(reply["session"].as_str()?)
}
fn selected_minutes() -> Option<Option<i64>> {
    let defaults = NSUserDefaults::standardUserDefaults();
    let key = NSString::from_str("exclusive.durationChoice");
    let selection = if defaults.objectForKey(&key).is_some() {
        defaults.integerForKey(&key)
    } else {
        60
    };
    match selection {
        0 => Some(None),
        60 | 180 | 480 => Some(Some(selection as i64)),
        -1 => {
            let minutes = defaults
                .stringForKey(&NSString::from_str("exclusive.customMinutes"))
                .map_or_else(|| "30".to_owned(), |s| s.to_string());
            let seconds = unsafe { nespat_parse_minutes(minutes.as_ptr(), minutes.len()) };
            (seconds > 0).then_some(Some(seconds / 60))
        }
        _ => None,
    }
}
fn run_fixed(path: &str, args: &[&str]) -> bool {
    let Ok(mut child) = Command::new(path)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let until = Instant::now() + Duration::from_secs(120);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < until => thread::sleep(Duration::from_millis(30)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}
impl Session {
    fn call(&mut self, req: Request) -> Option<Value> {
        if self.client.is_none() {
            self.client = Client::connect();
        }
        let reply = self
            .client
            .as_mut()
            .and_then(|client| client.request(&req))
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        if reply.is_none() {
            self.client = None;
        }
        self.cached = reply.clone();
        self.last_rpc = reply.as_ref().map(|_| nespat_continuous_seconds());
        reply
    }
    pub(crate) fn heartbeat(&mut self, id: [u8; 16]) -> Option<Value> {
        self.sequence = self.sequence.checked_add(1)?;
        let mut req = request(6, Some(id));
        req.has_sequence = self
            .cached
            .as_ref()
            .is_some_and(|r| r["selectedLifetime"] == true);
        req.sequence = self.sequence;
        self.call(req)
    }
    fn read_status(&mut self) -> Option<Value> {
        let time = nespat_continuous_seconds();
        if let Some(cached) = &self.cached {
            let id = session_id(cached);
            if id.is_some() && nespat_sleep_disabled() == 0 {
                let reply = self.call(request(0, None))?;
                if session_id(&reply).is_none() && reply["state"] == "enabled" {
                    self.client = None;
                    self.cached = None;
                }
                return Some(reply);
            }
            if self
                .last_rpc
                .is_some_and(|last| (0.0..18.0).contains(&(time - last)))
            {
                return Some(cached.clone());
            }
            if let Some(id) = id.filter(|_| cached["fullAuthority"] == true) {
                return self.heartbeat(id);
            }
        }
        self.call(request(0, None))
    }
    pub(crate) fn observe(&mut self) -> Option<SessionObservation> {
        let reply = self.read_status()?;
        let id = session_id(&reply);
        let selected = reply["selectedLifetime"] == true;
        let deadline = reply["deadline"].as_f64();
        let expires = reply["authorityExpires"].as_f64();
        let lease = reply["active"] == true
            && id.is_some()
            && deadline.is_some() == expires.is_some()
            && (selected || deadline.is_some());
        let battery = nespat_current_battery();
        let thermal = match NSProcessInfo::processInfo().thermalState().0 {
            0 | 1 => 0,
            2 | 3 => 1,
            _ => -1,
        };
        Some(SessionObservation {
            boot: boot()?,
            id: id.unwrap_or_default(),
            now: nespat_continuous_seconds(),
            deadline: deadline.unwrap_or(f64::NAN),
            expires: expires.unwrap_or(f64::NAN),
            battery: battery.percent,
            temp: crate::nespat_chip_temperature(),
            has_session: lease,
            selected,
            foreign_owner: id.is_some() && !lease,
            recovery_only: lease && reply["fullAuthority"] != true,
            permitted: Profile::load().is_some_and(|p| nespat_profile_enabled(&p)),
            active_user: nespat_active_uid() == unsafe { libc::getuid() },
            lid: nespat_lid_closed(),
            power: nespat_sleep_disabled(),
            ac: battery.external,
            thermal,
        })
    }
    pub(crate) fn prepare(&mut self) -> bool {
        let Some(minutes) = selected_minutes() else {
            return false;
        };
        let mut req = request(1, None);
        req.has_minutes = minutes.is_some();
        req.minutes = minutes.unwrap_or(0);
        self.call(req).is_some()
    }
    pub(crate) fn recover(&mut self, id: [u8; 16], manual: bool) -> bool {
        if !manual {
            let Some(r) = self.call(request(7, Some(id))) else {
                return false;
            };
            if r["state"] == "enabled" && session_id(&r).is_none() {
                self.client = None;
            }
            return true;
        }
        let Some(reply) = self.call(request(0, None)) else {
            return false;
        };
        let Some(ticket) = reply["recoveryTicket"]
            .as_str()
            .filter(|_| session_id(&reply) == Some(id))
        else {
            return false;
        };
        // Ticket and UUID have already passed strict wire validation. Only the
        // installed, pinned helper may be invoked by the authorization dialog.
        let Some(profile) = Profile::load() else {
            return false;
        };
        let Some(helper) = profile.verified_recovery_helper() else {
            return false;
        };
        let script=format!("do shell script \"'{helper}' --approved-recovery {} {ticket}\" with administrator privileges",uuid_text(&id));
        if !run_fixed("/usr/bin/osascript", &["-e", &script]) || nespat_sleep_disabled() != 0 {
            return false;
        }
        self.cached = None;
        true
    }
    pub(crate) fn confirms_display(&self, id: [u8; 16]) -> bool {
        self.cached.as_ref().is_some_and(|r| {
            r["active"] == true && r["fullAuthority"] == true && session_id(r) == Some(id)
        })
    }
    pub(crate) fn display(&self, id: [u8; 16]) -> bool {
        if !self.confirms_display(id)
            || nespat_active_uid() != unsafe { libc::getuid() }
            || nespat_sleep_disabled() != 1
            || nespat_lid_closed() != 1
        {
            return true;
        }
        run_fixed("/usr/bin/pmset", &["displaysleepnow"])
    }
}
#[no_mangle]
pub extern "C" fn nespat_session_new() -> *mut Session {
    Box::into_raw(Box::default())
}
#[no_mangle]
pub unsafe extern "C" fn nespat_session_drop(s: *mut Session) {
    drop(Box::from_raw(s))
}
#[no_mangle]
pub extern "C" fn nespat_session_observe(s: &mut Session, out: &mut SessionObservation) -> bool {
    let Some(value) = s.observe() else {
        return false;
    };
    *out = value;
    true
}
#[no_mangle]
pub extern "C" fn nespat_session_prepare(s: &mut Session) -> bool {
    s.prepare()
}
#[no_mangle]
pub extern "C" fn nespat_session_recover(s: &mut Session, id: &[u8; 16], manual: bool) -> bool {
    s.recover(*id, manual)
}
#[no_mangle]
pub extern "C" fn nespat_session_display(s: &Session, id: &[u8; 16]) -> bool {
    s.display(*id)
}
#[no_mangle]
pub extern "C" fn nespat_session_heartbeat(s: &mut Session, id: &[u8; 16]) -> bool {
    if s.last_rpc
        .is_some_and(|last| !(nespat_continuous_seconds() - last >= 12.0))
    {
        return true;
    }
    s.heartbeat(*id).is_some()
}
