import Foundation
import Darwin
import NeSpatPrivilegeCore

// Fixed executable/argv only. A child inherits the locked open file description on stdin,
// so a still-running setter keeps the exclusion lock even if its helper parent exits.
final class LocalFixedPowerInvoker: @unchecked Sendable {
    private let fd: Int32
    private let mutex = NSLock()
    private var running: Process?
    init() throws {
        guard geteuid() == 0 else { throw PrivilegeError.blocked }
        fd = open("/Library/Application Support/NeSpatPrivileged/State/setter.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw PrivilegeError.blocked }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == 0, s.st_mode & 0o077 == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else {
            close(fd); throw PrivilegeError.blocked
        }
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); close(fd); throw PrivilegeError.blocked }
        guard errno == ENOENT else { close(fd); throw PrivilegeError.blocked }
    }
    deinit { close(fd) }
    static func inspectIdle() -> Bool {
        guard geteuid() == 0 else { return false }
        let f = open("/Library/Application Support/NeSpatPrivileged/State/setter.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard f >= 0 else { return false }; defer { close(f) }
        var s = stat()
        guard fstat(f, &s) == 0, s.st_uid == 0, s.st_nlink == 1, s.st_mode & S_IFMT == S_IFREG,
              s.st_mode & 0o077 == 0, flock(f, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(f, LOCK_UN); return true
    }
    func canFinalizePending() -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard running == nil, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(fd, LOCK_UN); return true
    }
    func setDisabled(_ disabled: Bool) throws {
        if disabled { guard try LocalTrustProfile.load().currentlyEnabled else { throw PrivilegeError.blocked } }
        mutex.lock()
        guard running == nil, flock(fd, LOCK_EX | LOCK_NB) == 0 else { mutex.unlock(); throw PrivilegeError.busy }
        let process = Process(); running = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.mutex.lock()
            if self.running === child { self.running = nil; _ = flock(self.fd, LOCK_UN) }
            self.mutex.unlock()
        }
        do {
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
            try process.run()
        } catch {
            running = nil; _ = flock(fd, LOCK_UN); mutex.unlock(); throw error
        }
        mutex.unlock()
        let end = RecoveryPolicy.continuousSeconds() + 3
        while process.isRunning && RecoveryPolicy.continuousSeconds() < end { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw PrivilegeError.unconfirmed }
        guard process.terminationStatus == 0 else { throw PrivilegeError.unconfirmed }
        guard SystemSleepObservation.read() == (disabled ? .disabled : .enabled) else { throw PrivilegeError.unconfirmed }
    }
}
