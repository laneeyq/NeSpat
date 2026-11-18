import Foundation
import ServiceManagement
import Darwin
import NeSpatPrivilegeCore

/// Автозапуск при входе в систему (SMAppService, без сторонних LaunchAgent для самого приложения).
enum LoginItem {
    static var localAgentEnabled: Bool {
        guard let profile = try? LocalTrustProfile.load(), profile.allowedUID == getuid(),
              profile.guiPin.matchesHardenedFile(Bundle.main.bundleURL) else { return false }
        var info = stat()
        return lstat("/Library/LaunchAgents/local.nespat.gui.plist", &info) == 0 && info.st_uid == 0 &&
            info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o022 == 0
    }
    static var isEnabled: Bool { localAgentEnabled || SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        if localAgentEnabled { return on } // Removing a root-installed agent needs separate approval.
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
