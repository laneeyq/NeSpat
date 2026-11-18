import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor
struct CountdownTests {
    @Test func displayedSecondsAdvanceWithoutMonitoringTick() {
        let f = Fixture(); f.active(); f.session.until = f.now.addingTimeInterval(65)
        let model = f.model(); let initial = model.statusText
        let deadline = f.session.until
        for _ in 0..<4 {
            let previous = model.statusText
            f.now = f.now.addingTimeInterval(1)
            #expect(model.statusText != previous)
        }
        #expect(model.statusText != initial)
        #expect(f.session.until == deadline)
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
    }

    @Test func hourLongCountdownStillDisplaysSeconds() {
        let f = Fixture(); f.active(); f.session.until = f.now.addingTimeInterval(3661)
        let model = f.model()
        #expect(model.statusText.contains("01 с"))
    }

    @Test func fractionalSecondsRoundUpAndExpiredTimeNeverGoesNegative() {
        let f = Fixture(); f.active(); f.session.until = f.now.addingTimeInterval(1.1)
        let model = f.model()
        #expect(model.statusText(at: f.now).contains("2 с"))
        #expect(model.statusText(at: f.now.addingTimeInterval(1)).contains("1 с"))
        #expect(model.remaining(at: f.now.addingTimeInterval(1.1)) == 0)
        #expect(model.remaining(at: f.now.addingTimeInterval(100)) == 0)
        #expect(model.statusText(at: f.now.addingTimeInterval(1.1)).contains("ещё не подтверждён"))
        #expect(model.status == .on)
        #expect(f.session.canRestore)
        #expect(f.calls.isEmpty)
    }

    @Test func presentationDoesNotPollMetricsStorageIdentityOrPower() {
        let f = Fixture(); f.active()
        var deps = f.dependencies
        var operations = 0; var samples = 0
        let read = deps.readState, load = deps.load, identity = deps.identity, lock = deps.lock
        let save = deps.save, sample = deps.sample, setSleep = deps.setSleep
        let lid = deps.lidClosed, thermal = deps.thermalSerious, alive = deps.ownerAlive
        let display = deps.sleepDisplay
        deps.readState = { operations += 1; return read() }
        deps.load = { operations += 1; return try load() }
        deps.save = { operations += 1; try save($0) }
        deps.identity = { operations += 1; return identity() }
        deps.lock = { operations += 1; return try lock() }
        deps.sample = { samples += 1; return sample() }
        deps.setSleep = { operations += 1; return setSleep($0, $1) }
        deps.lidClosed = { operations += 1; return lid() }
        deps.thermalSerious = { operations += 1; return thermal() }
        deps.ownerAlive = { operations += 1; return alive($0) }
        deps.sleepDisplay = { operations += 1; return display() }
        let model = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        let before = operations, sampleCount = samples
        for second in 0..<120 {
            _ = model.statusText(at: f.now.addingTimeInterval(Double(second)))
            _ = model.remaining(at: f.now.addingTimeInterval(Double(second)))
        }
        #expect(operations == before)
        #expect(samples == sampleCount)
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
        f.now = f.now.addingTimeInterval(5); model.tick()
        #expect(samples == sampleCount + 1)
        #expect(operations > before)
    }

    @Test func reopeningPresentationAndRestartingKeepTheSavedDeadline() {
        let f = Fixture(); f.active(); f.session.until = f.now.addingTimeInterval(65)
        let original = f.session; let first = f.model()
        // A suspended/closed panel resumes at the current date; no missed ticks are accumulated.
        #expect(first.remaining(at: f.now.addingTimeInterval(30)) == 35)
        #expect(first.remaining(at: f.now.addingTimeInterval(2)) == 63)
        f.now = f.now.addingTimeInterval(42)
        let restarted = f.model()
        #expect(restarted.countdownDeadline == original.until)
        #expect(restarted.remaining == 23)
        #expect(first.remaining == 23)
        #expect(f.session == original)
        #expect(f.saved.isEmpty)
        #expect(f.calls.isEmpty)
    }

    @Test(arguments: [SleepState.disabled, .unknown])
    func zeroDoesNotReportRestorationBeforeSystemConfirmation(_ state: SleepState) {
        let f = Fixture(); f.active(); f.session.until = f.now.addingTimeInterval(1)
        let model = f.model(); let deadline = f.session.until
        f.now = f.now.addingTimeInterval(2)
        #expect(model.statusText.contains("ещё не подтверждён"))
        #expect(f.calls.isEmpty) // Drawing cannot execute even an overdue safety action.
        f.outcome = .canceled; f.state = state; model.tick()
        #expect(model.status != .off)
        #expect(!model.statusText.contains("Выключено · обычный сон"))
        #expect(f.session.canRestore)
        #expect(f.session.until == deadline)
        if state == .unknown { #expect(f.calls.isEmpty) }
        else { #expect(f.calls.count == 1) }
        f.state = .enabled; model.tick()
        #expect(model.status == .off)
        #expect(model.countdownDeadline == nil)
        #expect(model.statusText == "Выключено · обычный сон")
    }

    @Test func unownedAndLostJournalNeverShowAnOwnedCountdown() {
        let f = Fixture(); f.active(); let model = f.model()
        f.session = Session(); model.tick()
        #expect(model.countdownDeadline == nil)
        #expect(model.remaining(at: f.now) == nil)
        #expect(!model.statusText.contains("осталось"))
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        let other = Fixture(); other.active(); other.session.owner?.pid = 456
        other.otherOwnerAlive = true
        let observer = other.model()
        #expect(observer.countdownDeadline == nil)
        #expect(observer.prepareToQuit())
        #expect(other.calls.isEmpty)
    }

    @Test func unlimitedSessionDoesNotInventADeadline() {
        let f = Fixture(); f.active(); f.session.until = nil
        let model = f.model()
        #expect(model.countdownDeadline == nil)
        #expect(model.remaining == nil)
        #expect(model.statusText == "Включено · подтверждено системой")
    }
}
