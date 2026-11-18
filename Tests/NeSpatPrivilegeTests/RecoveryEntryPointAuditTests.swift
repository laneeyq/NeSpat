import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct RecoveryEntryPointAuditTests {
    @Test(arguments: [Operation.recover, .revoke, .end])
    func freshAuthorizedRequestIDsCurrentlyBypassSharedRateLimit(_ operation: NeSpatPrivilegeCore.Operation) throws {
        let h = CriticalAuditFixture(), id = try h.begin(); h.f.failSetter = true
        for _ in 0..<2 {
            let request = Request(operation: operation, session: operation == .revoke ? nil : id)
            #expect(throws: PrivilegeError.unconfirmed) { try h.engine.handle(request, from: h.f.peer) }
        }
        // OPEN production-policy gap: this is deliberately characterization, not repair.
        #expect(h.f.changes == [true, false, false] && h.f.journal.record?.id == id)
    }
    @Test func replayedIDAndForeignPeerCannotUseRetryGap() throws {
        let h = CriticalAuditFixture(), id = try h.begin(); h.f.failSetter = true
        let request = Request(operation: .recover, session: id)
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.handle(request, from: h.f.peer) }
        #expect(throws: PrivilegeError.replay) { try h.engine.handle(request, from: h.f.peer) }
        let stranger = Peer(connection: h.f.peer.connection, uid: 502, auditSession: 123, codeIdentity: "other")
        #expect(throws: PrivilegeError.denied) { try h.engine.handle(Request(operation: .recover, session: id), from: stranger) }
        #expect(h.f.changes == [true, false] && h.f.journal.record?.id == id)
    }
    @Test func reconnectIsRecoveryOnlyDespiteFailedDisconnectAndDoesNotMintFreshConsent() throws {
        let h = CriticalAuditFixture(), id = try h.begin(); h.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.disconnect(h.f.peer) }
        let next = Peer(connection: UUID(), uid: h.f.peer.uid, auditSession: h.f.peer.auditSession, codeIdentity: h.f.peer.codeIdentity)
        try h.engine.admit(next, expires: 1000)
        #expect(throws: PrivilegeError.denied) { try h.engine.handle(Request(operation: .begin), from: next) }
        #expect(throws: PrivilegeError.unconfirmed) { try h.engine.handle(Request(operation: .recover, session: id), from: next) }
        #expect(h.f.changes == [true, false, false] && h.f.journal.record?.id == id)
    }
}
