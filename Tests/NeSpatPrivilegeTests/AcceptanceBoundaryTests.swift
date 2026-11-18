import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct AcceptanceBoundaryTests {
    @Test(arguments: [false, true]) func everySetterDirectionDenied(_ value: Bool) {
        #expect(throws: PrivilegeError.blocked) { try AcceptancePowerBoundary.setDisabled(value) }
    }
    @Test func noAuthorityCanBeStored() throws {
        let journal = AcceptanceAuthorityJournal()
        #expect(throws: PrivilegeError.blocked) { try journal.save(nil) }
        #expect(try journal.load() == nil)
    }
    @Test(arguments: [NeSpatPrivilegeCore.Operation.recover, .revoke, .pollRecovery, .end])
    func evenOwnedRecoveryCannotPassBoundary(_ operation: NeSpatPrivilegeCore.Operation) throws {
        let f = PrivilegeFixture(), id = try f.begin()
        let engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: AcceptancePowerBoundary.setDisabled,
            ownerLiveness: { _ in .inactive }, fullGrantPolicy: nil, safetySnapshot: { fixtureSafetySnapshot })
        try engine.admit(f.peer, authorization: .recoveryOnly(expires: 1000))
        #expect(throws: (any Error).self) { try engine.handle(Request(operation: operation, session: id), from: f.peer) }
        #expect(f.changes == [true] && f.state == .disabled)
        #expect(f.journal.record?.id == id)
        try? engine.disconnect(f.peer)
        try? engine.tick()
        #expect(f.changes == [true] && f.state == .disabled)
    }
    @Test func acceptanceEngineCannotIssueFullGrant() throws {
        let f = PrivilegeFixture()
        let engine = PrivilegeEngine(journal: AcceptanceAuthorityJournal(), boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: AcceptancePowerBoundary.setDisabled, fullGrantPolicy: nil)
        let proof = FreshAuthorization(trustedConsentFor: try engine.enrollmentChallenge(for: f.peer), confirmedAt: 10, expires: 1000)
        #expect(throws: PrivilegeError.blocked) { try engine.admit(f.peer, authorization: .fresh(proof)) }
        #expect(f.changes.isEmpty && f.state == .enabled)
    }

}
