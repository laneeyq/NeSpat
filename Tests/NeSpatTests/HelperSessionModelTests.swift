import Foundation
import Testing
@testable import NeSpat
@testable import NeSpatPrivilegeCore

// MOCK_ONLY end-to-end adapter/transport/wire/endpoint/engine. No OS root peer is invented:
// credentials below exist only in this test channel; no NSXPC service or process is launched.
private final class AdapterJournal: PersistentRecoveryJournal {
    var retry: RecoveryRetry?
    func recoverySnapshot() throws -> RecoverySnapshot { RecoverySnapshot(generation: 1, retry: retry) }
    func saveRecoveryRetry(_ value: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws {
        guard record == expected, generation == 1 else { throw PrivilegeError.ownership }; retry = value
    }
    var record: PrivilegedRecord?
    var held=false
    func exclusive<T>(_ body:() throws ->T) throws ->T {
        guard !held else {throw PrivilegeError.busy};held=true;defer{held=false};return try body()
    }
    func load() throws ->PrivilegedRecord? {record}
    func save(_ record:PrivilegedRecord?) throws {self.record=record;if let record {retry?.record=record} else {retry=nil}}
}
private final class AdapterServer: @unchecked Sendable {
    let journal=AdapterJournal(),boot=UUID()
    let peer=Peer(connection:UUID(),uid:501,auditSession:123,codeIdentity:"test authority/app")
    var time:Double=10
    var state=ObservedSleep.enabled
    var changes:[Bool]=[]
    var apply=true,consent=true
    lazy var engine=PrivilegeEngine(journal:journal,boot:boot,now:{Date(timeIntervalSince1970:1800000000)},
        monotonic:{self.time},observe:{self.state},setDisabled:{self.changes.append($0);if self.apply {self.state = $0 ? .disabled : .enabled}},
        fullGrantPolicy:try! FullGrantLifetimePolicy(maximumLifetime:100),heartbeatPolicy:try! HeartbeatPolicy(timeout:10),safetySnapshot:{.init(batteryPercent:100,externalPowerConnected:true,temperatureC:40,thermalSerious:false)},retryClock:{self.time})
    lazy var endpoint=PrivilegeEndpoint(engine:engine,peer:peer,enrollment:{c in
        self.consent ? .fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:self.time,expires:100)) : nil
    })
}
private final class AdapterChannel: HelperChannel, @unchecked Sendable {
    let server:AdapterServer
    private let mutex=NSLock()
    private var hello:HelperHello?
    private var failure:(@Sendable ()->Void)?
    private var count=0
    private var delayed:[@Sendable ()->Void]=[]
    var hold=false
    var operationCount:Int {mutex.lock();defer{mutex.unlock()};return count}
    var pendingReplies:Int {mutex.lock();defer{mutex.unlock()};return delayed.count}
    init(_ server:AdapterServer) {self.server=server}
    func onFailure(_ callback:@escaping @Sendable ()->Void) {mutex.lock();failure=callback;mutex.unlock()}
    func activate() {}
    func invalidate() {mutex.lock();hello=nil;mutex.unlock()}
    func handshake(_ bytes:Data,reply:@escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>)->Void) {
        do {
            let value=try HelperWire.decodeHello(bytes);mutex.lock();hello=value;mutex.unlock()
            reply(.success(HelperChannelReply(bytes:try HelperWire.hello(value,response:true),peer:.init(pid:1234,euid:0))))
        } catch {reply(.failure(.malformed))}
    }
    func request(_ bytes:Data,reply:@escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>)->Void) {
        mutex.lock();let current=hello;count += 1;let shouldHold=hold;mutex.unlock()
        guard let current else {reply(.failure(.authentication));return}
        do {
            let (request,data)=try HelperWire.decodeOperation(bytes,epoch:current.epoch)
            server.endpoint.request(data) {response in
                let delivery:@Sendable ()->Void = {
                    do {reply(.success(HelperChannelReply(bytes:try HelperWire.operationReply(response,id:request.id,epoch:current.epoch),peer:.init(pid:1234,euid:0))))}
                    catch {reply(.failure(.malformed))}
                }
                if shouldHold {self.mutex.lock();self.delayed.append(delivery);self.mutex.unlock()} else {delivery()}
            }
        } catch {reply(.failure(.malformed))}
    }
    func release() {mutex.lock();let calls=delayed;delayed=[];mutex.unlock();calls.forEach{$0()}}
    func interrupt() {mutex.lock();let cb=failure;mutex.unlock();cb?()}
}
@Suite @MainActor struct HelperSessionModelTests {
    private func setup(consent:Bool = true) async throws ->(HelperSessionModel,AdapterServer,AdapterChannel) {
        let server=AdapterServer();server.consent=consent
        let channel=AdapterChannel(server),transport=PrivilegeTransport(channel:channel,timeout:1)
        try await transport.handshake()
        return(HelperSessionModel(transport:transport),server,channel)
    }
    @Test func normalEnableHeartbeatAndEndUseVerifiedPipeline() async throws {
        let (model,server,channel)=try await setup()
        #expect(model.status == .unknown)
        await model.enable(minutes:60)
        #expect(model.status == .on && model.deadline == Date(timeIntervalSince1970:1800003600))
        server.time=19;await model.heartbeat()
        #expect(model.status == .on && server.changes == [true])
        await model.end()
        #expect(model.status == .off && model.operationError == nil && server.changes == [true,false])
        #expect(channel.operationCount == 3 && server.journal.record == nil)
    }
    @Test func noHumanConsentNeverEnablesOrProducesFalseOff() async throws {
        let (model,server,_)=try await setup(consent:false)
        await model.enable()
        #expect(model.status == .unknown && model.operationError != nil && server.changes.isEmpty)
    }
    @Test(arguments:[ObservedSleep.disabled,.unknown]) func unconfirmedRecoveryNeverShowsOff(_ after:ObservedSleep) async throws {
        let (model,server,_)=try await setup();await model.enable()
        server.apply=false;server.state=after
        await model.end()
        #expect(model.status == .unknown && model.operationError != nil && server.journal.record != nil)
    }
    @Test func lostGUIHeartbeatRestoresIndependentlyAndReceiptCannotReenable() async throws {
        let (model,server,_)=try await setup();await model.enable()
        server.time=20;try server.engine.tick()
        #expect(server.state == .enabled && server.changes == [true,false])
        await model.heartbeat()
        #expect(model.status == .unknown) // A closed authority is not a fresh observation.
        await model.enable()
        #expect(server.changes == [true,false] && model.status != .on)
    }
    @Test(arguments:[false,true]) func missingOrChangedJournalDoesNotClaimOff(_ replacement:Bool) async throws {
        let (model,server,_)=try await setup();await model.enable()
        if replacement {server.journal.record?.id=UUID()} else {server.journal.record=nil}
        await model.heartbeat()
        #expect(model.status == .unknown && server.changes == [true])
    }
    @Test func lostResponseOrCloseCannotClaimRestorationAndOldCallbackCannotReopen() async throws {
        let (model,server,channel)=try await setup();await model.enable()
        channel.hold=true
        let operation=Task {await model.end()}
        while channel.pendingReplies == 0 {await Task.yield()}
        await model.close();await operation.value
        channel.release();await Task.yield()
        #expect(model.status == .unknown && model.operationError != nil && !model.busy)
        #expect(server.state == .enabled) // Real model restoration happened, but no trusted reply reached GUI.
    }
    @Test func concurrentUIActionsCannotSendParallelPowerRequests() async throws {
        let (model,server,channel)=try await setup();channel.hold=true
        let operation=Task {await model.enable()}
        while channel.pendingReplies == 0 {await Task.yield()}
        await model.enable();await model.refresh();await model.heartbeat()
        #expect(channel.operationCount == 1 && model.busy)
        channel.release();await operation.value
        #expect(model.status == .on && server.changes == [true])
    }
    @Test func unverifiedTransportSendsNoPowerAndNoAutomaticHandshake() async {
        let server=AdapterServer(),channel=AdapterChannel(server)
        let model=HelperSessionModel(transport:PrivilegeTransport(channel:channel))
        await model.enable()
        #expect(model.status == .unknown && server.changes.isEmpty && channel.operationCount == 0)
    }
    @Test func disconnectDoesNotTranslateToConfirmedOff() async throws {
        let (model,server,channel)=try await setup();await model.enable()
        channel.interrupt();await model.refresh()
        #expect(model.status == .unknown && server.changes == [true] && server.journal.record != nil)
    }
}

@Suite @MainActor struct AutonomousWireRecoveryTests {
    @Test func automaticPollUsesPersistentBudgetRatherThanManualRecoveryBypass() async throws {
        let server = AdapterServer(), channel = AdapterChannel(server), transport = PrivilegeTransport(channel: channel, timeout: 1)
        try await transport.handshake()
        let reply = try await transport.request(Request(operation: .begin, minutes: 720))
        let id = try #require(reply.session)
        server.time = 20; server.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try server.engine.tick() }
        let held = try await transport.request(Request(operation: .pollRecovery, session: id))
        #expect(held.state == .disabled && held.fullAuthority == false && server.changes == [true, false])
        server.time = 319
        _ = try await transport.request(Request(operation: .pollRecovery, session: id))
        #expect(server.changes == [true, false])
        server.time = 320; server.apply = true
        let done = try await transport.request(Request(operation: .pollRecovery, session: id))
        #expect(done.state == .enabled && done.session == nil && server.changes == [true, false, false])
        await transport.close()
    }
}
