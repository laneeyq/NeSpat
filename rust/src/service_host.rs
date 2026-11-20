use crate::{
    client::new_id,
    host::{boot, nespat_continuous_seconds},
    observation::nespat_sleep_disabled,
    profile::{nespat_profile_enabled, Profile},
    pulse,
    service_recovery::{self, Host},
    service_store::Store,
    setter::{nespat_setter_idle, nespat_setter_ready},
    signing::nespat_matches_code,
};
use core_foundation::{base::TCFType, string::CFString, url::CFURL};

const APP: &str = "/Library/Application Support/NeSpatPrivileged/NeSpat.app";
const HELPER:&str="/Library/Application Support/NeSpatPrivileged/NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper";
fn pinned(path: &str, requirement: &str, dir: bool) -> bool {
    CFURL::from_path(path, dir).is_some_and(|url| {
        nespat_matches_code(
            url.as_concrete_TypeRef(),
            CFString::new(requirement).as_concrete_TypeRef(),
            true,
        )
    })
}
fn host(argv0: &str, watchdog: bool) -> Option<Host> {
    if unsafe { libc::geteuid() } != 0
        || argv0 != HELPER
        || std::env::current_exe().ok()?.as_path() != std::path::Path::new(HELPER)
    {
        return None;
    }
    let profile = Profile::load()?;
    let client = profile.gui_pin()?;
    if !pinned(HELPER, &profile.helper_pin()?, false) || !pinned(APP, &client, true) {
        return None;
    }
    Some(Host {
        profile,
        client,
        boot: boot()?,
        epoch: new_id(),
        watchdog,
    })
}
pub fn run(args: &[String]) -> Option<i32> {
    let cmd = args.get(1)?.as_str();
    if !matches!(
        (cmd, args.len()),
        (
            "--serve-local" | "--watch-exclusive" | "--check-local" | "--check-removable",
            2
        ) | ("--approved-recovery", 4)
    ) {
        return None;
    }
    let watch = cmd == "--watch-exclusive";
    let h = host(&args[0], watch)?;
    if args.len() == 2 && cmd == "--check-local" {
        let battery = crate::battery::nespat_current_battery();
        let temp = crate::nespat_chip_temperature();
        let thermal = match objc2_foundation::NSProcessInfo::processInfo()
            .thermalState()
            .0
        {
            0 | 1 => 0,
            2 | 3 => 1,
            _ => -1,
        };
        let idle = nespat_setter_idle();
        let sleep = nespat_sleep_disabled();
        println!("root read-only preflight: battery={}, AC={}, temperature={}, thermal={}, sleep={}, boot=true, setupEnabled={}, setterIdle={idle}",battery.percent.is_finite(),battery.external>=0,temp.is_finite(),thermal,match sleep{0=>"enabled",1=>"disabled",_=>"unknown"},nespat_profile_enabled(&h.profile));
        return Some(
            if idle
                && sleep == 0
                && nespat_continuous_seconds().is_finite()
                && crate::policy::nespat_assess(
                    battery.percent,
                    battery.external,
                    temp,
                    thermal,
                    true,
                ) == 0
            {
                0
            } else {
                2
            },
        );
    }
    if !h.profile.exclusive() {
        return None;
    }
    let mut store = Store::open()?;
    if !nespat_setter_ready() {
        return None;
    }
    match (cmd, args.len()) {
        ("--serve-local", 2) => {
            crate::service_listener::run(crate::service_engine::Server::new(h, store))
        }
        ("--watch-exclusive", 2) => loop {
            let success = objc2::rc::autoreleasepool(|_| {
                store
                    .transaction(|t| service_recovery::reconcile(&h, t, None))
                    .is_some()
                    && pulse::heartbeat(h.boot, h.profile.setup, h.epoch, true)
            });
            if !success {
                eprintln!("Independent recovery pending");
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        },
        ("--check-removable", 2) => {
            if nespat_profile_enabled(&h.profile) {
                return None;
            }
            store.transaction(|t| {
                (t.state().record.is_none() && nespat_sleep_disabled() == 0).then_some(())
            })?;
            if !nespat_setter_idle() {
                return None;
            }
            println!("ordinary sleep confirmed; no recovery obligation; setter idle");
            Some(0)
        }
        ("--approved-recovery", 4) => {
            let id = crate::request::uuid(&args[2])?;
            let ticket = &args[3];
            if ticket.len() != 64 || !ticket.bytes().all(|b| b.is_ascii_hexdigit()) {
                return None;
            }
            store.transaction(|t| service_recovery::reconcile(&h, t, Some((id, ticket))))?;
            store.transaction(|t| {
                (t.state().record.is_none() && nespat_sleep_disabled() == 0).then_some(())
            })?;
            if nespat_sleep_disabled() != 0 {
                return None;
            }
            println!("Verified ordinary sleep");
            Some(0)
        }
        _ => None,
    }
}
