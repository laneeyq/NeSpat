import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

private final class BoundaryState: @unchecked Sendable {
    private let mutex = NSLock()
    private var delegates = 0, enrollments = 0, setters = 0
    private var answered = false, failed = false
    private var sleep = ObservedSleep.enabled
    func accepted() { mutex.lock(); delegates += 1; mutex.unlock() }
    func enrolled(_ peer: Peer) {
        mutex.lock(); enrollments += 1; mutex.unlock()
        #expect(peer.uid == getuid() && peer.process?.pid == getpid())
        #expect(peer.process?.uid == getuid() && peer.auditSession > 0)
    }
    func set(_ disabled: Bool) { mutex.lock(); setters += 1; sleep = disabled ? .disabled : .enabled; mutex.unlock() }
    func observe() -> ObservedSleep { mutex.lock(); defer { mutex.unlock() }; return sleep }
    func response() { mutex.lock(); answered = true; mutex.unlock() }
    func error() { mutex.lock(); failed = true; mutex.unlock() }
    var snapshot: (delegates: Int, enrollment: Int, setters: Int, replied: Bool, rejected: Bool) {
        mutex.lock(); defer { mutex.unlock() }; return (delegates, enrollments, setters, answered, failed)
    }
}
private final class BoundaryListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let state: BoundaryState, policy: SigningPolicy, boot: UUID
    let requireMessage: Bool
    private let mutex = NSLock()
    private var connections: [NSXPCConnection] = []
    init(state: BoundaryState, policy: SigningPolicy, boot: UUID, requireMessage: Bool) {
        self.state = state; self.policy = policy; self.boot = boot; self.requireMessage = requireMessage
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        state.accepted()
        if requireMessage { connection.setCodeSigningRequirement(policy.guiRequirement) }
        let state = state
        let engine = PrivilegeEngine(journal: MemoryAuthority(), boot: boot, now: Date.init,
                                     monotonic: { 10 }, observe: { state.observe() }, setDisabled: { state.set($0) }, fullGrantPolicy: fixtureFullGrantPolicy, safetySnapshot: { fixtureSafetySnapshot })
        let endpoint = AuthenticatedPrivilegeEndpoint(connection: connection, policy: policy, engine: engine, enrollment: { challenge in
            state.enrolled(challenge.peer)
            return .fresh(FreshAuthorization(trustedConsentFor: challenge, confirmedAt: 10, expires: 1000))
        })
        connection.exportedInterface = NSXPCInterface(with: PrivilegeRPC.self); connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.close() }; connection.interruptionHandler = { endpoint.close() }
        mutex.lock(); connections.append(connection); mutex.unlock()
        connection.activate(); return true
    }
    func close() { mutex.lock(); let all = connections; connections.removeAll(); mutex.unlock(); all.forEach { $0.invalidate() } }
}

@Suite struct ListenerBoundaryTests {
    private func exchange(listenerCheck: Bool = false, messageCheck: Bool = false, helperCheck: Bool = false) async throws
        -> (delegates: Int, enrollment: Int, setters: Int, replied: Bool, rejected: Bool) {
        let state = BoundaryState(), policy = try SigningPolicy(teamID: "ABCDE12345")
        let delegate = BoundaryListener(state: state, policy: policy, boot: try #require(SystemBootIdentity.read()), requireMessage: messageCheck)
        let listener = NSXPCListener.anonymous()
        if listenerCheck { policy.requireClient(on: listener) }
        listener.delegate = delegate; listener.activate()
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
        if helperCheck { client.setCodeSigningRequirement(policy.helperRequirement) }
        client.remoteObjectInterface = NSXPCInterface(with: PrivilegeRPC.self)
        client.invalidationHandler = { state.error() }; client.interruptionHandler = { state.error() }
        client.activate(); defer { client.invalidate(); delegate.close(); listener.invalidate() }
        let proxy = try #require(client.remoteObjectProxyWithErrorHandler { _ in state.error() } as? PrivilegeRPC)
        let data = try JSONSerialization.data(withJSONObject: ["version":1,"id":UUID().uuidString,"operation":"begin"], options:[.sortedKeys])
        proxy.request(data) { reply in
            if String(decoding: reply, as: UTF8.self).contains("error") { state.error() }
            else { state.response() }
            // Read actual outgoing-connection credentials only after a received reply.
            // This rootless peer is deliberately rejected by the prepared root guard.
            if !helperCheck {
                print("Rootless outgoing NSXPC reply peer pid=\(client.processIdentifier) euid=\(client.effectiveUserIdentifier)")
                #expect(throws: PrivilegeError.denied) { try PrivilegeClient.validateReplyPeer(client) }
            }
        }
        for _ in 0..<100 {
            let result = state.snapshot
            if result.replied || result.rejected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return state.snapshot
    }
    @Test func listenerRejectsBeforeDelegateEnrollmentAndPowerWithWorkingControl() async throws {
        // Deliberately unguarded rootless control exercises OS credential capture and mock
        // consent. It is not a production authentication fallback or a trusted-signer test.
        let control = try await exchange()
        try #require(control.delegates == 1 && control.enrollment == 1 && control.setters >= 1 && control.replied)
        let negative = try await exchange(listenerCheck: true, messageCheck: true)
        #expect(negative.rejected && !negative.replied)
        #expect(negative.delegates == 0 && negative.enrollment == 0 && negative.setters == 0)
    }
    @Test func clientRejectsWrongHelperSignatureBeforeConsumingReply() async throws {
        let result = try await exchange(helperCheck: true)
        #expect(result.rejected && !result.replied)
        // A client-side requirement controls received replies, not whether an untrusted
        // service can receive a sent message. Send no privileged/session secrets before
        // a separately verified handshake in a future transport.
    }
}
