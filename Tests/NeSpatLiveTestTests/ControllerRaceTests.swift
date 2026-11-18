import Foundation
import Testing
@testable import NeSpatLiveTestCore

private func waitFixture(_ test: () throws -> Bool) throws {
    let end = ProcessInfo.processInfo.systemUptime+3
    while try !test() {
        guard ProcessInfo.processInfo.systemUptime < end else { throw LiveError.busy }
        Thread.sleep(forTimeInterval: 0.01) // Parent test synchronization only.
    }
}
@Suite struct ControllerRaceTests {
    @Test(arguments: [130.0, 131]) func lateActivationCannotUndoExistingRetirement(_ finished: Double) throws {
        let f = Rig()
        f.backend.onExecute = {
            f.backend.sample.power = .disabled; f.backend.sample.continuous = finished
            #expect(throws: (any Error).self) { try f.recovery.poll() } // Busy setter, retirement is durable.
        }
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(f.store.record.retired && f.store.record.initiated == finished)
        #expect(f.store.record.phase == .activationReserved && f.store.record.attempt != nil)
        #expect(f.backend.calls == [.activate] && f.store.record.expires == 130)
    }
    @Test(arguments: [Double(130).nextDown, 130, Double(130).nextUp, 131])
    func activationCompletionMustPrecedeImmutableExpiry(_ finished: Double) throws {
        let f = Rig(); f.backend.onExecute = { f.backend.sample.continuous = finished }
        var rejected = false
        do { try f.arm() } catch { rejected = true }
        #expect(rejected == (finished >= 130))
        #expect((f.store.record.phase == .active) == (finished < 130))
        #expect(f.store.record.expires == 130 && f.store.record.attempt != nil && f.store.record.consumed)
        if finished >= 130 {
            #expect(f.store.record.retired && f.store.record.initiated == finished)
            #expect(f.backend.sample.power == .disabled && f.backend.calls == [.activate])
            f.backend.onExecute = nil; try f.recovery.poll()
            #expect(f.store.record.phase == .completed && f.backend.sample.power == .enabled)
        }
    }
    @Test func slowRestoreLeavesJournalAvailableToIndependentSecondWatchdog() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        try Data().write(to: f.url.appendingPathComponent("mock-hold-restore"))
        let first = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130)
        defer { if first.isRunning { first.terminate() }; first.waitUntilExit() }
        try waitFixture { FileManager.default.fileExists(atPath: f.url.appendingPathComponent("mock-restore-started").path) }
        let before = try? f.store.exclusive { try f.store.load() }
        #expect(before != nil)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 131) == 2) // Busy setter, not blocked journal.
        let updated = try? f.store.exclusive { try f.store.load() }
        #expect(updated?.lastClock == 131 && updated?.phase == .recovery)
        #expect(updated?.retry?.nonce == before?.retry?.nonce)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-restore-count"), encoding: .utf8) == "1")
        try Data().write(to: f.url.appendingPathComponent("mock-restore-release"))
        try waitFixture { !first.isRunning }; first.waitUntilExit()
        #expect(first.terminationStatus == 2) // Generation changed: stale result cannot commit.
        let pending = try f.store.exclusive { try f.store.load() }
        #expect(pending.phase == .recovery && pending.retired && pending.retry != nil)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 132) == 0)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-restore-count"), encoding: .utf8) == "1")
    }
    @Test func waitingManualConsentDoesNotBlockAutonomousDeadline() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        let manual = try f.spawn("NeSpatLiveRecoveryWatchdog", "--fixture-manual-wait", time: 20)
        defer { if manual.isRunning { manual.terminate() }; manual.waitUntilExit() }
        try waitFixture { FileManager.default.fileExists(atPath: f.url.appendingPathComponent("mock-auth-started").path) }
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130) == 0)
        #expect(manual.isRunning)
        try Data().write(to: f.url.appendingPathComponent("mock-auth-release"))
        try waitFixture { !manual.isRunning }; manual.waitUntilExit()
        #expect(manual.terminationStatus == 2) // Consent's record is now stale.
        let record = try f.store.exclusive { try f.store.load() }
        #expect(record.phase == .completed && record.retired && record.expires == 130)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-restore-count"), encoding: .utf8) == "1")
    }
    @Test func failedRestoreSurvivesConcurrentBookkeepingWithSameReservation() throws {
        let f = Rig(); try f.arm(); f.backend.applies = false; f.backend.sample.continuous = 130
        f.backend.onExecute = {
            f.backend.sample.continuous = 131
            #expect(throws: (any Error).self) { try f.recovery.poll() }
            throw LiveError.state
        }
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.phase == .recovery && f.store.record.failedAttempts == 1)
        #expect(f.store.record.lastFailure == 131 && f.store.record.retry?.since == 131)
        f.backend.onExecute = nil; f.backend.sample.continuous = 430
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls == [.activate, .restore])
        f.backend.sample.continuous = 431; f.backend.applies = true; try f.recovery.poll()
        #expect(f.store.record.phase == .completed && f.store.record.failedAttempts == 1)
    }
    @Test func lateRestoreCannotEraseInterferenceOrCommitStaleCompletion() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130
        f.backend.onExecute = { f.store.record.interferenceDetected = true; f.store.record.generation += 1 }
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.sample.power == .enabled && f.store.record.phase == .recovery)
        #expect(f.store.record.retired && f.store.record.interferenceDetected && f.store.record.retry != nil)
        #expect(try !f.recovery.canRemove())
        #expect(f.backend.calls == [.activate, .restore])
    }
}
