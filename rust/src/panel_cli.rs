use crate::{
    client::Client,
    host::nespat_continuous_seconds,
    observation::{nespat_lid_closed, nespat_sleep_disabled},
    profile::{nespat_profile_enabled, Profile},
    request::{uuid, Request},
    signing::{nespat_matches_code, pin},
};
use core_foundation::{base::TCFType, string::CFString, url::CFURL};
use objc2_foundation::NSBundle;
use serde_json::Value;
use std::{path::Path, thread, time::Duration};
fn code(path: &Path, hash: &str, id: &str) -> Option<bool> {
    let file = CFURL::from_path(path, path.is_dir())?;
    Some(nespat_matches_code(
        file.as_concrete_TypeRef(),
        CFString::new(&pin(hash, id)?).as_concrete_TypeRef(),
        true,
    ))
}
fn verify_build() -> Option<bool> {
    let path = NSBundle::mainBundle().bundlePath().to_string();
    let app = Path::new(&path);
    let profile: Value =
        serde_json::from_slice(&std::fs::read(app.parent()?.join("profile.json")).ok()?).ok()?;
    Some(
        code(app, profile["guiHash"].as_str()?, "local.nespat.app")?
            && code(
                &app.join("Contents/Library/Helpers/NeSpatPrivilegeHelper"),
                profile["helperHash"].as_str()?,
                "local.nespat.privilege-helper",
            )?,
    )
}
fn trial() -> Option<()> {
    let p = Profile::load()?;
    if !p.trial_only()
        || !nespat_profile_enabled(&p)
        || nespat_lid_closed() != 0
        || nespat_sleep_disabled() != 0
    {
        return None;
    }
    let mut client = Client::connect()?;
    let before = nespat_continuous_seconds();
    let begin = Request {
        id: crate::client::new_id(),
        operation: 1,
        has_minutes: true,
        minutes: 1,
        ..Default::default()
    };
    let reply: Value = serde_json::from_slice(&client.request(&begin)?).ok()?;
    let limit = reply["authorityExpires"].as_f64()?;
    let id = uuid(reply["session"].as_str()?)?;
    if reply["active"] != true
        || reply["state"] != "disabled"
        || !(before..=before + 120.).contains(&limit)
        || nespat_sleep_disabled() != 1
    {
        return None;
    }
    println!(
        "Trial active, confirmed Yes, session={}, authority remaining={}",
        crate::request::uuid_text(&id),
        limit - before
    );
    while nespat_continuous_seconds() < limit + 10. {
        thread::sleep(Duration::from_secs(3));
        if nespat_sleep_disabled() == 0 {
            break;
        }
        let heartbeat = Request {
            id: crate::client::new_id(),
            operation: 6,
            session: id,
            has_session: true,
            ..Default::default()
        };
        let _ = client.request(&heartbeat);
    }
    if nespat_sleep_disabled() == 0 {
        println!("Trial completed, confirmed No");
        Some(())
    } else {
        None
    }
}
pub fn run(arg: &str) -> i32 {
    match arg {
        "--observe-sleep" => {
            let v = nespat_sleep_disabled();
            println!(
                "SleepDisabled observation: {}",
                match v {
                    0 => "enabled",
                    1 => "disabled",
                    _ => "unknown",
                }
            );
            if v == 0 {
                0
            } else {
                2
            }
        }
        "--print-stats" => {
            let mut sampler = unsafe { Box::from_raw(crate::stats::nespat_sampler_create()) };
            let _ = crate::panel_readings::Readings::sample(&mut sampler);
            thread::sleep(Duration::from_secs(1));
            let r = crate::panel_readings::Readings::sample(&mut sampler);
            for (k, v) in ["Температура чипа", "CPU", "Память", "Батарея"]
                .into_iter()
                .zip(&r.values)
            {
                println!("{k}: {v}");
            }
            println!(
                "Сон: {}",
                match r.power {
                    0 => "включен (обычный)",
                    1 => "выключен (SleepDisabled=1)",
                    _ => "неизвестно",
                }
            );
            println!(
                "Крышка: {}",
                match nespat_lid_closed() {
                    0 => "открыта",
                    1 => "закрыта",
                    _ => "неизвестно",
                }
            );
            0
        }
        "--verify-local-service" => {
            if crate::client::nespat_verify_service() {
                println!("local root helper: strict mutual-pin handshake verified; no enrollment or power request sent");
                0
            } else {
                println!("local helper handshake not verified");
                1
            }
        }
        "--verify-local-build" => {
            let ok = verify_build() == Some(true);
            println!("local hardened ad-hoc pins verified: {ok}");
            if ok {
                0
            } else {
                1
            }
        }
        "--single-trial" => {
            if trial().is_some() {
                0
            } else {
                eprintln!("Trial unconfirmed");
                2
            }
        }
        _ => 64,
    }
}
