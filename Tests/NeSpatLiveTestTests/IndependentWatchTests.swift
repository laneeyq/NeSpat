import Foundation
import Testing
@testable import NeSpatLiveTestCore

private func waitFor(_ condition: () throws -> Bool) throws {
    let end = ProcessInfo.processInfo.systemUptime+4
    while try !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else { throw LiveError.state }
        Thread.sleep(forTimeInterval: 0.01) // Test synchronization, never the watchdog scheduler.
    }
}
@Suite struct IndependentWatchTests {
    @Test func watchdogWritesExpiryDuringLiveMockSetterWithoutParallelRestore() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        try Data("10".utf8).write(to: f.url.appendingPathComponent("mock-clock"))
        try Data().write(to: f.url.appendingPathComponent("mock-hold-activation"))
        let watcher = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-watch", time: 10)
        defer { if watcher.isRunning { watcher.terminate() }; watcher.waitUntilExit() }
        try waitFor { FileManager.default.fileExists(atPath: f.url.appendingPathComponent("watch-ready").path) }
        let helper = try f.spawn("NeSpatLiveTestHelper", "--fixture-arm", time: 10)
        defer { if helper.isRunning { helper.terminate() }; helper.waitUntilExit() }
        try waitFor { FileManager.default.fileExists(atPath: f.url.appendingPathComponent("mock-setter-started").path) }
        try Data("130".utf8).write(to: f.url.appendingPathComponent("mock-clock"), options: .atomic)
        try waitFor { (try? f.store.exclusive { try f.store.load().initiated }) == 130 }
        #expect(helper.isRunning && watcher.isRunning)
        let pending = try f.store.exclusive { try f.store.load() }
        #expect(pending.phase == .activationReserved && pending.retry == nil && pending.retired)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-power"), encoding: .utf8) == "Yes")
        try Data().write(to: f.url.appendingPathComponent("mock-setter-release"))
        try waitFor { !helper.isRunning && !watcher.isRunning }
        helper.waitUntilExit(); watcher.waitUntilExit()
        #expect(helper.terminationStatus == 2 && watcher.terminationStatus == 0)
        let done = try f.store.exclusive { try f.store.load() }
        #expect(done.phase == .completed && done.expires == 130)
    }
    @Test func autonomousWatchdogOutlivesHelperAndRecoversAtPersistedExpiry() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        try Data("10".utf8).write(to: f.url.appendingPathComponent("mock-clock"))
        let watcher = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-watch", time: 10)
        defer { if watcher.isRunning { watcher.terminate() }; watcher.waitUntilExit() }
        try waitFor { FileManager.default.fileExists(atPath: f.url.appendingPathComponent("watch-ready").path) }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-crash-after", time: 10) == 86)
        #expect(watcher.isRunning)
        try Data("130".utf8).write(to: f.url.appendingPathComponent("mock-clock"), options: .atomic)
        try waitFor { !watcher.isRunning }; watcher.waitUntilExit()
        #expect(watcher.terminationStatus == 0)
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.expires == 130 && r.initiated == 130 && r.phase == .completed)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-power"), encoding: .utf8) == "No")
    }
    @Test func watchdogRestartRechecksOverdueStateAndDoesNotExitAfterFailedRecovery() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-crash-after", time: 10) == 86)
        try Data("130".utf8).write(to: f.url.appendingPathComponent("mock-clock"))
        try Data().write(to: f.url.appendingPathComponent("mock-fail-restore"))
        let first = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-watch", time: 130)
        defer { if first.isRunning { first.terminate() }; first.waitUntilExit() }
        try waitFor { (try? f.store.exclusive { try f.store.load().failedAttempts }) == 1 }
        #expect(first.isRunning)
        first.terminate(); first.waitUntilExit() // Only the fixture process created above.
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.retry?.since == 130 && r.lastFailure == 130 && r.phase == .recovery)
        try FileManager.default.removeItem(at: f.url.appendingPathComponent("mock-fail-restore"))
        try Data("429".utf8).write(to: f.url.appendingPathComponent("mock-clock"), options: .atomic)
        let second = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-watch", time: 429)
        defer { if second.isRunning { second.terminate() }; second.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.15)
        #expect(second.isRunning)
        try Data("430".utf8).write(to: f.url.appendingPathComponent("mock-clock"), options: .atomic)
        try waitFor { !second.isRunning }; second.waitUntilExit()
        #expect(second.terminationStatus == 0)
        let done = try f.store.exclusive { try f.store.load() }
        #expect(done.phase == .completed && done.expires == 130 && done.failedAttempts == 1)
    }
    @Test func watchdogDeathAfterMockRestoreBeforeConfirmationIsIdempotent() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-recovery-crash-after", time: 130) == 86)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 131) == 0)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 132) == 0)
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.phase == .completed && r.retry == nil && r.failedAttempts == 0)
    }
}
