import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct OwnerGrantRegressionTests {
    func another(_ f: PrivilegeFixture) -> Peer {
        Peer(connection: UUID(), uid: f.peer.uid, auditSession: f.peer.auditSession, codeIdentity: f.peer.codeIdentity)
    }
    @Test func duplicateFullAdmissionMustBeDenied() throws {
        let f = PrivilegeFixture(); try f.admit(); let b = another(f)
        // Even a separately modeled trusted approval must not bypass the one-full-grant limit.
        let approval = try f.freshConsent(for: b)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(b, authorization: .fresh(approval)) }
        #expect(f.changes.isEmpty)
    }
    @Test func historicalParallelGrantsAreRetiredOwnerWideWithoutLosingRecovery() throws {
        let f = PrivilegeFixture(), b = another(f), unrelated = Peer(connection: UUID(), uid: 502, auditSession: 1, codeIdentity: "other/app")
        let id = UUID()
        let input: [UUID: PrivilegeEngine.Grant] = [
            f.peer.connection: .init(peer: f.peer, expires: 1000, scope: .full, ownedSession: nil),
            b.connection: .init(peer: b, expires: 1000, scope: .full, ownedSession: id),
            unrelated.connection: .init(peer: unrelated, expires: 1000, scope: .full, ownedSession: nil)]
        // Historical two-full state is intentionally unreachable via the new admission API.
        // Exercise the exact owner-wide transition used before any journal I/O in retire().
        let output = PrivilegeEngine.revoking(input, owner: try #require(f.peer.ownerIdentity))
        if case .revoked = output[f.peer.connection]?.scope { } else { Issue.record("A retained authority") }
        if case .recovery(let bound) = output[b.connection]?.scope { #expect(bound == id) }
        else { Issue.record("B lost bound recovery or retained full authority") }
        if case .full = output[unrelated.connection]?.scope { } else { Issue.record("Unrelated owner changed") }
        #expect(output[b.connection]?.ownedSession == id)
    }
    @Test func parallelGrantCannotSurviveOwnerRevoke() throws {
        let f = PrivilegeFixture(); try f.admit(); let b = another(f)
        let stale = try f.freshConsent(for: b)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(b, authorization: .fresh(stale)) }
        _ = try f.engine.handle(Request(operation: .revoke), from: f.peer)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(b, authorization: .fresh(stale)) }
        for op in [Operation.begin, .changeDeadline] {
            #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: op, session: op == .begin ? nil : UUID()), from: b) }
        }
        #expect(f.changes.isEmpty)
    }
    @Test func enrollmentContractMustExpressFreshnessNotOnlyExpiry() throws {
        let f = PrivilegeFixture(); try f.admit(); try f.engine.disconnect(f.peer)
        #expect(throws: PrivilegeError.denied) { try f.admit(another(f)) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NeSpatPrivilegeCore/SigningAndXPC.swift"), encoding: .utf8)
        #expect(!source.contains("-> TimeInterval?"))
        #expect(source.contains("(EnrollmentChallenge) -> EnrollmentAuthorization?"))
    }
    @Test(arguments: [false, true]) func independentNewConsentAfterCleanRetirement(_ revoke: Bool) throws {
        let f = PrivilegeFixture(); try f.admit()
        if revoke { _ = try f.engine.handle(Request(operation: .revoke), from: f.peer) }
        else { try f.engine.disconnect(f.peer) }
        let next = another(f)
        #expect(throws: PrivilegeError.denied) { try f.admit(next) }
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(next, expires: 1000) }
        let fresh = try f.freshConsent(for: next) // Explicit separate test-authority approval action.
        try f.engine.admit(next, authorization: .fresh(fresh))
        _ = try f.engine.handle(Request(operation: .begin, minutes: 1), from: next)
        #expect(f.changes == [true]); #expect(f.journal.record?.owner == next)
    }
    @Test(arguments: Array(0..<8)) func revokeFaultCannotReviveParallelAuthority(_ fault: Int) throws {
        let f = PrivilegeFixture(); let id = try f.begin(); let b = another(f)
        let stale = try f.freshConsent(for: b)
        #expect(throws: PrivilegeError.ownership) { try f.engine.admit(b, authorization: .fresh(stale)) }
        let before = f.journal.record
        switch fault {
        case 0: f.state = .unknown
        case 1: f.failSetter = true
        case 2: f.apply = false
        case 3: f.journal.failWrite = f.journal.writes + 1
        case 4: f.journal.busy = true
        case 5: f.journal.corrupt = true
        case 6: f.journal.record?.baselineEnabled = false
        default: f.journal.record?.bootID = UUID()
        }
        let damaged = f.journal.record
        #expect(throws: (any Error).self) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
        #expect(f.journal.record == damaged)
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .changeDeadline, session: id, minutes: 1), from: b) }
        f.journal.busy = false; f.journal.corrupt = false; f.journal.failWrite = nil
        f.failSetter = false; f.apply = true; f.state = .disabled; f.journal.record = before
        #expect(throws: PrivilegeError.ownership) { try f.engine.admit(b, authorization: .fresh(stale)) }
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer)
        #expect(f.journal.record == nil && f.state == .enabled)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(b, authorization: .fresh(stale)) }
    }
    @Test(arguments: Array(0..<7)) func receiptsAreBoundToPeerAndEngine(_ variant: Int) throws {
        let f = PrivilegeFixture(); let receipt = try f.freshConsent(for: f.peer)
        var peer = f.peer
        if variant < 4 {
            peer = Peer(connection: variant == 0 ? UUID() : f.peer.connection,
                        uid: variant == 1 ? 502 : f.peer.uid,
                        auditSession: variant == 2 ? 999 : f.peer.auditSession,
                        codeIdentity: variant == 3 ? "other/app" : f.peer.codeIdentity)
        }
        let engine: PrivilegeEngine
        if variant >= 4 {
            engine = PrivilegeEngine(journal: f.journal, boot: variant == 4 ? UUID() : f.boot,
                                     now: { f.wall }, monotonic: { f.uptime }, observe: { f.state },
                                     setDisabled: { _ in Issue.record("Unexpected executor call") })
            if variant == 6 { _ = try engine.enrollmentChallenge(for: peer) }
        } else { engine = f.engine }
        #expect(throws: PrivilegeError.denied) { try engine.admit(peer, authorization: .fresh(receipt)) }
        #expect(throws: PrivilegeError.denied) { try engine.handle(Request(operation: .begin), from: peer) }
        #expect(f.changes.isEmpty)
    }
    @Test func oneUseConsentEventAndChallengeCancellation() throws {
        let f = PrivilegeFixture(); let proof = try f.freshConsent(for: f.peer)
        try f.engine.admit(f.peer, authorization: .fresh(proof)); try f.engine.disconnect(f.peer)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(f.peer, authorization: .fresh(proof)) }
        let next = another(f), challenge = try f.engine.enrollmentChallenge(for: next)
        let replay = FreshAuthorization(trustedConsentFor: challenge, event: proof.consentEvent, confirmedAt: f.uptime, expires: 1000)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(next, authorization: .fresh(replay)) }
        let fresh = try f.freshConsent(for: next); f.engine.cancelEnrollment(for: next)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(next, authorization: .fresh(fresh)) }
        #expect(f.changes.isEmpty)
    }
    @Test(arguments: Array(0..<6)) func invalidConsentTimesAndUnknownBaseline(_ variant: Int) throws {
        let f = PrivilegeFixture(), challenge = try f.engine.enrollmentChallenge(for: f.peer)
        let confirmation: Double = variant == 0 ? 9 : variant == 1 ? 11 : variant == 2 ? .nan : 10
        let until: Double = variant == 3 ? 10 : variant == 4 ? .infinity : 1000
        if variant == 5 { f.state = .unknown }
        let proof = FreshAuthorization(trustedConsentFor: challenge, confirmedAt: confirmation, expires: until)
        #expect(throws: (any Error).self) { try f.engine.admit(f.peer, authorization: .fresh(proof)) }
        #expect(f.changes.isEmpty && f.journal.record == nil)
    }
    @Test func freshConsentCannotPromoteRecoveryOrAmbiguousJournal() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.state = .unknown
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.disconnect(f.peer) }
        let next = another(f), proof = try f.freshConsent(for: next)
        try f.engine.admit(next, authorization: .fresh(proof))
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: next) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .changeDeadline, session: id, minutes: 1), from: next) }
        f.state = .disabled
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: next)
        #expect(f.changes == [true, false])
        let g = PrivilegeFixture(); _ = try g.begin(); g.journal.record = nil; g.state = .enabled
        #expect(throws: PrivilegeError.ownership) { try g.engine.handle(Request(operation: .revoke), from: g.peer) }
        let other = another(g), fresh = try g.freshConsent(for: other)
        #expect(throws: PrivilegeError.ownership) { try g.engine.admit(other, authorization: .fresh(fresh)) }
        #expect(g.changes == [true])
    }
    @Test func concurrentRetirementBeginAndTickCannotRestoreOldFullGrant() throws {
        let f = PrivilegeFixture(); try f.admit(); let b = another(f), stale = try f.freshConsent(for: b)
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            do {
                switch index % 5 {
                case 0: _ = try f.engine.handle(Request(operation: .revoke), from: f.peer)
                case 1: try f.engine.disconnect(f.peer)
                case 2: _ = try f.engine.handle(Request(operation: .begin), from: b)
                case 3: try f.engine.tick()
                default: try f.engine.admit(b, authorization: .fresh(stale))
                }
                if index % 5 == 2 || index % 5 == 4 { Issue.record("Parallel authority survived") }
            } catch PrivilegeError.denied { }
            catch PrivilegeError.ownership { }
            catch { Issue.record("Unexpected race outcome: \(error)") }
        }
        #expect(f.changes.isEmpty && f.journal.record == nil)
    }
}
