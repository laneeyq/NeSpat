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
    private static func launcher(_ action: String) -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/Applications/NeSpat.app/Contents/MacOS/NeSpat")
        process.arguments = [action]
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return status == "enabled\n"
    }
    private static var installedPanel: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == LocalTrustProfile.appPath
    }
    static var isEnabled: Bool {
        if localAgentEnabled || SMAppService.mainApp.status == .enabled { return true }
        return installedPanel && launcher("--login-status") == true
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        if localAgentEnabled { return on } // Removing a root-installed agent needs separate approval.
        do {
            if installedPanel {
                if SMAppService.mainApp.status == .enabled {
                    if on { return true }
                    try SMAppService.mainApp.unregister()
                }
                return launcher(on ? "--login-enable" : "--login-disable") == on
            }
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
