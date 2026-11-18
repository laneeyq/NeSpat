import Foundation
import Testing
@testable import NeSpatPrivilegeCore

private final class ObservationRaceFixture: @unchecked Sendable {
    let f=PrivilegeFixture()
    var onObserve:(()->Void)?
    lazy var engine=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{self.f.wall},monotonic:{self.f.uptime},
        observe:{self.onObserve?();return self.f.state},setDisabled:{self.f.changes.append($0);self.f.state = $0 ? .disabled : .enabled},
        fullGrantPolicy:fixtureFullGrantPolicy,safetySnapshot:{fixtureSafetySnapshot})
    func admit() throws {
        let c=try engine.enrollmentChallenge(for:f.peer)
        try engine.admit(f.peer,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:10,expires:100)))
    }
    func begin() throws ->UUID {try admit();return try #require(engine.handle(Request(operation:.begin),from:f.peer).session)}
}
@Suite struct LeaseBoundaryRaceTests {
    @Test func deadlineMutationCannotCrossGrantExpiryDuringObservation() throws {
        let h=ObservationRaceFixture(),id=try h.begin(),f=h.f,writes=f.journal.writes
        h.onObserve={f.uptime=100}
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.changeDeadline,session:id,minutes:1),from:f.peer)}
        #expect(f.journal.writes == writes)
        h.onObserve=nil;_=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.changes == [true,false])
    }
    @Test func beginRechecksJournalAfterFinalPowerObservation() throws {
        let h=ObservationRaceFixture(),f=h.f;try h.admit()
        h.onObserve={if f.journal.record?.phase == .pending {f.journal.record?.id=UUID()}}
        #expect(throws:PrivilegeError.ownership) {try h.engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.record != nil)
    }
    @Test func finalNoObservationCannotEraseAReplacementJournal() throws {
        let h=ObservationRaceFixture(),id=try h.begin(),f=h.f;var observations=0
        h.onObserve={observations += 1;if observations == 3 {f.journal.record?.id=UUID()}}
        #expect(throws:PrivilegeError.ownership) {try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)}
        #expect(f.journal.record != nil && f.journal.record?.id != id && f.changes == [true,false])
    }
}
