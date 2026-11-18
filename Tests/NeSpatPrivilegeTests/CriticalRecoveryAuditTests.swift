import Foundation
import Testing
@testable import NeSpatPrivilegeCore

final class CriticalAuditFixture {
    let f = PrivilegeFixture()
    var clock: Double = 1000
    var reading: PowerSafetySnapshot? = fixtureSafetySnapshot
    var liveness = OwnerLiveness.inactive
    lazy var engine = makeEngine()
    func makeEngine(boot: UUID? = nil) -> PrivilegeEngine {
        PrivilegeEngine(journal: f.journal, boot: boot ?? f.boot, now: { self.f.wall },
            monotonic: { self.f.uptime }, observe: { self.f.state }, setDisabled: { value in
                self.f.changes.append(value)
                if self.f.failSetter { throw PrivilegeError.unconfirmed }
                if self.f.apply { self.f.state = value ? .disabled : .enabled }
            }, ownerLiveness: { _ in self.liveness }, fullGrantPolicy: fixtureFullGrantPolicy,
            safetySnapshot: { self.reading ?? PowerSafetySnapshot() }, retryClock: { self.clock })
    }
    func begin() throws -> UUID {
        let c = try engine.enrollmentChallenge(for: f.peer)
        try engine.admit(f.peer, authorization: .fresh(FreshAuthorization(trustedConsentFor: c,
            confirmedAt: f.uptime, expires: 1000)))
        return try #require(engine.handle(Request(operation: .begin, minutes: 60), from: f.peer).session)
    }
    func condition(_ variant: Int) {
        switch variant {
        case 0: reading = .init(thermalSerious: true)
        case 1: reading = .init(batteryPercent: 10, externalPowerConnected: false, temperatureC: 40, thermalSerious: false)
        case 2: reading = .init(batteryPercent: 80, externalPowerConnected: true, temperatureC: 95, thermalSerious: false)
        default: reading = .init()
        }
    }
}

@Suite struct CriticalRecoveryAuditTests {
    @Test(arguments: Array(0..<4))
    func dangerAndUnknownRevokeBeforeFailedSetterThenWait(_ condition: Int) throws {
        let h = CriticalAuditFixture(), id = try h.begin(); h.condition(condition)
        let record = h.f.journal.record; h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        #expect(h.f.changes == [true, false] && h.f.journal.record == record && h.f.state == .disabled)
        #expect(throws: PrivilegeError.denied) { try h.engine.handle(Request(operation: .changeDeadline, session: id, minutes: 1), from: h.f.peer) }
        for time in [1000.0, 1001, 1029, Double(1030).nextDown] {
            h.clock = time; try h.engine.tick()
            #expect(h.f.changes == [true, false] && h.f.journal.record == record)
        }
        h.clock = 1030; h.f.failSetter = false; try h.engine.tick()
        #expect(h.f.changes == [true, false, false] && h.f.journal.record == nil && h.f.state == .enabled)
    }
    @Test(arguments: Array(0..<4))
    func safeReadingAfterFailureCannotRenewFullAuthority(_ condition: Int) throws {
        let h = CriticalAuditFixture(), id = try h.begin(); h.condition(condition); h.f.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        h.reading = fixtureSafetySnapshot; try h.engine.tick()
        #expect(h.f.changes == [true, false] && h.f.journal.record?.id == id)
        #expect(throws: PrivilegeError.denied) { try h.engine.handle(Request(operation: .begin), from: h.f.peer) }
        h.f.apply = true
        _ = try h.engine.handle(Request(operation: .recover, session: id), from: h.f.peer)
        #expect(h.f.changes == [true, false, false] && h.f.journal.record == nil)
    }
    @Test(arguments: [ObservedSleep.enabled, .unknown])
    func observedPowerDuringCriticalCooldown(_ state: ObservedSleep) throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        let record = h.f.journal.record; h.f.state = state
        if state == .unknown { #expect(throws: PrivilegeError.unknownPower) { try h.engine.tick() } }
        else { try h.engine.tick() }
        #expect(h.f.changes == [true, false])
        #expect(h.f.journal.record == (state == .enabled ? nil : record))
    }
    @Test(arguments: Array(0..<5))
    func journalDamageDuringCriticalCooldownCannotAuthorizeSetter(_ variant: Int) throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        switch variant {
        case 0: h.f.journal.record = nil
        case 1: h.f.journal.record?.id = UUID()
        case 2: h.f.journal.record?.owner = Peer(connection: UUID(), uid: 502, auditSession: 123, codeIdentity: "other")
        case 3: h.f.journal.record?.phase = .pending
        default: h.f.journal.corrupt = true
        }
        let changed = h.f.journal.record; h.clock = 1300; try? h.engine.tick()
        #expect(h.f.changes == [true, false] && h.f.journal.record == changed)
    }
    @Test func restartRetainsPersistentCooldownWithoutChangingAuthorityJournal() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        let record = h.f.journal.record; try h.engine.tick()
        #expect(h.f.changes == [true, false])
        let restarted = h.makeEngine()
        try restarted.tick()
        #expect(h.f.changes == [true, false] && h.f.journal.record == record)
    }
    @Test func rebootIdentityAndLiveForeignOwnerBlockRestartRecovery() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        let record = h.f.journal.record
        #expect(throws: PrivilegeError.ownership) { try h.makeEngine(boot: UUID()).tick() }
        h.liveness = .active
        #expect(throws: PrivilegeError.ownership) { try h.makeEngine().tick() }
        #expect(h.f.changes == [true, false] && h.f.journal.record == record)
    }
    @Test func retryBindingRejectsAuthorityRecordReplayAfterRestart() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); let record = h.f.journal.record
        _ = try h.engine.handle(Request(operation: .changeDeadline, session: try #require(record?.id), minutes: 120), from: h.f.peer)
        #expect(h.f.journal.record != record)
        h.condition(0); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        // A valid earlier record is indistinguishable after in-memory authority pins are lost.
        h.f.journal.record = record
        #expect(throws: PrivilegeError.ownership) { try h.makeEngine().tick() }
        #expect(h.f.changes == [true, false] && h.f.journal.record == record)
    }
    @Test(arguments: Array(0..<4))
    func eligibleEmergencyWithoutPriorFailureRestoresImmediately(_ condition: Int) throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(condition)
        try h.engine.tick()
        #expect(h.f.state == .enabled && h.f.changes == [true, false] && h.f.journal.record == nil)
    }
    @Test(arguments: [14.0, 10.01, 10.0])
    func batteryEmergencyThresholdDoesNotInventAnEmergency(_ battery: Double) throws {
        let h = CriticalAuditFixture(); _ = try h.begin()
        h.reading = .init(batteryPercent: battery, externalPowerConnected: false, temperatureC: 40, thermalSerious: false)
        try h.engine.tick()
        #expect(h.f.changes == (battery <= 10 ? [true, false] : [true]))
        #expect((h.f.journal.record == nil) == (battery <= 10))
    }
    @Test func unknownACIsSensorLossRatherThanInventedBatteryDanger() throws {
        let h = CriticalAuditFixture(); _ = try h.begin()
        h.reading = .init(batteryPercent: 10, externalPowerConnected: nil, temperatureC: 40, thermalSerious: false)
        #expect(h.reading?.emergencyReason == nil && h.reading?.emergencyAssessment == .unknown)
        try h.engine.tick()
        #expect(h.f.changes == [true, false] && h.f.journal.record == nil)
    }
    @Test func journalCommitFailureAfterObservedNoDoesNotRepeatSetter() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0)
        let record = h.f.journal.record; h.f.journal.failWrite = h.f.journal.writes + 1
        #expect(throws: PrivilegeError.journal) { try h.engine.tick() }
        #expect(h.f.state == .enabled && h.f.journal.record == record && h.f.changes == [true, false])
        h.f.journal.failWrite = nil; try h.engine.tick()
        #expect(h.f.journal.record == nil && h.f.changes == [true, false])
    }
    @Test func unknownLivenessVetoesUnconfirmedRestartRecovery() throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.tick() }
        h.liveness = .unknown
        #expect(throws: PrivilegeError.ownership) { try h.makeEngine().tick() }
        #expect(h.f.changes == [true, false])
    }
    @Test func watchdogCheckedDuringCooldownIsNotOrdinarySleep() async throws {
        let h = CriticalAuditFixture(); _ = try h.begin(); h.condition(0); h.f.failSetter = true
        let watchdog = HelperWatchdog(engine: h.engine)
        #expect(await watchdog.poll() == .recoveryRequired)
        #expect(await watchdog.poll() == .checked)
        #expect(h.f.state == .disabled && h.f.journal.record != nil && h.f.changes == [true, false])
    }
}
