import Foundation
import NeSpatNative
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
    private static var installedPanel: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == LocalTrustProfile.appPath
    }
    static var isEnabled: Bool {
        nespat_login_enabled(localAgentEnabled, installedPanel)
    }
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        nespat_login_set(on, localAgentEnabled, installedPanel)
    }
}
