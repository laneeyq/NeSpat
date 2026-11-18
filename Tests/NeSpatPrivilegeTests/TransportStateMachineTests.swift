import Foundation
import Testing
@testable import NeSpatPrivilegeCore

// MOCK_ONLY peer acceptance. This does not simulate a real signature or root process.
final class MockHelperChannel: HelperChannel, @unchecked Sendable {
    typealias Callback = @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void
    private let mutex=NSLock()
    private var hellos: [(Data,Callback)] = [], operations: [(Data,Callback)] = []
    private var failure: (@Sendable () -> Void)?
    private var invalidations=0
    var helloData: [Data] { mutex.lock(); defer { mutex.unlock() }; return hellos.map(\.0) }
    var operationData: [Data] { mutex.lock(); defer { mutex.unlock() }; return operations.map(\.0) }
    var closed: Bool { mutex.lock(); defer { mutex.unlock() }; return invalidations > 0 }
    func onFailure(_ callback: @escaping @Sendable () -> Void) { mutex.lock(); failure=callback; mutex.unlock() }
    func activate() {}
    func handshake(_ bytes: Data, reply: @escaping Callback) { mutex.lock(); hellos.append((bytes,reply)); mutex.unlock() }
    func request(_ bytes: Data, reply: @escaping Callback) { mutex.lock(); operations.append((bytes,reply)); mutex.unlock() }
    func invalidate() { mutex.lock(); invalidations += 1; mutex.unlock() }
    func interrupt() { mutex.lock(); let callback=failure; mutex.unlock(); callback?() }
    static let root = HelperPeerCredentials(pid:1234,euid:0)
    func answerHello(_ index: Int = 0, peer: HelperPeerCredentials = root, bytes: Data? = nil) throws {
        mutex.lock(); let item=hellos[index]; mutex.unlock()
        let payload=try bytes ?? HelperWire.hello(HelperWire.decodeHello(item.0),response:true)
        item.1(.success(HelperChannelReply(bytes:payload,peer:peer)))
    }
    func rejectHello() { mutex.lock(); let callback=hellos[0].1; mutex.unlock(); callback(.failure(.connection)) }
    func answerOperation(_ index: Int = 0, peer: HelperPeerCredentials = root, bytes: Data? = nil) throws {
        mutex.lock(); let item=operations[index]; mutex.unlock()
        let f=try HelperWire.object(item.0), text=try #require(f["epoch"] as? String)
        let epoch=try #require(UUID(uuidString:text))
        let (request,_)=try HelperWire.decodeOperation(item.0,epoch:epoch)
        let payload=try bytes ?? HelperWire.operationReply(Data(#"{"state":"enabled"}"#.utf8),id:request.id,epoch:epoch)
        item.1(.success(HelperChannelReply(bytes:payload,peer:peer)))
    }
}
func waitForTransport(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    Issue.record("Timed out waiting for test event"); throw PrivilegeTransportError.timeout
}
func expectTransportFailure<T: Sendable>(_ task: Task<T,any Error>, _ expected: PrivilegeTransportError? = nil) async {
    do { _=try await task.value; Issue.record("Operation unexpectedly succeeded") }
    catch { if let expected { #expect(error as? PrivilegeTransportError == expected) } }
}
func waitForClosed(_ t: PrivilegeTransport) async throws {
    for _ in 0..<200 { if await t.state == .closed { return }; try await Task.sleep(for:.milliseconds(2)) }
    Issue.record("Transport retained verification after failure"); throw PrivilegeTransportError.timeout
}
func mockVerifiedTransport() async throws -> (PrivilegeTransport,MockHelperChannel) {
    let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
    let task=Task { try await t.handshake() }
    try await waitForTransport { c.helloData.count == 1 }; try c.answerHello(); try await task.value
    return (t,c)
}

@Suite struct TransportStateMachineTests {
    @Test func mockOnlyStateFlowAndFirstMessageHasNoAuthority() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        #expect(await t.state == .unverified)
        let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        let f=try HelperWire.object(try #require(c.helloData.first))
        #expect(Set(f.keys) == ["version","kind","epoch","nonce"] && f["kind"] as? String == "hello")
        #expect(c.operationData.isEmpty); #expect(await t.state == .unverified)
        try c.answerHello(); try await task.value; #expect(await t.state == .peerVerified)
        let op=Task { try await t.request(Request(operation:.status)) }
        try await waitForTransport { c.operationData.count == 1 }; try c.answerOperation()
        #expect(try await op.value.state == .enabled); #expect(await t.state == .active)
        await t.close(); #expect(await t.state == .closed && c.closed)
    }
    @Test(arguments: [Operation.status,.begin,.recover,.changeDeadline,.end,.revoke])
    func everyOperationBeforeHandshakeClosesWithoutSending(_ op: NeSpatPrivilegeCore.Operation) async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c)
        await expectTransportFailure(Task { try await t.request(Request(operation:op)) },.unverified)
        #expect(c.helloData.isEmpty && c.operationData.isEmpty && c.closed)
        #expect(await t.state == .closed)
    }
    @Test(arguments: [HelperPeerCredentials(pid:1,euid:501),.init(pid:0,euid:0),.init(pid:-1,euid:0)])
    func OSFactsMustProveRootAndPositivePID(_ peer: HelperPeerCredentials) async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        try c.answerHello(peer:peer); await expectTransportFailure(task,.authentication)
        #expect(await t.state == .closed && c.operationData.isEmpty)
    }
    @Test func powerDuringPendingHandshakeCannotReachWire() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let handshake=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        await expectTransportFailure(Task { try await t.request(Request(operation:.begin)) },.unverified)
        await expectTransportFailure(handshake,.unverified); try c.answerHello()
        #expect(await t.state == .closed && c.operationData.isEmpty)
    }
    @Test func noAnswerTimesOutAndLateAnswerCannotReopen() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:0.03)
        let task=Task { try await t.handshake() }; await expectTransportFailure(task,.timeout)
        #expect(c.helloData.count == 1); try c.answerHello()
        #expect(await t.state == .closed && c.operationData.isEmpty)
    }
    @Test(arguments: Array(0..<7)) func malformedOrForgedHelloCloses(_ variant: Int) async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        let h=try HelperWire.decodeHello(c.helloData[0]); var f=try HelperWire.object(HelperWire.hello(h,response:true))
        var bytes: Data
        switch variant {
        case 0: bytes=Data("{".utf8)
        case 1: f["uid"]=0; bytes=try JSONSerialization.data(withJSONObject:f,options:[.sortedKeys])
        case 2: f["epoch"]=UUID().uuidString; bytes=try JSONSerialization.data(withJSONObject:f,options:[.sortedKeys])
        case 3: f["nonce"]=UUID().uuidString; bytes=try JSONSerialization.data(withJSONObject:f,options:[.sortedKeys])
        case 4: f["version"]=true; bytes=try JSONSerialization.data(withJSONObject:f,options:[.sortedKeys])
        case 5: bytes=Data(repeating:65,count:513)
        default: bytes=Data(#"{"epoch":"x","epoch":"x","kind":"helloReply","nonce":"x","version":1}"#.utf8)
        }
        try c.answerHello(bytes:bytes); await expectTransportFailure(task)
        #expect(await t.state == .closed && c.operationData.isEmpty)
    }
    @Test func JSONCannotDeclareRootOrReplaceOSFacts() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        try c.answerHello(peer:.init(pid:123,euid:501),bytes:Data(#"{"uid":0,"pid":1,"verified":true}"#.utf8))
        await expectTransportFailure(task,.authentication); #expect(c.operationData.isEmpty)
    }
    @Test func duplicateHelloReplyAndRepeatedHandshakeClose() async throws {
        let (t,c)=try await mockVerifiedTransport(); try c.answerHello(); try await waitForClosed(t)
        await expectTransportFailure(Task { try await t.handshake() },.replay)
        #expect(c.helloData.count == 1 && c.operationData.isEmpty)
        let (other,d)=try await mockVerifiedTransport()
        await expectTransportFailure(Task { try await other.handshake() },.replay)
        #expect(await other.state == .closed && d.helloData.count == 1)
    }
    @Test func interruptionLosesStateAndPendingReplyImmediately() async throws {
        let (t,c)=try await mockVerifiedTransport()
        let op=Task { try await t.request(Request(operation:.status)) }; try await waitForTransport { c.operationData.count == 1 }
        c.interrupt(); await expectTransportFailure(op,.connection); try c.answerOperation()
        await expectTransportFailure(Task { try await t.request(Request(operation:.begin)) },.unverified)
        #expect(await t.state == .closed && c.operationData.count == 1)
    }
    @Test func callbackAfterCloseCannotVerifyOrResumeTwice() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        await t.close(); await expectTransportFailure(task,.closed)
        try c.answerHello(); try c.answerHello(); #expect(await t.state == .closed)
    }
    @Test func newEpochRejectsReplayedHelloAndOldCallbackStaysOnOldInstance() async throws {
        let (old,c)=try await mockVerifiedTransport(); let oldHello=try HelperWire.decodeHello(c.helloData[0]); await old.close()
        let d=MockHelperChannel(), next=PrivilegeTransport(channel:d,timeout:1)
        let task=Task { try await next.handshake() }; try await waitForTransport { d.helloData.count == 1 }
        #expect(try HelperWire.decodeHello(d.helloData[0]).epoch != oldHello.epoch)
        try c.answerHello(); #expect(await next.state == .unverified)
        try d.answerHello(bytes:HelperWire.hello(oldHello,response:true)); await expectTransportFailure(task,.replay)
        #expect(await old.state == .closed); #expect(await next.state == .closed)
    }
    @Test(arguments: [false,true]) func operationalReplyMustMatchOSPeerAndWireCorrelation(_ differentPeer: Bool) async throws {
        let (t,c)=try await mockVerifiedTransport()
        let op=Task { try await t.request(Request(operation:.status)) }; try await waitForTransport { c.operationData.count == 1 }
        if differentPeer { try c.answerOperation(peer:.init(pid:5678,euid:0)) }
        else {
            let h=try HelperWire.decodeHello(c.helloData[0])
            try c.answerOperation(bytes:HelperWire.operationReply(Data(#"{"state":"enabled"}"#.utf8),id:UUID(),epoch:h.epoch))
        }
        await expectTransportFailure(op); #expect(await t.state == .closed)
    }
    @Test func replayedOperationalPayloadCannotSatisfyNextRequest() async throws {
        let (t,c)=try await mockVerifiedTransport(); let first=Request(operation:.status)
        let a=Task { try await t.request(first) }; try await waitForTransport { c.operationData.count == 1 }
        let h=try HelperWire.decodeHello(c.helloData[0])
        let stale=try HelperWire.operationReply(Data(#"{"state":"enabled"}"#.utf8),id:first.id,epoch:h.epoch)
        try c.answerOperation(bytes:stale); _=try await a.value
        let b=Task { try await t.request(Request(operation:.status)) }; try await waitForTransport { c.operationData.count == 2 }
        try c.answerOperation(1,bytes:stale); await expectTransportFailure(b,.malformed)
        #expect(await t.state == .closed)
    }
    @Test func lateDuplicateCallbackCannotSatisfyAnotherRequest() async throws {
        let (t,c)=try await mockVerifiedTransport()
        let a=Task { try await t.request(Request(operation:.status)) }; try await waitForTransport { c.operationData.count == 1 }
        try c.answerOperation(); _=try await a.value
        let b=Task { try await t.request(Request(operation:.status)) }; try await waitForTransport { c.operationData.count == 2 }
        try c.answerOperation(); await expectTransportFailure(b,.replay)
        #expect(await t.state == .closed)
    }
    @Test func repeatedRequestUUIDIsRejectedBeforeWire() async throws {
        let (t,c)=try await mockVerifiedTransport(); let request=Request(operation:.status)
        let a=Task { try await t.request(request) }; try await waitForTransport { c.operationData.count == 1 }
        try c.answerOperation(); _=try await a.value
        await expectTransportFailure(Task { try await t.request(request) },.replay)
        #expect(c.operationData.count == 1 && c.closed)
    }
    @Test func cancellationAndConnectionErrorsDoNotReenroll() async throws {
        for cancel in [false,true] {
            let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
            let task=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
            if cancel { task.cancel() } else { c.rejectHello() }
            await expectTransportFailure(task,cancel ? .canceled : .connection)
            try c.answerHello(); #expect(await t.state == .closed && c.helloData.count == 1 && c.operationData.isEmpty)
        }
    }
    @Test func concurrentHandshakeAndReconnectNeverShareVerification() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:1)
        let first=Task { try await t.handshake() }; try await waitForTransport { c.helloData.count == 1 }
        let second=Task { try await t.handshake() }; await expectTransportFailure(second,.replay)
        await expectTransportFailure(first,.replay)
        let (fresh,d)=try await mockVerifiedTransport(); try c.answerHello()
        #expect(await t.state == .closed); #expect(await fresh.state == .peerVerified)
        #expect(c.helloData.count == 1 && d.helloData.count == 1 && d.operationData.isEmpty)
        await fresh.close()
    }
    @Test func operationalReplyFromOldEpochCannotSatisfyNewConnectionEvenWithSameRequestID() async throws {
        let request=Request(operation:.status), (old,c)=try await mockVerifiedTransport()
        let first=Task {try await old.request(request)}; try await waitForTransport {c.operationData.count == 1}
        let h=try HelperWire.decodeHello(c.helloData[0])
        let stale=try HelperWire.operationReply(Data(#"{"state":"enabled"}"#.utf8),id:request.id,epoch:h.epoch)
        try c.answerOperation(bytes:stale); _=try await first.value; await old.close()
        let (next,d)=try await mockVerifiedTransport()
        let task=Task {try await next.request(request)}; try await waitForTransport {d.operationData.count == 1}
        try d.answerOperation(bytes:stale); await expectTransportFailure(task,.malformed)
        #expect(await next.state == .closed)
    }
    @Test func operationTimeoutDoesNotRetryAndCannotAcceptLateReply() async throws {
        let c=MockHelperChannel(), t=PrivilegeTransport(channel:c,timeout:0.25)
        let hello=Task {try await t.handshake()}; try await waitForTransport {c.helloData.count == 1}
        try c.answerHello(); try await hello.value
        let op=Task {try await t.request(Request(operation:.status))}
        await expectTransportFailure(op,.timeout); try c.answerOperation()
        #expect(c.operationData.count == 1); #expect(await t.state == .closed)
    }
    @Test(arguments:Array(0..<4)) func malformedWorkReplyDoesNotReachCaller(_ variant: Int) async throws {
        let (t,c)=try await mockVerifiedTransport(), request=Request(operation:.status)
        let task=Task {try await t.request(request)}; try await waitForTransport {c.operationData.count == 1}
        let h=try HelperWire.decodeHello(c.helloData[0])
        let payload: String
        switch variant {
        case 0: payload=#"{"state":"enabled","uid":0}"#
        case 1: payload=#"{"state":"invalid"}"#
        case 2: payload=#"{"state":"enabled","deadline":true,"session":"123"}"#
        default: payload=#"{"error":"consent-canceled"}"#
        }
        try c.answerOperation(bytes:HelperWire.operationReply(Data(payload.utf8),id:request.id,epoch:h.epoch))
        await expectTransportFailure(task,.malformed); #expect(await t.state == .closed)
    }
    @Test func unknownPowerRemainsUnknownInTypedReply() async throws {
        let (t,c)=try await mockVerifiedTransport(), request=Request(operation:.status)
        let task=Task {try await t.request(request)}; try await waitForTransport {c.operationData.count == 1}
        let h=try HelperWire.decodeHello(c.helloData[0])
        try c.answerOperation(bytes:HelperWire.operationReply(Data(#"{"state":"unknown"}"#.utf8),id:request.id,epoch:h.epoch))
        #expect(try await task.value.state == .unknown); await t.close()
    }
    @Test func concurrentWorkAndInvalidRequestCloseInsteadOfBypassingGate() async throws {
        let (t,c)=try await mockVerifiedTransport()
        let first=Task {try await t.request(Request(operation:.status))}; try await waitForTransport {c.operationData.count == 1}
        await expectTransportFailure(Task {try await t.request(Request(operation:.status))},.busy)
        await expectTransportFailure(first,.busy); #expect(c.operationData.count == 1)
        let (next,d)=try await mockVerifiedTransport()
        await expectTransportFailure(Task {try await next.request(Request(operation:.changeDeadline))},.malformed)
        #expect(d.operationData.isEmpty); #expect(await next.state == .closed)
    }
}
