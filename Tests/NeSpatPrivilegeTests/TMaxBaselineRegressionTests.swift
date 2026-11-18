import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct TMaxBaselineRegressionTests {
    func engineWithoutPolicy(_ f: PrivilegeFixture) -> PrivilegeEngine {
        PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{ f.changes.append($0); f.state = $0 ? .disabled : .enabled })
    }
    @Test func noTrustedLifetimePolicyCannotIssueFullGrant() throws {
        let f=PrivilegeFixture(), engine=engineWithoutPolicy(f)
        let challenge=try engine.enrollmentChallenge(for:f.peer)
        let proof=FreshAuthorization(trustedConsentFor:challenge,confirmedAt:f.uptime,expires:f.uptime+100)
        #expect(throws:PrivilegeError.blocked) {try engine.admit(f.peer,authorization:.fresh(proof))}
        #expect(throws:PrivilegeError.denied) {try engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func finiteHugeExpiryIsNotAReplacementForServerPolicy() throws {
        let f=PrivilegeFixture(), engine=engineWithoutPolicy(f)
        let challenge=try engine.enrollmentChallenge(for:f.peer)
        let proof=FreshAuthorization(trustedConsentFor:challenge,confirmedAt:f.uptime,expires:.greatestFiniteMagnitude)
        #expect(throws:PrivilegeError.blocked) {try engine.admit(f.peer,authorization:.fresh(proof))}
        #expect(throws:PrivilegeError.denied) {try engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
