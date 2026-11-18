import Foundation
import Testing
@testable import NeSpatPrivilegeCore
@Suite struct LocalAutomaticTrustTests {
    @Test func explicitSetupDelegationIsBoundedAndCannotReplayOrExtendStoredLease() throws {
        let f = PrivilegeFixture()
        let engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
            observe: { f.state }, setDisabled: { f.changes.append($0); f.state = $0 ? .disabled : .enabled },
            fullGrantPolicy: .production, safetySnapshot: { fixtureSafetySnapshot }, retryClock: { f.uptime })
        let challenge = try engine.enrollmentChallenge(for: f.peer)
        // MOCK trusted setup authority; production construction is only in the protected profile.
        let proof = LocalSetupAuthorization(challenge: challenge, setup: UUID(), issued: 10, expires: 43210)
        try engine.admit(f.peer, authorization: .localSetup(proof))
        let id = try #require(engine.handle(Request(operation: .begin, minutes: 720), from: f.peer).session)
        #expect(f.journal.record?.authorityExpires == 43210)
        #expect(throws: PrivilegeError.denied) { try engine.admit(f.peer, authorization: .localSetup(proof)) }
        _ = try engine.handle(Request(operation: .changeDeadline, session: id, minutes: 10000), from: f.peer)
        #expect(f.journal.record?.authorityExpires == 43210)
        f.uptime = 43210; try engine.tick()
        #expect(f.state == .enabled && f.changes == [true, false] && f.journal.record == nil)
    }
    @Test func localPolicyRequiresExactIdentifiersAndNeverBroadensPublisherRequirement() throws {
        let hash = String(repeating: "a", count: 40)
        let gui = try ExactCodePin(codeDirectoryHash: hash, signingIdentifier: SigningPolicy.guiIdentifier)
        let helper = try ExactCodePin(codeDirectoryHash: hash, signingIdentifier: SigningPolicy.helperIdentifier)
        let policy = try SigningPolicy(approvedLocalGUI: gui, helper: helper)
        #expect(policy.guiRequirement == gui.requirement && policy.helperRequirement == helper.requirement)
        #expect(throws: PrivilegeError.blocked) { try SigningPolicy(approvedLocalGUI: helper, helper: gui) }
        // No profile file is created or read as an authorization fixture.
        #expect(!policy.matchesFile(URL(fileURLWithPath: "/usr/bin/true"), helper: true))
    }
    @Test func turningAutomaticModeOffRetiresFullGrantBeforeOrdinaryRecovery() throws {
        let f = PrivilegeFixture(), id = try f.begin()
        let reply = try f.engine.handle(Request(operation: .pollRecovery, session: id), from: f.peer)
        #expect(reply.state == .enabled && reply.session == nil && reply.fullAuthority == false)
        #expect(f.changes == [true, false])
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
    }

}
