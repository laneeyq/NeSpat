import Foundation
import Testing
@testable import NeSpatPrivilegeCore

// Rootless Foundation integration probe; NOT the blocked production daemon listener.
private final class ProbeState: @unchecked Sendable {
    let mutex = NSLock()
    private var rejected = false
    private var invoked = false
    private var configured = false
    private var details = ""
    func error(_ error: Error? = nil) {
        mutex.lock(); rejected = true
        if let error { details = String(describing: error) }
        mutex.unlock()
    }
    func accepted() { mutex.lock(); configured = true; mutex.unlock() }
    var evidence: (Bool, String) { mutex.lock(); defer { mutex.unlock() }; return (configured, details) }
    func called() { mutex.lock(); invoked = true; mutex.unlock() }
    var result: (Bool, Bool) { mutex.lock(); defer { mutex.unlock() }; return (rejected, invoked) }
}
private final class ProbeObject: NSObject, PrivilegeRPC {
    let state: ProbeState
    init(_ state: ProbeState) { self.state = state }
    func request(_ bytes: Data, reply: @escaping (Data) -> Void) { state.called(); reply(bytes) }
}
private final class ProbeListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let state: ProbeState
    let requirement: String?
    private let mutex = NSLock()
    private var connections: [NSXPCConnection] = []
    init(state: ProbeState, requirement: String?) { self.state = state; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        state.accepted()
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        connection.exportedInterface = NSXPCInterface(with: PrivilegeRPC.self)
        connection.exportedObject = ProbeObject(state)
        connection.invalidationHandler = { [state] in state.error() }
        mutex.lock(); connections.append(connection); mutex.unlock()
        connection.activate(); return true
    }
    func close() { mutex.lock(); let values = connections; connections.removeAll(); mutex.unlock(); values.forEach { $0.invalidate() } }
}

@Suite struct RootlessXPCIntegrationTests {
    private func exchange(requirement: String?) async throws -> ((Bool, Bool), (Bool, String)) {
        let state = ProbeState()
        let delegate = ProbeListener(state: state, requirement: requirement)
        let listener = NSXPCListener.anonymous(); listener.delegate = delegate; listener.activate()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegeRPC.self)
        connection.invalidationHandler = { state.error() }
        connection.interruptionHandler = { state.error() }
        connection.activate()
        defer { connection.invalidate(); delegate.close(); listener.invalidate() }
        let object = connection.remoteObjectProxyWithErrorHandler { state.error($0) } as? PrivilegeRPC
        try #require(object).request(Data("{}".utf8)) { _ in state.called() }
        for _ in 0..<100 {
            if !state.evidence.1.isEmpty || state.result.1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (state.result, state.evidence)
    }
    @Test func realXPCRejectsCurrentUntrustedClientWithWorkingControl() async throws {
        let control = try await exchange(requirement: nil)
        try #require(control.0.1 && control.1.0, "Unrestricted rootless RPC must work before interpreting rejection")
        let policy = try SigningPolicy(teamID: "ABCDE12345")
        let negative = try await exchange(requirement: policy.guiRequirement)
        print("Rootless XPC with requirement: \(negative.1.1); without requirement RPC succeeded")
        #expect(negative.1.0)
        #expect(negative.0.0 && !negative.1.1.isEmpty)
        #expect(!negative.0.1, "Untrusted peer must never reach exported method")
    }
}
