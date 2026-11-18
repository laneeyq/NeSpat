import Foundation
import Testing
@testable import NeSpatPrivilegeCore

// Existing engine contract, with a modeled trusted authority only. No OS authorization
// call, cache purge, dialog or production issuer is executed by these tests.
@Suite struct FreshConsentContractTests {
    @Test(arguments:Array(0..<8)) func receiptBindsAllChallengeAndAuthenticatedPeerFields(_ variant: Int) throws {
        let f=PrivilegeFixture(), c=try f.engine.enrollmentChallenge(for:f.peer)
        let other=Peer(connection:variant == 4 ? UUID() : c.peer.connection,
            uid:variant == 5 ? 502 : c.peer.uid,auditSession:variant == 6 ? 999 : c.peer.auditSession,
            codeIdentity:variant == 7 ? "other/app" : c.peer.codeIdentity)
        let forged=EnrollmentChallenge(nonce:variant == 0 ? UUID() : c.nonce,engine:variant == 1 ? UUID() : c.engine,
            boot:variant == 2 ? UUID() : c.boot,ownerEpoch:variant == 3 ? UUID() : c.ownerEpoch,peer:other,issuedAt:c.issuedAt)
        let proof=FreshAuthorization(trustedConsentFor:forged,confirmedAt:f.uptime,expires:f.uptime+100)
        #expect(throws:PrivilegeError.denied) {try f.engine.admit(f.peer,authorization:.fresh(proof))}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test(arguments:Array(0..<5)) func consentHasFiniteAndCurrentMonotonicWindow(_ variant: Int) throws {
        let f=PrivilegeFixture(), c=try f.engine.enrollmentChallenge(for:f.peer)
        let confirmation: Double = variant == 0 ? c.issuedAt-1 : variant == 1 ? f.uptime+1 : variant == 2 ? .nan : f.uptime
        let end: Double = variant == 3 ? .infinity : variant == 4 ? f.uptime : f.uptime+100
        let proof=FreshAuthorization(trustedConsentFor:c,confirmedAt:confirmation,expires:end)
        #expect(throws:PrivilegeError.denied) {try f.engine.admit(f.peer,authorization:.fresh(proof))}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func expiredReceiptAndRevokedEventCannotBeReusedAfterNewChallenge() throws {
        let f=PrivilegeFixture(), proof=try f.freshConsent(for:f.peer)
        f.uptime=proof.expires
        #expect(throws:PrivilegeError.denied) {try f.engine.admit(f.peer,authorization:.fresh(proof))}
        let g=PrivilegeFixture(), used=try g.freshConsent(for:g.peer)
        try g.engine.admit(g.peer,authorization:.fresh(used)); _=try g.engine.handle(Request(operation:.revoke),from:g.peer)
        let next=Peer(connection:UUID(),uid:g.peer.uid,auditSession:g.peer.auditSession,codeIdentity:g.peer.codeIdentity)
        let freshChallenge=try g.engine.enrollmentChallenge(for:next)
        let replay=FreshAuthorization(trustedConsentFor:freshChallenge,event:used.consentEvent,confirmedAt:g.uptime,expires:g.uptime+100)
        #expect(throws:PrivilegeError.denied) {try g.engine.admit(next,authorization:.fresh(replay))}
        #expect(f.changes.isEmpty && g.changes.isEmpty)
    }
    @Test func freshReceiptCannotExpandRecoveryScope() throws {
        let f=PrivilegeFixture(); let id=try f.begin(); f.state = .unknown
        #expect(throws:PrivilegeError.unknownPower) {try f.engine.disconnect(f.peer)}
        let next=Peer(connection:UUID(),uid:f.peer.uid,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        let proof=try f.freshConsent(for:next)
        try f.engine.admit(next,authorization:.fresh(proof))
        #expect(throws:PrivilegeError.denied) {try f.engine.handle(Request(operation:.begin),from:next)}
        #expect(throws:PrivilegeError.denied) {try f.engine.handle(Request(operation:.changeDeadline,session:id,minutes:1),from:next)}
        #expect(f.changes == [true])
    }
    @Test func unavailableVerifierAndCanceledConsentNeverProduceFullAuthority() throws {
        let f=PrivilegeFixture(), challenge=try f.engine.enrollmentChallenge(for:f.peer)
        #expect(throws:PrivilegeError.blocked) {try SystemConsentVerifier.authorize(challenge)}
        #expect(throws:PrivilegeError.denied) {try f.engine.admit(f.peer,expires:f.uptime+100)}
        let endpoint=PrivilegeEndpoint(engine:f.engine,peer:f.peer,enrollment:{_ in nil}) // Modeled cancellation/denial.
        endpoint.request(try HelperWire.requestData(Request(operation:.begin))) {response in #expect(response == HelperWire.denied)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
