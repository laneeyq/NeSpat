import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

final class PCHarness {
    let dir: URL
    let fd: Int32
    let witness = PCWitness()
    let authority: PCAuthority
    var time: Double = 1000
    var state = ObservedSleep.disabled
    var calls = 0
    var applies = false
    var allowed = true
    var crash: PCPoint?
    var onSetter: (() throws -> Void)?
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PCError.storage }
        let f = PrivilegeFixture()
        authority = PCAuthority(record: PrivilegedRecord(id: UUID(), owner: f.peer, bootID: f.boot,
            baselineEnabled: true, phase: .active, deadline: f.wall.addingTimeInterval(100)), generation: 1)
        try store().provision(authority)
    }
    deinit { close(fd); try? FileManager.default.removeItem(at: dir) }
    func store() throws -> PCStore { try PCStore(directoryFD: fd, witness: witness) }
    var context: PCRecoveryContext { PCRecoveryContext(peer: authority.record.owner, hasRecoveryScope: true, operation: .recover) }
    func model(manual: PCManualPolicy = .sharedBudget, boot: UUID? = nil) throws -> PCPrototype {
        let s = try store()
        s.hook = { if self.crash == $0 { throw PCError.crash } }
        let p = try PCPrototype(store: s, boot: boot ?? authority.record.bootID, delay: 300, manual: manual,
            clock: { self.time }, observe: { self.state }, authorize: { _ in if !self.allowed { throw PCError.denied } }, setter: {
                self.calls += 1
                if self.crash == .duringSetter { throw PCError.crash }
                try self.onSetter?()
                if self.applies { self.state = .enabled }
            })
        p.hook = { if self.crash == $0 && $0 != .duringSetter { throw PCError.crash } }
        return p
    }
    func load() throws -> PCEnvelope { let s = try store(); return try s.lock.exclusive { try s.load() } }
    func mutate(_ body: (inout PCEnvelope) -> Void) throws {
        let s = try store(); try s.lock.exclusive { var v = try s.load(); body(&v); v.revision += 1; try s.save(v) }
    }
}

@Suite struct PersistentCooldownPrototypeTests {
    @Test func sameBootRestartAndAuthorizedRequestsSharePrototypeBudget() throws {
        let h = try PCHarness()
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        let record = try h.load()
        for op in [Operation.recover, .revoke] {
            let c = PCRecoveryContext(peer: h.authority.record.owner, hasRecoveryScope: true, operation: op)
            #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: c) }
        }
        h.time = 1299
        #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: nil) }
        let checked61 = try h.load()
        #expect(h.calls == 1 && checked61.authority == record.authority)
        h.time = 1300; h.applies = true
        try h.model().recover(expected: h.authority, context: h.context)
        let checked64 = try h.load()
        #expect(h.calls == 2 && checked64.authority == nil && checked64.retry == nil)
    }
    @Test(arguments: PCPoint.allCases)
    func everyCrashWindowRetainsCoherentCombinedState(_ point: PCPoint) throws {
        let h = try PCHarness(); h.crash = point; h.applies = true
        #expect(throws: PCError.crash) { try h.model().recover(expected: h.authority, context: nil) }
        h.crash = nil
        let value = try h.load()
        #expect(value.authority == h.authority)
        let beforeReservation = [.beforeReservation, .afterWitnessPrepare, .afterFileSync].contains(point)
        if beforeReservation {
            #expect(value.retry == nil && h.calls == 0)
            try h.model().recover(expected: h.authority, context: nil)
            let checked77 = try h.load()
            #expect(h.calls == 1 && checked77.authority == nil)
        } else if [.afterSetter, .beforeConfirmation, .beforeCleanup].contains(point) {
            #expect(h.calls == 1 && value.retry != nil && h.state == .enabled)
            try h.model().recover(expected: h.authority, context: nil)
            let checked81 = try h.load()
            #expect(h.calls == 1 && checked81.authority == nil && checked81.retry == nil)
        } else {
            #expect(value.retry != nil)
            let calls = h.calls
            #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: nil) }
            #expect(h.calls == calls)
            h.time = 1300; try h.model().recover(expected: h.authority, context: nil)
            let checked88 = try h.load()
            #expect(h.calls == calls + 1 && checked88.authority == nil)
        }
    }
    @Test(arguments: Array(0..<4))
    func exactBindingRejectsBootSessionOwnerAndGenerationSubstitution(_ variant: Int) throws {
        let h = try PCHarness()
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        try h.mutate { value in
            var r = h.authority.record; var generation = h.authority.generation
            switch variant {
            case 0: r.bootID = UUID()
            case 1: r.id = UUID()
            case 2: r.owner = Peer(connection: UUID(), uid: 502, auditSession: 123, codeIdentity: "other")
            default: generation += 1
            }
            let replacement = PCAuthority(record: r, generation: generation)
            if let retry = value.retry { value.retry = PCRetry(authority: replacement, nonce: retry.nonce, since: retry.since, last: retry.last, delay: retry.delay, failed: retry.failed, timeTrusted: retry.timeTrusted) }
        }
        #expect(throws: PCError.binding) { try h.model().recover(expected: h.authority, context: h.context) }
        let checked107 = try h.load()
        #expect(h.calls == 1 && checked107.authority == h.authority)
    }
    @Test(arguments: Array(0..<5))
    func lossCorruptionReplayAndMissingRetryNeverBecomeAllowance(_ variant: Int) throws {
        let h = try PCHarness(); let file = h.dir.appendingPathComponent("combined.json"), old = try Data(contentsOf: file)
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        switch variant {
        case 0: try FileManager.default.removeItem(at: file)
        case 1: try Data("corrupt".utf8).write(to: file)
        case 2: try old.write(to: file)
        case 3: var v = try h.load(); v.retry = nil; try PCStore.bytes(v).write(to: file)
        default: var v = try h.load(); v.authority = nil; try PCStore.bytes(v).write(to: file)
        }
        #expect(throws: (any Error).self) { try h.model().recover(expected: h.authority, context: h.context) }
        #expect(h.calls == 1)
    }
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 999])
    func invalidClockDoesNotAuthorizeRetry(_ value: Double) throws {
        let h = try PCHarness()
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        h.time = value
        #expect(throws: PCError.clock) { try h.model().recover(expected: h.authority, context: h.context) }
        let checked129 = try h.load()
        #expect(h.calls == 1 && checked129.authority == h.authority)
    }
    @Test func manualBypassStillRequiresConfirmedClockAndAuthorization() throws {
        let h = try PCHarness()
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        h.time = .nan; h.applies = true; h.allowed = false
        #expect(throws: PCError.denied) { try h.model(manual: .authorizedBypass).recover(expected: h.authority, context: h.context) }
        #expect(h.calls == 1)
        h.allowed = true
        #expect(throws: PCError.clock) { try h.model(manual: .authorizedBypass).recover(expected: h.authority, context: h.context) }
        #expect(h.calls == 1)
        h.time = 1000
        try h.model(manual: .authorizedBypass).recover(expected: h.authority, context: h.context)
        let checked139 = try h.load()
        #expect(h.calls == 2 && checked139.authority == nil)
    }
    @Test(arguments: Array(0..<4))
    func retryStateCannotMintRecoveryOrFullAuthority(_ variant: Int) throws {
        let h = try PCHarness(); var peer = h.authority.record.owner; var scope = true; var op = Operation.recover
        switch variant {
        case 0: scope = false
        case 1: peer = Peer(connection: UUID(), uid: 502, auditSession: 123, codeIdentity: "other")
        case 2: op = .begin
        default: op = .changeDeadline
        }
        let context = PCRecoveryContext(peer: peer, hasRecoveryScope: scope, operation: op)
        #expect(throws: PCError.denied) { try h.model(manual: .authorizedBypass).recover(expected: h.authority, context: context) }
        let checked152 = try h.load()
        #expect(h.calls == 0 && checked152.retry == nil)
    }
    @Test func bootChangeCannotReuseReservation() throws {
        let h = try PCHarness()
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        #expect(throws: PrivilegeError.ownership) { try h.model(boot: UUID()).recover(expected: h.authority, context: nil) }
        let checked158 = try h.load()
        #expect(h.calls == 1 && checked158.authority == h.authority)
    }
    @Test func setterReentrancyCannotConsumeAnotherReservation() throws {
        let h = try PCHarness()
        h.onSetter = {
            #expect(throws: PrivilegeError.busy) { try h.model().recover(expected: h.authority, context: nil) }
        }
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        #expect(h.calls == 1)
    }
    @Test func authorizationLossAfterReservationStopsBeforeSetter() throws {
        let h = try PCHarness(), p = try h.model()
        p.hook = { if $0 == .afterReservation { h.allowed = false } }
        #expect(throws: PCError.denied) { try p.recover(expected: h.authority, context: h.context) }
        let checked172 = try h.load()
        #expect(h.calls == 0 && checked172.retry != nil)
    }
    @Test func combinedRollbackPlusMockWitnessRollbackIsOutsideClaim() throws {
        let h = try PCHarness(), file = h.dir.appendingPathComponent("combined.json")
        let bytes = try Data(contentsOf: file), stamp = h.witness.current
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        // Characterization of the explicit MOCK witness trust assumption, not a mitigation.
        try bytes.write(to: file); h.witness.current = stamp
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        #expect(h.calls == 2)
    }
    @Test(arguments: Array(0..<4))
    func symlinkHardlinkFifoAndBroadModeAreRejected(_ variant: Int) throws {
        let h = try PCHarness(), file = h.dir.appendingPathComponent("combined.json")
        switch variant {
        case 0:
            let target = h.dir.appendingPathComponent("target"); try Data("untouched".utf8).write(to: target)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case 1:
            try FileManager.default.linkItem(at: file, to: h.dir.appendingPathComponent("hardlink"))
        case 2:
            try FileManager.default.removeItem(at: file); try #require(mkfifo(file.path, 0o600) == 0)
        default: try #require(chmod(file.path, 0o644) == 0)
        }
        #expect(throws: (any Error).self) { try h.model().recover(expected: h.authority, context: h.context) }
        #expect(h.calls == 0)
        if variant == 0 { #expect(try String(contentsOf: h.dir.appendingPathComponent("target"), encoding: .utf8) == "untouched") }
    }
    @Test func failedCompletionUsesCompletionTimeAndUnknownClockNeedsFreshInterval() throws {
        let h = try PCHarness(); h.onSetter = { h.time = 1050 }
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: nil) }
        h.time = 1349
        #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: h.context) }
        h.time = 1350; h.onSetter = { h.time = .nan }
        #expect(throws: PCError.unconfirmed) { try h.model().recover(expected: h.authority, context: h.context) }
        let failed = try h.load(); #expect(failed.retry?.timeTrusted == false && h.calls == 2)
        h.onSetter = nil; h.time = 2000
        #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: nil) }
        h.time = 2299
        #expect(throws: PCError.throttled) { try h.model().recover(expected: h.authority, context: nil) }
        h.time = 2300; h.applies = true; try h.model().recover(expected: h.authority, context: nil)
        #expect(h.calls == 3)
    }
    @Test func substitutionDuringSetterCannotBeCleanedAsOwnSession() throws {
        let h = try PCHarness()
        h.onSetter = {
            let file = h.dir.appendingPathComponent("combined.json")
            try Data("substituted".utf8).write(to: file)
        }
        #expect(throws: (any Error).self) { try h.model().recover(expected: h.authority, context: nil) }
        #expect(h.calls == 1)
        #expect(throws: (any Error).self) { try h.model().recover(expected: h.authority, context: h.context) }
        #expect(h.calls == 1)
    }

}
