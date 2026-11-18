import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct ClockProgressRegressionTests {
    @Test func clockCannotRegressBehindLastValidatedRequestWithoutHeartbeatPolicy() throws {
        let f=PrivilegeFixture();let id=try f.begin()
        f.uptime=20;_=try f.engine.handle(Request(operation:.status),from:f.peer)
        f.uptime=19;let writes=f.journal.writes
        #expect(throws:PrivilegeError.denied) {try f.engine.handle(Request(operation:.changeDeadline,session:id,minutes:1),from:f.peer)}
        #expect(f.journal.writes == writes)
        _=try f.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.state == .enabled)
    }
    @Test func clockCannotRegressBehindLastAutonomousCheck() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f
        f.uptime=15;try h.engine.tick();f.uptime=14
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        #expect(f.changes == [true])
        _=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.changes == [true,false])
    }
}
