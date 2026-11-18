import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct HelperSecurityRegressionTests {
    @Test(arguments: [ObservedSleep.disabled, .unknown])
    func sameUUIDWithDifferentOwnerIsNotRecoveryAuthority(_ state: ObservedSleep) throws {
        let f = PrivilegeFixture(); _ = try f.begin(minutes: 1)
        f.journal.record?.owner = Peer(connection: UUID(), uid: 502, auditSession: 456, codeIdentity: "other/app")
        let substituted = f.journal.record
        f.state = state; f.wall = f.wall.addingTimeInterval(61)
        #expect(throws: PrivilegeError.ownership) { try f.engine.tick() }
        #expect(f.changes == [true]); #expect(f.journal.record == substituted)
        #expect(try !f.engine.canRemoveOrUpdate())
    }
    @Test func pendingCannotBePromotedByReplacingJournalWithSameUUID() throws {
        let f = PrivilegeFixture(); try f.admit(); f.journal.failWrite = 2
        #expect(throws: PrivilegeError.journal) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        f.journal.failWrite = nil; f.journal.record?.phase = .active; f.uptime = 1001
        #expect(throws: PrivilegeError.ownership) { try f.engine.tick() }
        #expect(f.changes == [true]); #expect(f.state == .disabled)
    }
    @Test func extendedACLIsNotProtectedByPOSIXModeAlone() throws {
        try ProtectedJournalTests().fixture { dir, fd in
            let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            try store.exclusive { try store.save(nil) }
            let file = dir.appendingPathComponent("authority.json")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow write", file.path]
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            try #require(attrs[.posixPermissions] as? Int == 0o600, "Fixture must preserve restrictive mode")
            #expect(throws: PrivilegeError.journal) { try store.exclusive { try store.load() } }
            #expect(throws: PrivilegeError.journal) { try store.exclusive { try store.save(nil) } }
        }
    }
    @Test(arguments: [false, true]) func ACLOnDirectoryOrLockAlsoBlocksAuthority(_ directory: Bool) throws {
        try ProtectedJournalTests().fixture { dir, fd in
            let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            let target = directory ? dir : dir.appendingPathComponent("lock")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow write", target.path]
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
            #expect(throws: PrivilegeError.journal) { try store.exclusive { try store.save(nil) } }
            #expect(throws: PrivilegeError.journal) { try ProtectedJournal(testDirectoryFD: fd, owner: getuid()) }
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("authority.json").path))
        }
    }
    @Test(arguments: Array(0..<4)) func ownerSubstitutionCannotBeUndoneAfterDetection(_ variant: Int) throws {
        let f = PrivilegeFixture(); let id = try f.begin(minutes: 1), original = f.journal.record
        let prior = f.peer
        f.journal.record?.owner = Peer(connection: variant == 0 ? UUID() : prior.connection,
            uid: prior.uid, auditSession: variant == 1 ? prior.auditSession + 1 : prior.auditSession,
            codeIdentity: variant == 2 ? "different/app" : prior.codeIdentity,
            process: variant == 3 ? OwnerProcessStamp(pid: 123, uid: prior.uid, startSeconds: 42, startMicroseconds: 0, bootID: f.boot) : nil)
        f.wall = f.wall.addingTimeInterval(61)
        #expect(throws: PrivilegeError.ownership) { try f.engine.tick() }
        f.journal.record = original
        #expect(throws: PrivilegeError.ownership) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        #expect(f.changes == [true]); #expect(f.journal.record == original)
    }
    @Test(arguments: Array(0..<7)) func restartNeverRestoresFullGrantOrAmbiguousAuthority(_ variant: Int) throws {
        let f = PrivilegeFixture(); let id = try f.begin(minutes: 1)
        let deadline = f.journal.record?.deadline
        if variant == 0 { f.journal.record?.phase = .pending }
        if variant == 2 { f.state = .unknown }
        if variant == 3 { f.state = .enabled }
        if variant == 4 { f.journal.record = nil }
        if variant == 6 {
            f.state = .unknown
            #expect(throws: PrivilegeError.unknownPower) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
            f.state = .disabled
        }
        let restarted = PrivilegeEngine(journal: f.journal, boot: variant == 5 ? UUID() : f.boot,
            now: { f.wall }, monotonic: { f.uptime }, observe: { f.state },
            setDisabled: { f.changes.append($0); f.state = .enabled }, ownerLiveness: { _ in .inactive })
        #expect(throws: PrivilegeError.denied) { try restarted.handle(Request(operation: .recover, session: id), from: f.peer) }
        if variant == 0 || variant == 5 { #expect(throws: PrivilegeError.ownership) { try restarted.tick() } }
        else if variant == 2 { #expect(throws: PrivilegeError.unknownPower) { try restarted.tick() } }
        else { try restarted.tick() }
        if variant == 1 || variant == 6 { #expect(f.changes == [true, false] && f.journal.record == nil) }
        else { #expect(f.changes == [true]) }
        if variant == 3 { #expect(f.journal.record == nil && f.state == .enabled) }
        if variant == 0 || variant == 2 || variant == 5 { #expect(f.journal.record?.deadline == deadline) }
        let next = Peer(connection: UUID(), uid: f.peer.uid, auditSession: f.peer.auditSession, codeIdentity: f.peer.codeIdentity)
        // Expiry-only cannot issue full authority even after a successful restart recovery.
        if f.journal.record == nil { #expect(throws: PrivilegeError.denied) { try restarted.admit(next, expires: 1000) } }
    }
    @Test func committedButUnacknowledgedPersistenceCannotReturnSuccess() throws {
        final class UncertainJournal: PersistentRecoveryJournal {
            var retry: RecoveryRetry?
            func recoverySnapshot() throws -> RecoverySnapshot { RecoverySnapshot(generation: 1, retry: retry) }
            func saveRecoveryRetry(_ value: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws { retry = value }
            var record: PrivilegedRecord?, writes = 0
            func exclusive<T>(_ body: () throws -> T) throws -> T { try body() }
            func load() throws -> PrivilegedRecord? { record }
            func save(_ value: PrivilegedRecord?) throws {
                writes += 1; record = value
                if writes == 2 { throw PrivilegeError.journal } // Models rename followed by failed directory fsync.
            }
        }
        let f = PrivilegeFixture(), journal = UncertainJournal()
        let engine = PrivilegeEngine(journal: journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: { f.changes.append($0); f.state = $0 ? .disabled : .enabled }, fullGrantPolicy: fixtureFullGrantPolicy, safetySnapshot: { fixtureSafetySnapshot })
        let challenge = try engine.enrollmentChallenge(for: f.peer)
        try engine.admit(f.peer, authorization: .fresh(FreshAuthorization(trustedConsentFor: challenge, confirmedAt: f.uptime, expires: 1000)))
        #expect(throws: PrivilegeError.journal) { try engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(journal.record?.phase == .active && f.state == .disabled)
        f.uptime = 1001
        #expect(throws: PrivilegeError.ownership) { try engine.tick() }
        #expect(f.changes == [true]); #expect(try !engine.canRemoveOrUpdate())
    }
}
