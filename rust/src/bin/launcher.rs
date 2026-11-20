use objc2::{rc::autoreleasepool, MainThreadMarker};
use objc2_app_kit::{NSAlert, NSApplication, NSRunningApplication, NSWorkspace};
use objc2_foundation::{NSBundle, NSString, NSURL};
use objc2_service_management::{SMAppService, SMAppServiceStatus};
use std::{env, fs, path::Path, process::ExitCode};

const BASE: &str = "/Library/Application Support/NeSpatPrivileged";
const APPLICATION: &str = "/Applications/NeSpat.app";

fn version(bundle: &NSBundle) -> Option<Vec<u64>> {
    let item =
        bundle.objectForInfoDictionaryKey(&NSString::from_str("CFBundleShortVersionString"))?;
    let version = item.downcast::<NSString>().ok()?.to_string();
    version.split('.').map(|part| part.parse().ok()).collect()
}

fn route(
    placed: bool,
    ready: bool,
    installed: Option<Vec<u64>>,
    expected: Option<Vec<u64>>,
) -> &'static str {
    if !placed {
        return "move";
    }
    if ready && matches!((installed, expected), (Some(a), Some(b)) if a >= b) {
        return "panel";
    }
    "setup"
}

fn notice(mtm: MainThreadMarker, title: &str, detail: &str) {
    let alert = NSAlert::new(mtm);
    alert.setMessageText(&NSString::from_str(title));
    alert.setInformativeText(&NSString::from_str(detail));
    #[allow(deprecated)]
    NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
    alert.runModal();
}

fn run(mtm: MainThreadMarker) -> Result<(), String> {
    let bundle = NSBundle::mainBundle();
    let placed = bundle.bundlePath().to_string() == APPLICATION;
    let args: Vec<_> = env::args().skip(1).collect();
    let arg = args.first().map(String::as_str);
    if args.len() > 1 {
        return Err("Неизвестные параметры запуска".into());
    }
    if matches!(
        arg,
        Some("--login-enable" | "--login-status" | "--login-disable")
    ) {
        if !placed {
            return Err("Перенесите NeSpat в Программы".into());
        }
        let service = unsafe { SMAppService::mainAppService() };
        match arg {
            Some("--login-enable") => {
                unsafe { service.registerAndReturnError() }.map_err(|e| e.to_string())?
            }
            Some("--login-disable") => {
                unsafe { service.unregisterAndReturnError() }.map_err(|e| e.to_string())?
            }
            _ => (),
        }
        println!(
            "{}",
            if unsafe { service.status() } == SMAppServiceStatus::Enabled {
                "enabled"
            } else {
                "disabled"
            }
        );
        return Ok(());
    }
    let panel = Path::new(BASE).join("NeSpat.app");
    let url = NSURL::fileURLWithPath(&NSString::from_str(&panel.to_string_lossy()));
    let profile = fs::read(Path::new(BASE).join("LocalTrust/profile.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
    let ready = profile.and_then(|p| p["enabled"].as_bool()) == Some(true);
    let dest = route(
        placed,
        ready,
        NSBundle::bundleWithURL(&url).and_then(|b| version(&b)),
        version(&bundle),
    );
    if arg == Some("--check-launch-route") {
        println!("{dest}");
        return Ok(());
    }
    if dest == "move" {
        notice(mtm, "Перенесите NeSpat в Программы", "Перетащите NeSpat.app на папку Applications в образе. Затем откройте NeSpat из Программ.");
        return Ok(());
    }
    let target = if dest == "setup" {
        let running = NSRunningApplication::runningApplicationsWithBundleIdentifier(
            &NSString::from_str("local.nespat.app"),
        );
        for i in 0..running.count() {
            if running
                .objectAtIndex(i)
                .bundleURL()
                .and_then(|u| u.path())
                .is_some_and(|p| p.to_string() == panel.to_string_lossy())
            {
                notice(mtm,"Завершите работу NeSpat","Остановите сессию, выберите «Выход» в панели и снова откройте NeSpat из Программ.");
                return Ok(());
            }
        }
        bundle
            .URLForResource_withExtension(
                Some(&NSString::from_str("Services")),
                Some(&NSString::from_str("pkg")),
            )
            .ok_or("В приложении отсутствует пакет служб")?
    } else {
        url
    };
    if !NSWorkspace::sharedWorkspace().openURL(&target) {
        notice(
            mtm,
            "Не удалось открыть NeSpat",
            "Скопируйте приложение заново из образа выпуска.",
        );
    }
    Ok(())
}
fn main() -> ExitCode {
    autoreleasepool(
        |_| match run(MainThreadMarker::new().expect("main thread")) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        },
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requires_installed_location_and_enabled_matching_panel() {
        assert_eq!(route(false, true, Some(vec![2]), Some(vec![1])), "move");
        assert_eq!(route(true, false, Some(vec![2]), Some(vec![1])), "setup");
        assert_eq!(route(true, true, None, Some(vec![1])), "setup");
        assert_eq!(
            route(true, true, Some(vec![1, 1]), Some(vec![1, 10])),
            "setup"
        );
        assert_eq!(
            route(true, true, Some(vec![1, 10]), Some(vec![1, 1])),
            "panel"
        );
    }
}
