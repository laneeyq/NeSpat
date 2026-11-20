import Foundation
import Darwin
import NeSpatNative
import NeSpatPrivilegeCore

final class LocalFixedPowerInvoker: Sendable {
    init() throws {
        guard nespat_setter_ready() else { throw PrivilegeError.blocked }
    }
    static func inspectIdle() -> Bool {
        let fd = nespat_setter_lock()
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
    func canFinalizePending() -> Bool { Self.inspectIdle() }
    func setDisabled(_ disabled: Bool) throws {
        if disabled { guard try LocalTrustProfile.load().currentlyEnabled else { throw PrivilegeError.blocked } }
        let fd = nespat_setter_lock()
        guard fd >= 0 else { throw PrivilegeError.busy }
        defer { close(fd) }
        if disabled {
            let profile = try LocalTrustProfile.load()
            guard profile.currentlyEnabled else { throw PrivilegeError.denied }
            guard SystemSleepObservation.read() == .enabled else { throw PrivilegeError.interference }
            if profile.trialOnly {
                // This installation has exactly one real attempt, even across helper crashes.
                let url = URL(fileURLWithPath: "/Library/Application Support/NeSpatPrivileged/State")
                let marker = open(url.appendingPathComponent("trial-spent").path,
                    O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard marker >= 0 else { throw PrivilegeError.denied }
                defer { close(marker) }
                let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw PrivilegeError.journal }
                defer { close(directory) }
                guard fsync(marker) == 0, fsync(directory) == 0 else { throw PrivilegeError.journal }
            }
        }
        guard nespat_setter_run(fd, disabled),
              SystemSleepObservation.read() == (disabled ? .disabled : .enabled) else { throw PrivilegeError.unconfirmed }
    }
}
