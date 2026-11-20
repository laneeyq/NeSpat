use objc2_service_management::{SMAppService, SMAppServiceStatus};
use std::process::Command;

fn launcher(action: &str) -> Option<bool> {
    let output = Command::new("/Applications/NeSpat.app/Contents/MacOS/NeSpat")
        .arg(action)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    match &output.stdout[..] {
        b"enabled\n" => Some(true),
        b"disabled\n" => Some(false),
        _ => None,
    }
}

#[no_mangle]
pub extern "C" fn nespat_login_enabled(local_agent: bool, installed_panel: bool) -> bool {
    local_agent
        || unsafe { SMAppService::mainAppService().status() } == SMAppServiceStatus::Enabled
        || (installed_panel && launcher("--login-status") == Some(true))
}
#[no_mangle]
pub extern "C" fn nespat_login_set(on: bool, local_agent: bool, installed_panel: bool) -> bool {
    if local_agent {
        return on;
    }
    let service = unsafe { SMAppService::mainAppService() };
    if installed_panel {
        if unsafe { service.status() } == SMAppServiceStatus::Enabled {
            if on {
                return true;
            }
            if unsafe { service.unregisterAndReturnError() }.is_err() {
                return false;
            }
        }
        return launcher(if on {
            "--login-enable"
        } else {
            "--login-disable"
        }) == Some(on);
    }
    if on {
        unsafe { service.registerAndReturnError() }.is_ok()
    } else {
        unsafe { service.unregisterAndReturnError() }.is_ok()
    }
}
