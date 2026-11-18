import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct HeartbeatWireTests {
    @Test func heartbeatBeforeHandshakeCannotReachWire() async {
        let channel=MockHelperChannel(),transport=PrivilegeTransport(channel:channel)
        await expectTransportFailure(Task {try await transport.request(Request(operation:.heartbeat,session:UUID()))},.unverified)
        #expect(channel.helloData.isEmpty && channel.operationData.isEmpty)
    }
    @Test func heartbeatCannotSupplyServerTimeoutOrExecutable() throws {
        let id=UUID().uuidString,session=UUID().uuidString
        for key in ["timeout","heartbeatPolicy","T_max","argv","executable","uid","peer"] {
            let data=try JSONSerialization.data(withJSONObject:["version":1,"id":id,"operation":"heartbeat","session":session,key:1],options:[.sortedKeys])
            #expect(throws:PrivilegeError.malformed) {try Request.decode(data)}
        }
        let value=Request(operation:.heartbeat,session:UUID())
        #expect(try Request.decode(HelperWire.requestData(value)).operation == .heartbeat)
    }
    @Test func wrongSessionHeartbeatCannotKeepOwnerAlive() throws {
        let h=try HeartbeatFixture();_=try h.begin();h.f.uptime=19
        #expect(throws:PrivilegeError.ownership) {try h.engine.handle(Request(operation:.heartbeat,session:UUID()),from:h.f.peer)}
        h.f.uptime=20;try h.engine.tick()
        #expect(h.f.changes == [true,false])
    }
    @Test func concurrentDuplicateHeartbeatsHaveOneAcceptedRequest() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),request=Request(operation:.heartbeat,session:id)
        let lock=NSLock();nonisolated(unsafe) var successes=0;nonisolated(unsafe) var replay=0
        DispatchQueue.concurrentPerform(iterations:32) {_ in
            do {_=try h.engine.handle(request,from:h.f.peer);lock.lock();successes += 1;lock.unlock()}
            catch {#expect(error as? PrivilegeError == .replay);lock.lock();replay += 1;lock.unlock()}
        }
        #expect(successes == 1 && replay == 31 && h.f.changes == [true])
    }
}
