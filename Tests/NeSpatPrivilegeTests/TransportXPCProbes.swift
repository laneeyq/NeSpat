import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

private final class TransportProbeState: @unchecked Sendable {
    private let mutex=NSLock()
    private var hellos: [Data] = [], operations=0, enrollments=0, setters=0
    func hello(_ data: Data) { mutex.lock(); hellos.append(data); mutex.unlock() }
    func request() { mutex.lock(); operations += 1; mutex.unlock() }
    func enroll() { mutex.lock(); enrollments += 1; mutex.unlock() }
    func set() { mutex.lock(); setters += 1; mutex.unlock() }
    var snapshot: (hellos:[Data],operations:Int,enrollments:Int,setters:Int) {
        mutex.lock(); defer { mutex.unlock() }; return (hellos,operations,enrollments,setters)
    }
}
private final class ImpostorHelper: NSObject, VerifiedPrivilegeRPC {
    let state: TransportProbeState
    let drop: Bool
    init(_ state: TransportProbeState,drop: Bool) { self.state=state; self.drop=drop }
    func handshake(_ bytes: Data, reply: @escaping (Data) -> Void) {
        state.hello(bytes)
        if !drop { reply((try? HelperWire.hello(HelperWire.decodeHello(bytes),response:true)) ?? HelperWire.denied) }
    }
    func request(_ bytes: Data, reply: @escaping (Data) -> Void) { state.request(); reply(HelperWire.denied) }
}
private final class TransportProbeListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let state: TransportProbeState
    let drop: Bool
    let gate: Bool
    let boot: UUID
    private let mutex=NSLock()
    private var connections: [NSXPCConnection] = []
    init(state: TransportProbeState,drop: Bool = false,gate: Bool = false,boot: UUID) {
        self.state=state; self.drop=drop; self.gate=gate; self.boot=boot
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface=NSXPCInterface(with:VerifiedPrivilegeRPC.self)
        if gate {
            let state=state
            let engine=PrivilegeEngine(journal:MemoryAuthority(),boot:boot,now:Date.init,monotonic:{10},
                observe:{.enabled},setDisabled:{ _ in state.set() }, fullGrantPolicy: fixtureFullGrantPolicy, safetySnapshot: { fixtureSafetySnapshot })
            let endpoint=HandshakingPrivilegeEndpoint(connection:connection,policy:try! SigningPolicy(teamID:"ABCDE12345"),
                engine:engine,enrollment:{ challenge in
                    // Only an unguarded rootless CONTROL. No real signer/consent acceptance.
                    state.enroll()
                    return .fresh(FreshAuthorization(trustedConsentFor:challenge,confirmedAt:10,expires:1000))
                })
            connection.exportedObject=endpoint
            connection.invalidationHandler={endpoint.close()}
            connection.interruptionHandler={endpoint.close()}
        } else { connection.exportedObject=ImpostorHelper(state,drop:drop) }
        mutex.lock(); connections.append(connection); mutex.unlock()
        connection.activate(); return true
    }
    func close() { mutex.lock(); let all=connections; connections.removeAll(); mutex.unlock(); all.forEach {$0.invalidate()} }
}
private final class ProbeReply: @unchecked Sendable {
    private let mutex=NSLock()
    private var bytes: Data?
    private var failed=false
    func receive(_ data: Data) { mutex.lock(); bytes=data; mutex.unlock() }
    func error() { mutex.lock(); failed=true; mutex.unlock() }
    var result: (Data?,Bool) { mutex.lock(); defer {mutex.unlock()}; return(bytes,failed) }
}

@Suite struct TransportXPCProbes {
    @Test func actualUntrustedHelperSeesOnlyPublicHelloAndNoPowerRequest() async throws {
        let state=TransportProbeState(), delegate=TransportProbeListener(state:state,boot:UUID())
        let listener=NSXPCListener.anonymous(); listener.delegate=delegate; listener.activate()
        defer {delegate.close();listener.invalidate()}
        let channel=NSXPCHelperChannel(endpoint:listener.endpoint,policy:try SigningPolicy(teamID:"ABCDE12345"))
        let t=PrivilegeTransport(channel:channel,timeout:1)
        await expectTransportFailure(Task {try await t.handshake()})
        await expectTransportFailure(Task {try await t.request(Request(operation:.begin))},.unverified)
        let result=state.snapshot
        #expect(await t.state == .closed); #expect(result.operations == 0 && result.enrollments == 0 && result.setters == 0)
        #expect(result.hellos.count == 1)
        for bytes in result.hellos {
            let f=try HelperWire.object(bytes)
            #expect(Set(f.keys) == ["version","kind","epoch","nonce"] && f["kind"] as? String == "hello")
        }
        print("Actual strict client against untrusted helper: hello=\(result.hellos.count), privileged RPC=\(result.operations)")
    }
    @Test func actualMissingHandshakeReplyTimesOutWithoutFallback() async throws {
        let state=TransportProbeState(), delegate=TransportProbeListener(state:state,drop:true,boot:UUID())
        let listener=NSXPCListener.anonymous(); listener.delegate=delegate; listener.activate()
        defer {delegate.close();listener.invalidate()}
        let t=PrivilegeTransport(channel:NSXPCHelperChannel(endpoint:listener.endpoint,policy:try SigningPolicy(teamID:"ABCDE12345")),timeout:0.25)
        await expectTransportFailure(Task {try await t.handshake()},.timeout)
        #expect(await t.state == .closed && state.snapshot.operations == 0)
        #expect(state.snapshot.hellos.count == 1)
    }
    @Test(arguments:[false,true]) func actualServerRequiresHelloWithoutEnrollmentAndRejectsDuplicates(_ duplicate: Bool) async throws {
        // Raw rootless test client only, deliberately NOT the public guarded transport.
        let state=TransportProbeState(), delegate=TransportProbeListener(state:state,gate:true,boot:try #require(SystemBootIdentity.read()))
        let listener=NSXPCListener.anonymous(); listener.delegate=delegate; listener.activate()
        let client=NSXPCConnection(listenerEndpoint:listener.endpoint)
        client.remoteObjectInterface=NSXPCInterface(with:VerifiedPrivilegeRPC.self); client.activate()
        defer {client.invalidate();delegate.close();listener.invalidate()}
        let result=ProbeReply()
        let proxy=try #require(client.remoteObjectProxyWithErrorHandler {_ in result.error()} as? VerifiedPrivilegeRPC)
        let hello=HelperHello(epoch:UUID(),nonce:UUID())
        if duplicate {
            let first=ProbeReply(); proxy.handshake(try HelperWire.hello(hello)) {first.receive($0)}
            try await waitForTransport {first.result.0 != nil}
            #expect(try HelperWire.decodeHello(try #require(first.result.0),response:true) == hello)
            #expect(state.snapshot.enrollments == 0 && state.snapshot.setters == 0)
            proxy.handshake(try HelperWire.hello(hello)) {result.receive($0)}
        } else {
            proxy.request(try HelperWire.operation(Request(operation:.begin),epoch:hello.epoch)) {result.receive($0)}
        }
        try await waitForTransport {result.result.0 != nil || result.result.1}
        #expect(result.result.0 == HelperWire.denied)
        #expect(state.snapshot.enrollments == 0 && state.snapshot.setters == 0)
        let after=ProbeReply()
        proxy.request(try HelperWire.operation(Request(operation:.begin),epoch:hello.epoch)) {after.receive($0)}
        try await waitForTransport {after.result.0 != nil || after.result.1}
        #expect(after.result.0 == HelperWire.denied && state.snapshot.enrollments == 0 && state.snapshot.setters == 0)
    }
    @Test func directOuterEndpointInvocationCannotClaimAuthenticatedCaller() throws {
        let f=PrivilegeFixture(), listener=NSXPCListener.anonymous(), c=NSXPCConnection(listenerEndpoint:listener.endpoint)
        defer {c.invalidate();listener.invalidate()}
        let endpoint=HandshakingPrivilegeEndpoint(connection:c,policy:try SigningPolicy(teamID:"ABCDE12345"),engine:f.engine,
            enrollment:{_ in Issue.record("Direct caller reached enrollment");return nil})
        let hello=HelperHello(epoch:UUID(),nonce:UUID())
        endpoint.handshake(try HelperWire.hello(hello)) {#expect($0 == HelperWire.denied)}
        endpoint.request(try HelperWire.operation(Request(operation:.begin),epoch:hello.epoch)) {#expect($0 == HelperWire.denied)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
