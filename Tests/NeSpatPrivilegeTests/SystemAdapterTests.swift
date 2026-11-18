import Foundation
import CoreFoundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

private final class InvocationSpy: FixedPowerInvoking {
    var plans: [FixedPowerInvocation] = []
    var status: Int32 = 0
    var error: PrivilegeError?
    func perform(_ plan: FixedPowerInvocation) throws -> Int32 {
        plans.append(plan)
        if let error { throw error }; return status
    }
}

@Suite struct SystemAdapterTests {
    @Test func strictIndependentSleepDecoding() {
        #expect(SystemSleepObservation.decode(kCFBooleanFalse) == .enabled)
        #expect(SystemSleepObservation.decode(kCFBooleanTrue) == .disabled)
        #expect(SystemSleepObservation.decode(NSNumber(value: Int32(0))) == .enabled)
        #expect(SystemSleepObservation.decode(NSNumber(value: Int32(1))) == .disabled)
        for value: CFTypeRef? in [nil, NSNumber(value: -1), NSNumber(value: 2), NSNumber(value: 1.0),
                                 "0" as CFString, Data() as CFData, NSNull()] {
            #expect(SystemSleepObservation.decode(value) == .unknown)
        }
    }
    @Test func bootParsingHasNoRandomOrEmptyFallback() {
        let id = UUID(), valid = Array(id.uuidString.utf8) + [0]
        #expect(SystemBootIdentity.decode(valid) == id)
        for bytes in [[], [0], Array(valid.dropLast()), valid + [0], Array("not-a-boot-id".utf8) + [0],
                      Array(repeating: UInt8(255), count: 37)] {
            #expect(SystemBootIdentity.decode(bytes) == nil)
        }
    }
    func stamp(pid: Int32 = 123, uid: UInt32 = 501, start: UInt64 = 42, microseconds: UInt64 = 123, boot: UUID) -> OwnerProcessStamp {
        OwnerProcessStamp(pid: pid, uid: uid, startSeconds: start, startMicroseconds: microseconds, bootID: boot)
    }
    @Test func PIDReuseUnknownAndBootChangeNeverAppearAsLiveOriginalOwner() {
        let boot = UUID(), expected = stamp(boot: boot)
        #expect(SystemOwnerLiveness.evaluate(expected, boot: boot, snapshot: .process(expected)) == .active)
        #expect(SystemOwnerLiveness.evaluate(expected, boot: boot, snapshot: .absent) == .inactive)
        #expect(SystemOwnerLiveness.evaluate(expected, boot: boot, snapshot: .unavailable) == .unknown)
        #expect(SystemOwnerLiveness.evaluate(expected, boot: nil, snapshot: .absent) == .unknown)
        #expect(SystemOwnerLiveness.evaluate(expected, boot: UUID(), snapshot: .process(expected)) == .unknown)
        #expect(SystemOwnerLiveness.evaluate(nil, boot: boot, snapshot: .absent) == .unknown)
        for actual in [stamp(start: 43, boot: boot), stamp(uid: 502, boot: boot), stamp(microseconds: 124, boot: boot)] {
            #expect(SystemOwnerLiveness.evaluate(expected, boot: boot, snapshot: .process(actual)) == .inactive)
        }
        #expect(SystemOwnerLiveness.evaluate(expected, boot: boot, snapshot: .process(stamp(pid: 124, boot: boot))) == .unknown)
        #expect(SystemOwnerLiveness.evaluate(stamp(microseconds: 1_000_000, boot: boot), boot: boot, snapshot: .absent) == .unknown)
    }
    @Test func actualKernelBootAndOwnProcessAreReadOnlyAndMatch() throws {
        let boot = try #require(SystemBootIdentity.read())
        guard case .process(let actual) = SystemOwnerLiveness.snapshot(pid: getpid(), boot: boot) else {
            Issue.record("Kernel process query unavailable; requires ordinary user process outside file sandbox"); return
        }
        #expect(actual.pid == getpid() && actual.uid == getuid() && actual.isValid)
        let peer = Peer(connection: UUID(), uid: getuid(), auditSession: 1, codeIdentity: "fixture/only", process: actual)
        #expect(SystemOwnerLiveness.read(peer) == .active)
        #expect(SystemOwnerLiveness.read(Peer(connection: UUID(), uid: getuid() + 1, auditSession: 1,
                                             codeIdentity: "fixture/only", process: actual)) == .unknown)
    }
    @Test func processStampIsJournalMetadataAndCannotBeClaimedInRPC() throws {
        let boot = UUID(), process = stamp(boot: boot)
        let peer = Peer(connection: UUID(), uid: 501, auditSession: 123, codeIdentity: "fixture/only", process: process)
        #expect(try JSONDecoder().decode(Peer.self, from: JSONEncoder().encode(peer)) == peer)
        #expect(peer.hasVerifiedIdentity)
        #expect(!Peer(connection: UUID(), uid: 502, auditSession: 123, codeIdentity: "fixture/only", process: process).hasVerifiedIdentity)
        let wire = try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
            "operation": "status", "process": ["pid": 123, "uid": 501]], options: [.sortedKeys])
        #expect(throws: PrivilegeError.malformed) { try Request.decode(wire) }
        let f = PrivilegeFixture(), oldBoot = stamp(boot: UUID())
        let wrong = Peer(connection: UUID(), uid: 501, auditSession: 123, codeIdentity: "fixture/only", process: oldBoot)
        let proof = try f.freshConsent(for: wrong)
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(wrong, authorization: .fresh(proof)) }
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test(arguments: [false, true]) func onlyTwoFixedPlansWithIndependentConfirmation(_ disabled: Bool) throws {
        let spy = InvocationSpy()
        let executor = VerifiedPowerExecutor(invocation: spy, observe: { disabled ? .disabled : .enabled })
        try executor.setDisabled(disabled)
        #expect(spy.plans == [disabled ? .disableSleep : .restoreSleep])
    }
    @Test func exitZeroDoesNotProveSleepStateAndFailureDoesNotRetry() throws {
        for state in [ObservedSleep.disabled, .unknown] {
            let spy = InvocationSpy(), executor = VerifiedPowerExecutor(invocation: spy, observe: { state })
            #expect(throws: state == .unknown ? PrivilegeError.unknownPower : .unconfirmed) { try executor.setDisabled(false) }
            #expect(spy.plans == [.restoreSleep])
        }
        let spy = InvocationSpy(); spy.status = 1
        let executor = VerifiedPowerExecutor(invocation: spy, observe: { Issue.record("Nonzero exit cannot be success"); return .enabled })
        #expect(throws: PrivilegeError.unconfirmed) { try executor.setDisabled(false) }
        spy.status = 0; spy.error = .unconfirmed
        #expect(throws: PrivilegeError.unconfirmed) { try executor.setDisabled(false) }
        #expect(spy.plans.count == 2)
    }
    @Test func unavailableSystemConsentCannotIssueAReceipt() throws {
        let f = PrivilegeFixture(), challenge = try f.engine.enrollmentChallenge(for: f.peer)
        #expect(throws: PrivilegeError.blocked) { try SystemConsentVerifier.authorize(challenge) }
        #expect(throws: PrivilegeError.denied) { try f.engine.admit(f.peer, expires: 1000) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func directInvocationCannotImpersonateAuthenticatedXPCDispatch() throws {
        let f = PrivilegeFixture(), listener = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        defer { connection.invalidate(); listener.invalidate() }
        let endpoint = AuthenticatedPrivilegeEndpoint(connection: connection, policy: try SigningPolicy(teamID: "ABCDE12345"),
            engine: f.engine, enrollment: { _ in Issue.record("Unauthenticated dispatch reached enrollment"); return nil })
        let bytes = try JSONSerialization.data(withJSONObject: ["version":1,"id":UUID().uuidString,"operation":"begin"], options: [.sortedKeys])
        endpoint.request(bytes) { #expect(String(decoding: $0, as: UTF8.self).contains("error")) }
        endpoint.close(); endpoint.request(bytes) { #expect(String(decoding: $0, as: UTF8.self).contains("error")) }
        #expect(f.changes.isEmpty && f.journal.writes == 0)
        #expect(throws: PrivilegeError.denied) { try PrivilegeClient.validateReplyPeer(connection) }
        let delegate = PrivilegeListener(policy: try SigningPolicy(teamID: "ABCDE12345"), engine: f.engine, enrollment: { _ in nil })
        #expect(throws: PrivilegeError.blocked) { try delegate.preparedListener() }
    }
}
