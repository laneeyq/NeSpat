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

const SERVICES: [&str; 2] = ["local.nespat.recovery", "local.nespat.privilege-helper"];

fn services_ready(mut registered: impl FnMut(&str) -> bool) -> bool {
    SERVICES.iter().all(|label| registered(label))
}

fn service_registered(label: &str) -> bool {
    Path::new("/Library/LaunchDaemons")
        .join(format!("{label}.plist"))
        .is_file()
        && std::process::Command::new("/bin/launchctl")
            .args(["print", &format!("system/{label}")])
            .output()
            .is_ok_and(|out| out.status.success())
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

fn embedded_digest() -> Result<&'static str, String> {
    option_env!("NESPAT_SERVICES_SHA256")
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or_else(|| "В сборке отсутствует контрольная сумма пакета служб".into())
}

fn install_services() -> Result<(), String> {
    // Only the release digest varies. All privileged paths and the installer target are fixed.
    let script = format!(
        r#"set -eu
umask 077
stage=$(/usr/bin/mktemp -d /private/tmp/nespat-services.XXXXXXXX)
trap '/bin/rm -f "$stage/Services.pkg"; /bin/rmdir "$stage"' EXIT
/bin/cp /Applications/NeSpat.app/Contents/Resources/Services.pkg "$stage/Services.pkg"
cd "$stage"
/bin/echo '{}  Services.pkg' | /usr/bin/shasum -a 256 -c - >/dev/null
/usr/sbin/installer -pkg "$stage/Services.pkg" -target /"#,
        embedded_digest()?
    );
    let result = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", "on run argv", "-e", "do shell script (item 1 of argv) with prompt \"NeSpat установит службы управления сном.\" with administrator privileges", "-e", "end run", "--", &script])
        .output().map_err(|e| e.to_string())?;
    if result.status.success() || String::from_utf8_lossy(&result.stderr).contains("(-128)") {
        return Ok(());
    }
    Err(String::from_utf8_lossy(&result.stderr).trim().to_owned())
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
        ready && services_ready(service_registered),
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
        if let Err(reason) = install_services() {
            notice(mtm, "Не удалось установить службы NeSpat", &reason);
            return Err(reason);
        }
        return Ok(());
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
    fn same_version_repairs_missing_service_registrations() {
        for helper in [false, true] {
            for watchdog in [false, true] {
                let ready = services_ready(|label| match label {
                    "local.nespat.privilege-helper" => helper,
                    "local.nespat.recovery" => watchdog,
                    _ => panic!("unexpected service"),
                });
                assert_eq!(
                    route(true, ready, Some(vec![1, 2, 5]), Some(vec![1, 2, 5])),
                    if helper && watchdog { "panel" } else { "setup" }
                );
            }
        }
    }
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
