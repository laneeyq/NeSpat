import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct GrantLifetimePolicyTests {
    func engine(_ f: PrivilegeFixture, maximum: Double? = 100) throws -> PrivilegeEngine {
        let policy=try maximum.map {try FullGrantLifetimePolicy(maximumLifetime:$0)}
        return PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{f.changes.append($0);f.state = $0 ? .disabled : .enabled},fullGrantPolicy:policy, safetySnapshot: { fixtureSafetySnapshot })
    }
    func proof(_ f: PrivilegeFixture, _ e: PrivilegeEngine, until: Double, confirmation: Double? = nil) throws -> FreshAuthorization {
        FreshAuthorization(trustedConsentFor:try e.enrollmentChallenge(for:f.peer),confirmedAt:confirmation ?? f.uptime,expires:until)
    }
    @Test(arguments:[Double(0),-1,.nan,.infinity,-.infinity]) func invalidPolicyNeverConstructs(_ value: Double) {
        #expect(throws:PrivilegeError.blocked) {try FullGrantLifetimePolicy(maximumLifetime:value)}
    }
    @Test func exactBoundaryWorksAndExpiryIsNotSilentlyShortened() throws {
        let f=PrivilegeFixture(), e=try engine(f), approval=try proof(f,e,until:110)
        try e.admit(f.peer,authorization:.fresh(approval))
        f.uptime=Double(110).nextDown
        #expect(try e.handle(Request(operation:.status),from:f.peer).state == .enabled)
        f.uptime=110
        #expect(throws:PrivilegeError.denied) {try e.handle(Request(operation:.status),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test(arguments:[Double(110).nextUp,111,Double.greatestFiniteMagnitude])
    func exceedingMaximumDeniesWithoutSideEffectsOrConsumingChallenge(_ until: Double) throws {
        let f=PrivilegeFixture(), e=try engine(f), bad=try proof(f,e,until:until)
        #expect(throws:PrivilegeError.denied) {try e.admit(f.peer,authorization:.fresh(bad))}
        #expect(f.changes.isEmpty && f.journal.writes == 0 && f.journal.record == nil)
        #expect(throws:PrivilegeError.denied) {try e.handle(Request(operation:.begin),from:f.peer)}
        let corrected=FreshAuthorization(trustedConsentFor:bad.challenge,event:bad.consentEvent,confirmedAt:10,expires:110)
        try e.admit(f.peer,authorization:.fresh(corrected)) // Rejection consumed neither event nor pending challenge.
        #expect(throws:PrivilegeError.denied) {try e.admit(f.peer,authorization:.fresh(corrected))}
    }
    @Test(arguments:Array(0..<7)) func invalidTimeEndpointsNeverIssueAuthority(_ variant: Int) throws {
        let f=PrivilegeFixture(), e=try engine(f), c=try e.enrollmentChallenge(for:f.peer)
        let confirmation: Double = variant == 0 ? 9 : variant == 1 ? 11 : variant == 2 ? .nan : variant == 3 ? -.infinity : 10
        let until: Double = variant == 4 ? .infinity : variant == 5 ? .nan : variant == 6 ? 10 : 110
        let receipt=FreshAuthorization(trustedConsentFor:c,confirmedAt:confirmation,expires:until)
        #expect(throws:PrivilegeError.denied) {try e.admit(f.peer,authorization:.fresh(receipt))}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func finiteEndpointsWhoseDifferenceOverflowsAreDenied() throws {
        let policy=try FullGrantLifetimePolicy(maximumLifetime:.greatestFiniteMagnitude)
        #expect(throws:PrivilegeError.denied) {try policy.validate(confirmedAt: -.greatestFiniteMagnitude,expires:.greatestFiniteMagnitude)}
        let f=PrivilegeFixture(); f.uptime = -.greatestFiniteMagnitude
        let e=try engine(f,maximum:.greatestFiniteMagnitude), c=try e.enrollmentChallenge(for:f.peer)
        f.uptime=0
        let receipt=FreshAuthorization(trustedConsentFor:c,confirmedAt: -.greatestFiniteMagnitude,expires:.greatestFiniteMagnitude)
        #expect(throws:PrivilegeError.denied) {try e.admit(f.peer,authorization:.fresh(receipt))}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func lifetimeIsImmutableAndIndependentOfSleepTimer() throws {
        let f=PrivilegeFixture(); var supplied=try FullGrantLifetimePolicy(maximumLifetime:100)
        let e=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{f.changes.append($0);f.state = $0 ? .disabled : .enabled},fullGrantPolicy:supplied, safetySnapshot: { fixtureSafetySnapshot })
        supplied=try FullGrantLifetimePolicy(maximumLifetime:1_000_000) // Value copy cannot change the engine.
        #expect(supplied.maximumLifetime == 1_000_000)
        #expect(throws:PrivilegeError.denied) {try e.admit(f.peer,authorization:.fresh(proof(f,e,until:111)))}
        let approval=try proof(f,e,until:110); try e.admit(f.peer,authorization:.fresh(approval))
        let id=try #require(e.handle(Request(operation:.begin,minutes:10000),from:f.peer).session)
        let sleepDeadline=f.journal.record?.deadline
        _=try e.handle(Request(operation:.changeDeadline,session:id),from:f.peer)
        #expect(sleepDeadline == f.wall.addingTimeInterval(10000*60) && f.journal.record?.deadline == nil)
        f.uptime=110
        #expect(throws:PrivilegeError.denied) {try e.handle(Request(operation:.begin),from:f.peer)}
        _=try e.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.changes == [true,false])
    }
    @Test func missingPolicyDoesNotDestroyRecoveryOrPromoteItToFull() throws {
        let f=PrivilegeFixture(); let id=try f.begin(); f.state = .unknown
        #expect(throws:PrivilegeError.unknownPower) {try f.engine.disconnect(f.peer)}
        let next=Peer(connection:UUID(),uid:f.peer.uid,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        let recovery=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{f.changes.append($0);f.state = .enabled},ownerLiveness:{_ in .inactive}) // No policy.
        try recovery.admit(next,authorization:.recoveryOnly(expires:10000))
        #expect(throws:PrivilegeError.denied) {try recovery.handle(Request(operation:.begin),from:next)}
        f.state = .disabled
        _=try recovery.handle(Request(operation:.recover,session:id),from:next)
        #expect(f.changes == [true,false] && f.journal.record == nil)
        let after=Peer(connection:UUID(),uid:f.peer.uid,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        let c=try recovery.enrollmentChallenge(for:after)
        #expect(throws:PrivilegeError.blocked) {try recovery.admit(after,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:10,expires:110)))}
    }
    @Test func reconnectRestartRevokeCannotReuseFullReceiptOrAddPolicyFromWire() throws {
        let f=PrivilegeFixture(), e=try engine(f), receipt=try proof(f,e,until:110)
        try e.admit(f.peer,authorization:.fresh(receipt)); _=try e.handle(Request(operation:.revoke),from:f.peer)
        let next=Peer(connection:UUID(),uid:f.peer.uid,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        #expect(throws:PrivilegeError.denied) {try e.admit(next,authorization:.fresh(receipt))}
        let restarted=try engine(f)
        #expect(throws:PrivilegeError.denied) {try restarted.admit(f.peer,authorization:.fresh(receipt))}
        for key in ["T_max","fullGrantPolicy","maximumLifetime","authorization","consent"] {
            let bytes=try JSONSerialization.data(withJSONObject:["version":1,"id":UUID().uuidString,"operation":"status",key:100],options:[.sortedKeys])
            #expect(throws:PrivilegeError.malformed) {try Request.decode(bytes)}
        }
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
