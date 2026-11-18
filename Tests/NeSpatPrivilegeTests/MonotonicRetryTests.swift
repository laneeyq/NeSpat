import Foundation
import Testing
@testable import NeSpatPrivilegeCore

private final class RetryFixture {
    let f = PrivilegeFixture()
    var usesDefaultClock = false
    var retryTime: Double = 1000
    var reading = fixtureSafetySnapshot
    lazy var engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { self.f.wall },
        monotonic: { self.f.uptime }, observe: { self.f.state },
        setDisabled: { value in
            self.f.changes.append(value)
            if self.f.apply { self.f.state = value ? .disabled : .enabled }
        }, ownerLiveness: { _ in .inactive }, safetySnapshot: { self.reading },
        retryClock: usesDefaultClock ? nil : { self.retryTime })
    init() { install(); f.apply = false }
    func install() {
        f.state = .disabled
        f.journal.record = PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot,
            baselineEnabled: true, phase: .active, deadline: f.wall.addingTimeInterval(-1))
    }
    func fail() throws {
        #expect(throws: PrivilegeError.unconfirmed) { try engine.tick() }
    }
}

@Suite struct MonotonicRetryTests {
    @Test(arguments: [86400.0, -86400.0])
    func wallJumpCannotChangeRetryInterval(_ jump: Double) throws {
        let h = RetryFixture(); try h.fail(); let record = h.f.journal.record
        h.f.wall = h.f.wall.addingTimeInterval(jump)
        try h.engine.tick()
        #expect(h.f.changes == [false] && h.f.journal.record == record)
        h.retryTime = 1299; try h.engine.tick()
        #expect(h.f.changes == [false] && h.f.journal.record == record)
        h.retryTime = 1300; try h.fail()
        #expect(h.f.changes == [false, false] && h.f.journal.record == record)
        try h.engine.tick()
        #expect(h.f.changes == [false, false])
    }
    @Test func repeatedPollsWaitForExactBoundaryAndKeepJournal() throws {
        let h = RetryFixture(); try h.fail(); let record = h.f.journal.record
        for t in [1000.0, 1001, 1299, Double(1300).nextDown] {
            h.retryTime = t; try h.engine.tick()
            #expect(h.f.changes == [false] && h.f.journal.record == record)
        }
        h.retryTime = 1300; h.f.apply = true; try h.engine.tick()
        #expect(h.f.changes == [false, false] && h.f.state == .enabled && h.f.journal.record == nil)
    }
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 999])
    func invalidOrRegressedClockRearmsConservatively(_ bad: Double) throws {
        let h = RetryFixture(); try h.fail(); let record = h.f.journal.record
        h.retryTime = 1100; try h.engine.tick()
        h.retryTime = bad; #expect(throws: PrivilegeError.blocked) { try h.engine.tick() }
        #expect(h.f.changes == [false] && h.f.journal.record == record)
        h.retryTime = 1200; try h.engine.tick()
        h.retryTime = 1499; try h.engine.tick()
        #expect(h.f.changes == [false] && h.f.journal.record == record)
        h.retryTime = 1500; try h.fail()
        #expect(h.f.changes == [false, false] && h.f.journal.record == record)
    }
    @Test func invalidStartCannotAuthorizeImmediateRepeat() throws {
        let h = RetryFixture(); h.retryTime = .nan
        #expect(throws: PrivilegeError.blocked) { try h.engine.tick() }
        #expect(h.f.changes.isEmpty)
        h.retryTime = 9000; try h.fail()
        h.retryTime = 9299; try h.engine.tick()
        #expect(h.f.changes == [false])
        h.retryTime = 9300; try h.fail()
        #expect(h.f.changes == [false, false])
    }
    @Test func manualRecoveryRequiresTrustedTimeAndThenBypassesCooldown() throws {
        let h = RetryFixture(); try h.fail(); let id = try #require(h.f.journal.record?.id)
        try h.engine.admit(h.f.peer, expires: 1000)
        h.retryTime = .nan; h.f.apply = true
        #expect(throws: PrivilegeError.blocked) { try h.engine.handle(Request(operation: .recover, session: id), from: h.f.peer) }
        #expect(h.f.journal.record?.id == id && h.f.changes == [false])
        h.retryTime = 1000
        _ = try h.engine.handle(Request(operation: .recover, session: id), from: h.f.peer)
        #expect(h.f.changes == [false, false] && h.f.journal.record == nil && h.f.state == .enabled)
    }
    @Test func confirmedOrdinarySleepCleansUpWithoutSetterOrValidClock() throws {
        let h = RetryFixture(); try h.fail()
        h.retryTime = .infinity; h.f.state = .enabled; try h.engine.tick()
        #expect(h.f.changes == [false] && h.f.journal.record == nil)
        h.install(); let id = h.f.journal.record?.id
        #expect(throws: PrivilegeError.blocked) { try h.engine.tick() }
        h.retryTime = 1000; try h.fail()
        #expect(h.f.changes == [false, false] && h.f.journal.record?.id == id)
    }
    @Test func substitutedUUIDCannotUseClockToAuthorizeRestoration() throws {
        let h = RetryFixture(); try h.fail(); h.install(); let record = h.f.journal.record
        h.retryTime = 9000
        #expect(throws: PrivilegeError.ownership) { try h.engine.tick() }
        #expect(h.f.changes == [false] && h.f.journal.record == record)
    }
    @Test func criticalConditionUsesApprovedThirtySecondCooldown() throws {
        let h = RetryFixture(); h.reading = PowerSafetySnapshot(thermalSerious: true)
        try h.fail(); let record = h.f.journal.record
        h.retryTime = 1029; try h.engine.tick()
        #expect(h.f.changes == [false] && h.f.journal.record == record)
        h.retryTime = 1030; try h.fail()
        #expect(h.f.changes == [false, false] && h.f.journal.record == record)
    }
    @Test func defaultContinuousClockIgnoresWallAndAuthorityClockJumps() throws {
        let h = RetryFixture(); h.usesDefaultClock = true; try h.fail()
        let record = h.f.journal.record
        for jump in [86400.0, -172800.0] {
            h.f.wall = h.f.wall.addingTimeInterval(jump); h.f.uptime += 10000
            h.retryTime += 10000; try h.engine.tick()
            #expect(h.f.changes == [false] && h.f.journal.record == record)
        }
    }
    @Test func noSetterAttemptDoesNotStartCooldown() throws {
        let h = RetryFixture(); h.f.state = .unknown
        let record = h.f.journal.record
        #expect(throws: PrivilegeError.unknownPower) { try h.engine.tick() }
        #expect(h.f.changes.isEmpty && h.f.journal.record == record)
        h.f.state = .disabled; try h.fail()
        #expect(h.f.changes == [false] && h.f.journal.record == record)
    }
    @Test func manuallyRecoveredUUIDDoesNotThrottleNextSession() throws {
        let h = RetryFixture(); try h.fail(); let id = try #require(h.f.journal.record?.id)
        try h.engine.admit(h.f.peer, expires: 1000); h.f.apply = true
        _ = try h.engine.handle(Request(operation: .recover, session: id), from: h.f.peer)
        #expect(h.f.journal.record == nil)
        h.install(); h.f.apply = false; let next = h.f.journal.record
        #expect(next?.id != id); try h.fail()
        #expect(h.f.changes == [false, false, false] && h.f.journal.record == next)
    }
    @Test func elapsedSleepIntervalPermitsRetryOnNextPoll() throws {
        let h = RetryFixture(); try h.fail()
        // Simulated continuous time includes system sleep; no real sleep or wake performed.
        h.retryTime = 1600; h.f.apply = true; try h.engine.tick()
        #expect(h.f.changes == [false, false] && h.f.journal.record == nil)
    }
}
