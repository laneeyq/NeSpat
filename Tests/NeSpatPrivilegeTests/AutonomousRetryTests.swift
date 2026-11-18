import Foundation
import Testing
@testable import NeSpatPrivilegeCore
@Suite struct AutonomousRetryTests {
    @Test func repeatedAutonomousFailureIsBoundedButManualRecoveryRemainsAvailable() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f;f.apply=false;f.uptime=20
        #expect(throws:PrivilegeError.unconfirmed) {try h.engine.tick()}
        let record=f.journal.record
        try? h.engine.tick();try? h.engine.tick()
        #expect(f.changes == [true,false] && f.journal.record == record && f.journal.record?.id == id)
        f.wall=f.wall.addingTimeInterval(301);f.uptime += 301;try? h.engine.tick()
        #expect(f.changes == [true,false,false])
        f.apply=true;_=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.state == .enabled && f.journal.record == nil)
    }
}
