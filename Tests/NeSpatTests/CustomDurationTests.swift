import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor struct CustomDurationTests {
    @Test(arguments: [1,15,35,90,165,480,481,500,1440,10000])
    func customRoundTrip(_ minutes: Int) throws {
        let f = Fixture(); let model = f.model()
        model.applyCustomMinutes(String(minutes)); model.toggle(true)
        let deadline = f.session.until
        #expect(f.session.durationSeconds == Double(minutes) * 60)
        #expect(deadline == f.now.addingTimeInterval(Double(minutes) * 60))
        f.session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(f.session))
        f.now = f.now.addingTimeInterval(10)
        let restarted = f.model()
        #expect(restarted.customMinutes == minutes || restarted.duration.seconds == Double(minutes)*60)
        #expect(restarted.countdownDeadline == deadline)
        _ = restarted.statusText(at: f.now.addingTimeInterval(5))
        #expect(f.session.until == deadline)
        restarted.applyCustomMinutes("481")
        #expect(f.session.until == f.now.addingTimeInterval(481*60))
    }
    @Test(arguments: ["", "0", "-1", "1.5", "hi", " 1", "+1", String(Int.max), "153722867280912931", String(repeating:"9",count:10000)])
    func invalidInput(_ text: String) {
        let f = Fixture(); f.active(); let model = f.model(); let before = f.session
        model.applyCustomMinutes(text)
        #expect(model.durationError != nil)
        #expect(f.session == before)
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
    }
    @Test func numericEdgesAndFormatting() throws {
        #expect(throws: (any Error).self) { try CustomDuration.deadline(seconds: 60, now: Date(timeIntervalSinceReferenceDate: .infinity)) }
        #expect(throws: (any Error).self) { try CustomDuration.deadline(seconds: CustomDuration.exactSeconds, now: Date()) }
        #expect(throws: (any Error).self) { try CustomDuration.seconds(String(Int.max/60+1)) }
        #expect(Fmt.duration(.infinity) == "—")
        #expect(Fmt.duration(Double.greatestFiniteMagnitude) == "—")
        #expect(!Fmt.duration(CustomDuration.exactSeconds).contains("—"))
        let seconds = try CustomDuration.seconds("100000000")
        #expect(try CustomDuration.deadline(seconds: seconds, now: Date()).timeIntervalSinceReferenceDate.isFinite)
    }
    @Test func storageAndForeignOwnership() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456; f.otherOwnerAlive = true
        let observer = f.model(); let original = f.session
        observer.applyCustomMinutes("35")
        #expect(f.session == original); #expect(f.calls.isEmpty)
        let own = Fixture(); own.active(); let model = own.model(); let saved = own.session
        own.failSaveAt = 1; model.applyCustomMinutes("35")
        #expect(own.session == saved); #expect(model.operationError != nil)
        own.session.durationSeconds = .infinity
        model.tick(); #expect(!model.prepareToQuit()); #expect(own.calls.isEmpty)
    }
    @Test func corruptSavedValuesRejectAndLegacyStillLoads() throws {
        for value in [-1.0, 0, 1.5, Double.infinity, Double.greatestFiniteMagnitude] {
            var record = Session(); record.durationSeconds = value
            #expect(throws: (any Error).self) { try CustomDuration.validate(record) }
        }
        let legacy = try JSONDecoder().decode(Session.self, from: Data(#"{"owned":false,"pid":0}"#.utf8))
        try CustomDuration.validate(legacy)
    }
}
