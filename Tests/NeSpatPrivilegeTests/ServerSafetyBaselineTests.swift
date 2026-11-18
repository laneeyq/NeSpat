import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct ServerSafetyBaselineTests {
    @Test func fullGrantWithoutTrustedServerSafetyInputCannotChangePower() throws {
        let f=PrivilegeFixture()
        let engine=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{f.changes.append($0);f.state = .disabled},fullGrantPolicy:fixtureFullGrantPolicy)
        let c=try engine.enrollmentChallenge(for:f.peer)
        try engine.admit(f.peer,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:10,expires:100)))
        #expect(throws:PrivilegeError.blocked) {try engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
