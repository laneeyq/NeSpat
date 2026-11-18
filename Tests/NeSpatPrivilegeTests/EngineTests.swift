import Foundation
import Testing
@testable import NeSpatPrivilegeCore

// Explicit test authority policy only; no production maximum has been selected.
let fixtureFullGrantPolicy = try! FullGrantLifetimePolicy(maximumLifetime: 1000)
// Explicit healthy server sensor fixture, not readings asserted by a GUI.
let fixtureSafetySnapshot = PowerSafetySnapshot(batteryPercent: 100, externalPowerConnected: true, temperatureC: 40, thermalSerious: false)

final class MemoryAuthority: PersistentRecoveryJournal {
    var retry: RecoveryRetry?
    var retryGeneration: UInt64 = 1
    func recoverySnapshot() throws -> RecoverySnapshot { RecoverySnapshot(generation: retryGeneration, retry: retry) }
    func saveRecoveryRetry(_ value: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws {
        guard !corrupt, record == expected, generation == retryGeneration else { throw PrivilegeError.journal }
        retry = value
    }
    var record: PrivilegedRecord?
    var busy = false, corrupt = false
    var writes = 0
    var failWrite: Int?
    func exclusive<T>(_ body: () throws -> T) throws -> T {
        guard !busy else { throw PrivilegeError.busy }
        busy = true; defer { busy = false }; return try body()
    }
    func load() throws -> PrivilegedRecord? { if corrupt { throw PrivilegeError.journal }; return record }
    func save(_ record: PrivilegedRecord?) throws {
        writes += 1; if failWrite == writes { throw PrivilegeError.journal }; self.record = record
        if let record { retry?.record = record } else { retry = nil }
    }
}
final class PrivilegeFixture: @unchecked Sendable {
    let journal = MemoryAuthority()
    let boot = UUID()
    let peer = Peer(connection: UUID(), uid: 501, auditSession: 123, codeIdentity: "verified-test-publisher/app")
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: Double = 10
    var state = ObservedSleep.enabled
    var changes: [Bool] = []
    var apply = true
    var failSetter = false
    var onSet: (() -> Void)?
    lazy var engine = PrivilegeEngine(journal: journal, boot: boot, now: { self.wall }, monotonic: { self.uptime },
                                     observe: { self.state }, setDisabled: {
        self.changes.append($0); self.onSet?()
        if self.failSetter { throw PrivilegeError.unconfirmed }
        if self.apply { self.state = $0 ? .disabled : .enabled }
    }, fullGrantPolicy: fixtureFullGrantPolicy, safetySnapshot: { fixtureSafetySnapshot })
    // Only this isolated test authority can construct receipts. Reusing a callback does not
    // create consent: admit() deliberately reuses the previous receipt for the same owner.
    private var approvals: [OwnerIdentity: FreshAuthorization] = [:]
    func freshConsent(for who: Peer) throws -> FreshAuthorization {
        FreshAuthorization(trustedConsentFor: try engine.enrollmentChallenge(for: who),
                           confirmedAt: uptime, expires: 1000)
    }
    func admit(_ who: Peer? = nil) throws {
        let who = who ?? peer
        if journal.record != nil { try engine.admit(who, authorization: .recoveryOnly(expires: 1000)); return }
        guard let owner = who.ownerIdentity else { throw PrivilegeError.denied }
        if approvals[owner] == nil { approvals[owner] = try freshConsent(for: who) }
        try engine.admit(who, authorization: .fresh(approvals[owner]!))
    }
    func begin(minutes: Int? = 10000) throws -> UUID {
        try admit(); return try engine.handle(Request(operation: .begin, minutes: minutes), from: peer).session!
    }
}

@Suite struct PrivilegeEngineTests {
    @Test func fixedOperationsAndUnlimitedDuration() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        #expect(f.changes == [true]); #expect(f.journal.record?.baselineEnabled == true)
        #expect(f.journal.record?.phase == .active)
        #expect(f.journal.record?.deadline == f.wall.addingTimeInterval(10000 * 60))
        _ = try f.engine.handle(Request(operation: .changeDeadline, session: id), from: f.peer)
        #expect(f.journal.record?.deadline == nil)
        _ = try f.engine.handle(Request(operation: .end, session: id), from: f.peer)
        #expect(f.changes == [true, false]); #expect(f.journal.record == nil)
    }
    @Test func claimsInPayloadCannotChangePeer() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        for impostor in [Peer(connection: f.peer.connection, uid: 502, auditSession: 123),
                         Peer(connection: f.peer.connection, uid: 501, auditSession: 124),
                         Peer(connection: UUID(), uid: 501, auditSession: 123)] {
            #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .end, session: id), from: impostor) }
        }
        #expect(f.changes == [true])
    }
    @Test func oldAdmissionReplayRevokeAndExpiration() throws {
        let f = PrivilegeFixture(); try f.admit()
        let request = Request(operation: .status)
        _ = try f.engine.handle(request, from: f.peer)
        #expect(throws: PrivilegeError.replay) { try f.engine.handle(request, from: f.peer) }
        _ = try f.engine.handle(Request(operation: .revoke), from: f.peer)
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        let g = PrivilegeFixture(); try g.admit(); g.uptime = 1001
        #expect(throws: PrivilegeError.denied) { try g.engine.handle(Request(operation: .begin), from: g.peer) }
        #expect(g.changes.isEmpty)
    }
    @Test func foreignSessionAndRepeatedAdmissionDenied() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        #expect(throws: PrivilegeError.denied) { try f.admit() }
        let foreign = Peer(connection: UUID(), uid: 502, auditSession: 124, codeIdentity: "verified-test-publisher/app")
        #expect(throws: PrivilegeError.ownership) { try f.admit(foreign) }
        for op in [Operation.end, .recover, .changeDeadline] {
            #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: op, session: id), from: foreign) }
        }
        #expect(f.changes == [true])
    }
    @Test(arguments: [ObservedSleep.disabled, .unknown]) func baselineMustBeOrdinarySleep(_ state: ObservedSleep) throws {
        let f = PrivilegeFixture(); try f.admit(); f.state = state
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(f.changes.isEmpty); #expect(f.journal.record == nil)
    }
    @Test func writeFailuresAndUnconfirmedCommandsKeepAmbiguity() throws {
        let f = PrivilegeFixture(); try f.admit(); f.journal.failWrite = 1
        #expect(throws: PrivilegeError.journal) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(f.changes.isEmpty)
        let g = PrivilegeFixture(); try g.admit(); g.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try g.engine.handle(Request(operation: .begin), from: g.peer) }
        #expect(g.journal.record?.phase == .pending)
        g.uptime = 1001 // Force the recovery path; idle future timers correctly do no work.
        #expect(throws: PrivilegeError.ownership) { try g.engine.tick() }
        #expect(g.changes == [true])
        let h = PrivilegeFixture(); try h.admit(); h.journal.failWrite = 2
        #expect(throws: PrivilegeError.journal) { try h.engine.handle(Request(operation: .begin), from: h.peer) }
        #expect(h.journal.record?.phase == .pending); #expect(h.state == .disabled)
    }
    @Test func journalLossSubstitutionAndCorruptionNeverAuthorizeWrites() throws {
        for variant in 0..<3 {
            let f = PrivilegeFixture(); _ = try f.begin()
            if variant == 0 { f.journal.record = nil }
            if variant == 1 { f.journal.record?.id = UUID() }
            if variant == 2 { f.journal.corrupt = true }
            f.wall = f.wall.addingTimeInterval(1_000_000)
            do { try f.engine.tick() } catch { }
            #expect(f.changes == [true]); #expect(throws: (any Error).self) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
            if f.journal.corrupt { #expect(throws: (any Error).self) { try f.engine.canRemoveOrUpdate() } }
            else { #expect(try !f.engine.canRemoveOrUpdate()) }
        }
    }
    @Test func GUIExitDisconnectLeaseAndTimerRecoverOwnRecord() throws {
        for variant in 0..<4 {
            let f = PrivilegeFixture(); _ = try f.begin(minutes: 1)
            if variant == 0 { try f.engine.disconnect(f.peer) }
            if variant == 1 { f.uptime = 1001; try f.engine.tick() }
            if variant == 2 { f.wall = f.wall.addingTimeInterval(61); try f.engine.tick() }
            if variant == 3 { _ = try f.engine.handle(Request(operation: .revoke), from: f.peer) }
            #expect(f.changes == [true, false]); #expect(f.journal.record == nil)
        }
    }
    @Test func helperRestartSameBootVersusReboot() throws {
        let f = PrivilegeFixture(); _ = try f.begin()
        let sameBoot = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { 0 }, observe: { f.state }, setDisabled: { f.changes.append($0); f.state = .enabled }, ownerLiveness: { _ in .inactive })
        try sameBoot.tick(); #expect(f.state == .enabled)
        let g = PrivilegeFixture(); _ = try g.begin()
        let otherBoot = PrivilegeEngine(journal: g.journal, boot: UUID(), now: { g.wall }, monotonic: { 0 }, observe: { g.state }, setDisabled: { g.changes.append($0) })
        #expect(throws: PrivilegeError.ownership) { try otherBoot.tick() }
        #expect(g.changes == [true])
    }
    @Test func damagedTimerExplicitRecoveryDoesNotInventOwnership() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        f.journal.record?.deadline = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: PrivilegeError.journal) { try f.engine.tick() }
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer)
        #expect(f.state == .enabled)
        let g = PrivilegeFixture(); let gid = try g.begin(); g.journal.record?.baselineEnabled = false
        #expect(throws: PrivilegeError.ownership) { try g.engine.handle(Request(operation: .recover, session: gid), from: g.peer) }
        #expect(g.changes == [true])
    }
    @Test func failedRestorationAndInterruptedRemovalKeepRecord() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); let before = f.journal.record
        f.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try f.engine.handle(Request(operation: .end, session: id), from: f.peer) }
        #expect(f.journal.record == before); #expect(try !f.engine.canRemoveOrUpdate())
        f.state = .unknown
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        #expect(f.journal.record == before)
    }
    @Test func competingVersionsAndReentrancyCannotRace() throws {
        let f = PrivilegeFixture(); try f.admit()
        f.journal.busy = true
        #expect(throws: PrivilegeError.busy) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        f.journal.busy = false
        f.onSet = { #expect(throws: PrivilegeError.busy) { try f.engine.handle(Request(operation: .begin), from: f.peer) } }
        _ = try f.engine.handle(Request(operation: .begin), from: f.peer)
        #expect(f.changes == [true])
    }
    @Test func realConcurrentRequestsSerializeOneBegin() throws {
        let f = PrivilegeFixture(); try f.admit()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { _ = try f.engine.handle(Request(operation: .begin), from: f.peer) }
            catch PrivilegeError.ownership { }
            catch { Issue.record("Unexpected concurrent outcome: \(error)") }
        }
        #expect(f.changes == [true])
        #expect(f.journal.record?.phase == .active)
    }
}
