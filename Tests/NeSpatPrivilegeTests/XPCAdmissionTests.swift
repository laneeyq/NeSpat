import Foundation
import Testing
@testable import NeSpatPrivilegeCore

private final class AdmissionSpy: @unchecked Sendable {
    private let mutex = NSLock()
    private var enrollments = 0, setters = 0
    private var sleep = ObservedSleep.enabled
    private var replied = false, rejected = false, configured = false
    func enroll() -> TimeInterval { mutex.lock(); defer { mutex.unlock() }; enrollments += 1; return 1000 }
    func set(_ disabled: Bool) { mutex.lock(); setters += 1; sleep = disabled ? .disabled : .enabled; mutex.unlock() }
    func observe() -> ObservedSleep { mutex.lock(); defer { mutex.unlock() }; return sleep }
    func response() { mutex.lock(); replied = true; mutex.unlock() }
    func error() { mutex.lock(); rejected = true; mutex.unlock() }
    func accepted() { mutex.lock(); configured = true; mutex.unlock() }
    var snapshot: (enroll: Int, setters: Int, replied: Bool, rejected: Bool, configured: Bool) {
        mutex.lock(); defer { mutex.unlock() }; return (enrollments, setters, replied, rejected, configured)
    }
}

// A rootless test listener reuses the production endpoint. It does not enable PrivilegeDeployment.
private final class AdmissionProbeListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let spy: AdmissionSpy
    let policy: SigningPolicy
    let enforceRequirement: Bool
    private let mutex = NSLock()
    private var connections: [NSXPCConnection] = []
    init(spy: AdmissionSpy, policy: SigningPolicy, enforce: Bool) { self.spy = spy; self.policy = policy; enforceRequirement = enforce }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.auditSessionIdentifier > 0 else { return false }
        if enforceRequirement { connection.setCodeSigningRequirement(policy.guiRequirement) }
        let peer = Peer(connection: UUID(), uid: connection.effectiveUserIdentifier,
                        auditSession: UInt32(connection.auditSessionIdentifier), codeIdentity: policy.guiRequirement)
        let spy = spy
        let engine = PrivilegeEngine(journal: MemoryAuthority(), boot: UUID(), now: Date.init,
                                     monotonic: { 10 }, observe: { spy.observe() }, setDisabled: { spy.set($0) }, fullGrantPolicy: fixtureFullGrantPolicy, safetySnapshot: { fixtureSafetySnapshot })
        let endpoint = PrivilegeEndpoint(engine: engine, peer: peer, enrollment: { challenge in
            // Test authority explicitly models a new independent approval; no production issuer exists.
            .fresh(FreshAuthorization(trustedConsentFor: challenge, confirmedAt: 10, expires: spy.enroll()))
        })
        connection.exportedInterface = NSXPCInterface(with: PrivilegeRPC.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.close(); spy.error() }
        mutex.lock(); connections.append(connection); mutex.unlock()
        spy.accepted(); connection.activate(); return true
    }
    func close() { mutex.lock(); let values = connections; connections.removeAll(); mutex.unlock(); values.forEach { $0.invalidate() } }
}

@Suite struct AuthenticatedEnrollmentTests {
    private func exchange(enforce: Bool) async throws -> (enroll: Int, setters: Int, replied: Bool, rejected: Bool, configured: Bool) {
        let spy = AdmissionSpy(), policy = try SigningPolicy(teamID: "ABCDE12345")
        let delegate = AdmissionProbeListener(spy: spy, policy: policy, enforce: enforce)
        let listener = NSXPCListener.anonymous(); listener.delegate = delegate; listener.activate()
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
        client.remoteObjectInterface = NSXPCInterface(with: PrivilegeRPC.self)
        client.invalidationHandler = { spy.error() }; client.interruptionHandler = { spy.error() }
        client.activate(); defer { client.invalidate(); delegate.close(); listener.invalidate() }
        let proxy = try #require(client.remoteObjectProxyWithErrorHandler { _ in spy.error() } as? PrivilegeRPC)
        let data = try JSONSerialization.data(withJSONObject: ["version":1,"id":UUID().uuidString,"operation":"begin"], options:[.sortedKeys])
        proxy.request(data) { _ in spy.response() }
        for _ in 0..<100 {
            let result = spy.snapshot
            if result.replied || result.rejected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return spy.snapshot
    }
    @Test func actualRejectedPeerNeverRunsEnrollmentOrSetter() async throws {
        let positive = try await exchange(enforce: false)
        try #require(positive.configured && positive.replied && positive.enroll == 1 && positive.setters >= 1,
                     "Rootless control simulates authenticated dispatch only; it must exercise the actual endpoint")
        let negative = try await exchange(enforce: true)
        #expect(negative.configured && negative.rejected && !negative.replied)
        #expect(negative.enroll == 0 && negative.setters == 0)
        // No accepted Developer ID client was tested; this probes only rejection plus an unguarded control.
    }
    @Test func closedEndpointAndPolicyDenialNeverFallbackOrReadmit() throws {
        let f = PrivilegeFixture(); let spy = AdmissionSpy()
        let endpoint = PrivilegeEndpoint(engine: f.engine, peer: f.peer, enrollment: { challenge in
            // Test authority explicitly models a new independent approval; no production issuer exists.
            .fresh(FreshAuthorization(trustedConsentFor: challenge, confirmedAt: 10, expires: spy.enroll()))
        })
        endpoint.close()
        let data = try JSONSerialization.data(withJSONObject: ["version":1,"id":UUID().uuidString,"operation":"begin"], options:[.sortedKeys])
        endpoint.request(data) { response in #expect(String(decoding: response, as: UTF8.self).contains("error")) }
        #expect(spy.snapshot.enroll == 0 && f.changes.isEmpty)
        let denied = PrivilegeEndpoint(engine: f.engine, peer: f.peer, enrollment: { _ in nil })
        denied.request(data) { response in #expect(String(decoding: response, as: UTF8.self).contains("error")) }
        #expect(f.changes.isEmpty)
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
    }
    @Test func endpointEnrollmentDoesNotRepeatAfterRevocation() throws {
        let f = PrivilegeFixture(); let spy = AdmissionSpy()
        let endpoint = PrivilegeEndpoint(engine: f.engine, peer: f.peer, enrollment: { challenge in
            // Test authority explicitly models a new independent approval; no production issuer exists.
            .fresh(FreshAuthorization(trustedConsentFor: challenge, confirmedAt: 10, expires: spy.enroll()))
        })
        func send(_ operation: String) throws {
            let bytes = try JSONSerialization.data(withJSONObject:["version":1,"id":UUID().uuidString,"operation":operation], options:[.sortedKeys])
            endpoint.request(bytes) { _ in }
        }
        try send("begin"); try send("revoke"); try send("begin")
        #expect(spy.snapshot.enroll == 1)
        #expect(f.changes == [true,false])
    }
    @Test func repeatedEndpointCallbackCannotRenewOldApproval() throws {
        let f = PrivilegeFixture(); let b = Peer(connection: UUID(), uid: f.peer.uid,
                                               auditSession: f.peer.auditSession, codeIdentity: f.peer.codeIdentity)
        // One explicit approval is retained. Re-running the callback cannot mint another.
        let old = try f.freshConsent(for: f.peer)
        var callbacks = 0
        let enrollment: (EnrollmentChallenge) -> EnrollmentAuthorization? = { _ in callbacks += 1; return .fresh(old) }
        let a = PrivilegeEndpoint(engine: f.engine, peer: f.peer, enrollment: enrollment)
        let next = PrivilegeEndpoint(engine: f.engine, peer: b, enrollment: enrollment)
        func send(_ endpoint: PrivilegeEndpoint, _ operation: String) throws -> String {
            let bytes = try JSONSerialization.data(withJSONObject: ["version":1,"id":UUID().uuidString,"operation":operation], options: [.sortedKeys])
            var result = ""; endpoint.request(bytes) { result = String(decoding: $0, as: UTF8.self) }; return result
        }
        #expect(try !send(a, "status").contains("error")); a.close()
        #expect(try send(next, "begin").contains("error"))
        #expect(try send(next, "begin").contains("error"))
        #expect(callbacks == 3 && f.changes.isEmpty)
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: b) }
        next.close()
    }

}
