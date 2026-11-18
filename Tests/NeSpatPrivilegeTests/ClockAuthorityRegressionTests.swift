import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct ClockAuthorityRegressionTests {
    @Test(arguments:[Double.nan,-Double.infinity,Double(9)])
    func invalidOrRegressedClockCannotRetainFullAuthority(_ time:Double) throws {
        let f=PrivilegeFixture();let id=try f.begin();let writes=f.journal.writes
        f.uptime=time
        #expect(throws:PrivilegeError.denied) {
            try f.engine.handle(Request(operation:.changeDeadline,session:id,minutes:2),from:f.peer)
        }
        #expect(f.journal.writes == writes && f.changes == [true])
        _=try f.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.state == .enabled && f.changes == [true,false])
    }
}
