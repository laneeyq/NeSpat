import Testing
@testable import NeSpatPrivilegeCore
@Suite struct PersistentEnginePolicyTests {
    @Test(arguments: Array(0..<4)) func emergencyRepeatsAtThirtySeconds(_ condition: Int) throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(condition); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        h.clock = 1029; try h.engine.tick(); #expect(h.f.changes == [true, false])
        h.clock = 1030
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        #expect(h.f.changes == [true, false, false])
    }
    @Test func restartKeepsEmergencyReservation() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        try h.makeEngine().tick()
        #expect(h.f.changes == [true, false])
    }
    @Test func unknownTimeBlocksFirstSetter() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.clock = .nan
        #expect(throws: PrivilegeError.blocked) { try h.engine.tick() }
        #expect(h.f.changes == [true] && h.f.journal.record != nil)
    }
    @Test func firstCriticalAttemptCanPreemptOrdinaryWaitOnlyOnce() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.f.failSetter = true
        h.f.wall = h.f.wall.addingTimeInterval(3601)
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        h.condition(0)
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        h.clock = 1029; try h.engine.tick()
        #expect(h.f.changes == [true, false, false])
        h.clock = 1030
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        #expect(h.f.changes == [true, false, false, false])
    }

}

import Foundation
import Darwin

private final class CrashReservationJournal: PersistentRecoveryJournal {
    let base: ProtectedJournal
    var crash = true
    init(_ base: ProtectedJournal) { self.base = base }
    func exclusive<T>(_ body: () throws -> T) throws -> T { try base.exclusive(body) }
    func load() throws -> PrivilegedRecord? { try base.load() }
    func save(_ value: PrivilegedRecord?) throws { try base.save(value) }
    func recoverySnapshot() throws -> RecoverySnapshot { try base.recoverySnapshot() }
    func saveRecoveryRetry(_ value: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws {
        try base.saveRecoveryRetry(value, expected: expected, generation: generation)
        if crash { crash = false; throw PCError.crash }
    }
}
@Suite struct DiskEngineRetryTests {
    @Test(arguments: [false, true]) func actualFileKeepsReservationBeforeOrDuringSetter(_ before: Bool) throws {
        try ProtectedJournalTests().fixture { _, fd in
            let journal = try ProtectedJournal(testDirectoryFD: fd, owner: getuid()), f = PrivilegeFixture()
            let record = PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot, baselineEnabled: true, phase: .active, deadline: f.wall)
            try journal.exclusive { try journal.save(record) }
            var time = 1000.0, calls = 0
            func engine(_ store: any AuthorityJournal) -> PrivilegeEngine {
                PrivilegeEngine(journal: store, boot: f.boot, now: { f.wall }, monotonic: { time }, observe: { .disabled },
                    setDisabled: { _ in calls += 1; throw PCError.crash }, ownerLiveness: { _ in .inactive },
                    safetySnapshot: { PowerSafetySnapshot(thermalSerious: true) }, retryClock: { time })
            }
            #expect(throws: PCError.crash) { try engine(before ? CrashReservationJournal(journal) : journal).tick() }
            #expect(calls == (before ? 0 : 1))
            let reopened = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            try engine(reopened).tick(); time = 1029; try engine(reopened).tick()
            #expect(calls == (before ? 0 : 1))
            time = 1030
            #expect(throws: PCError.crash) { try engine(reopened).tick() }
            #expect(calls == (before ? 1 : 2))
            try reopened.exclusive {
                #expect(try reopened.load() == record)
                let retry = try #require(reopened.recoverySnapshot().retry)
                #expect(retry.record == record && retry.emergency && retry.since == 1030)
            }
        }
    }
}

@Suite struct RecoveryCrashCleanupTests {
    @Test func pendingIntentWithConfirmedOrdinarySleepCanBeCleanedWithoutSetter() throws {
        let f = PrivilegeFixture()
        f.journal.record = PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot, baselineEnabled: true, phase: .pending, deadline: nil)
        let engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: { f.changes.append($0) }, canFinalizePending: { true })
        try engine.tick()
        #expect(f.journal.record == nil && f.changes.isEmpty && f.state == .enabled)
    }
    @Test(arguments: [ObservedSleep.disabled, .unknown]) func pendingAmbiguityNeverAuthorizesRestore(_ state: ObservedSleep) throws {
        let f = PrivilegeFixture(); f.state = state
        f.journal.record = PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot, baselineEnabled: true, phase: .pending, deadline: nil)
        let original = f.journal.record
        let engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: { f.changes.append($0) }, canFinalizePending: { true })
        #expect(throws: PrivilegeError.ownership) { try engine.tick() }
        #expect(f.journal.record == original && f.changes.isEmpty)
    }
}

@Suite struct BootRecoveryNoTests {
    @Test func confirmedOrdinarySleepAfterNewBootClearsOldAuthorityWithoutPowerWrite() throws {
        let f = PrivilegeFixture()
        f.journal.record = PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot, baselineEnabled: true, phase: .active, deadline: nil)
        let engine = PrivilegeEngine(journal: f.journal, boot: UUID(), now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: { f.changes.append($0) }, canFinalizePending: { true })
        try engine.tick()
        #expect(f.journal.record == nil && f.changes.isEmpty && f.state == .enabled)
    }
}
