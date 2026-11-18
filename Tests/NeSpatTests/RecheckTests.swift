import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor
struct RecheckTests {
    @Test func foreignFlagHasWarningInMenu() {
        let f = Fixture(); f.state = .disabled
        let model = f.model()
        #expect(model.status == .foreign)
        #expect(model.menuTitle.hasPrefix("⚠"))
    }

    @Test func recoveredFiniteSessionDoesNotDisplayUnlimited() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456
        let model = f.model()
        #expect(model.status == .on)
        #expect(model.remaining != nil)
        #expect(model.duration != .none)
    }

    @Test func externalRestoreClearsStalePowerError() {
        let f = Fixture(); f.active()
        let model = f.model()
        f.outcome = .canceled; model.toggle(false)
        #expect(model.operationError != nil)
        f.state = .enabled; model.tick()
        #expect(model.status == .off)
        #expect(!f.session.owned)
        #expect(model.operationError == nil)
        #expect(model.lastReason == "Обычный сон подтверждён системой")
    }
}

@Suite @MainActor
struct TerminationAndPresentationTests {
    @Test(arguments: [SleepState.enabled, .disabled, .unknown])
    func absentModelChecksObservedState(_ state: SleepState) {
        var reads = 0
        let decision = AppDelegate.terminationDecision(model: nil, readState: { reads += 1; return state })
        #expect(reads == 1)
        if state == .enabled { #expect(decision == .allow) }
        else {
            guard case .cancel(let message) = decision else { Issue.record("Fail-open termination"); return }
            #expect(!message.isEmpty)
        }
    }

    @Test func existingModelUsesItsRestorationPath() {
        let f = Fixture(); f.active(); let model = f.model()
        f.outcome = .canceled
        let denied = AppDelegate.terminationDecision(model: model, readState: { Issue.record("Unexpected fallback"); return .enabled })
        guard case .cancel = denied else { Issue.record("Failed restoration permitted termination"); return }
        #expect(f.session.canRestore)
        f.outcome = .confirmed
        #expect(AppDelegate.terminationDecision(model: model) == .allow)
        #expect(!f.session.owned)
    }

    @Test func allPowerStatesDriveConsistentMenuAndControls() {
        for state in [SleepState.enabled, .disabled, .unknown] {
            let f = Fixture(); f.state = state; let model = f.model()
            if state == .enabled {
                #expect(model.menuTitle == "— — —")
                #expect(model.statusText.contains("обычный сон"))
                #expect(!model.modeIsOn)
                #expect(model.canToggleMode)
                #expect(!model.showsRestoreAction)
            } else {
                #expect(model.menuTitle.hasPrefix("⚠"))
                #expect(!model.statusText.contains("обычный сон"))
                #expect(!model.modeIsOn)
                #expect(!model.canToggleMode)
                #expect(model.showsRestoreAction)
            }
        }
        let f = Fixture(); f.active(); let model = f.model()
        #expect(model.menuTitle.hasPrefix("☕"))
        #expect(model.modeIsOn)
        #expect(model.canToggleMode)
        #expect(model.statusText.contains("осталось"))
        f.outcome = .notConfirmed; model.toggle(false)
        #expect(model.menuTitle.hasPrefix("⚠"))
        #expect(model.modeIsOn) // Actual owned flag remains enabled.
        #expect(model.showsRestoreAction)
    }

    @Test func unconfirmedEnableIsVisiblyDifferentFromOrdinarySleep() {
        let f = Fixture(); var deps = f.dependencies
        deps.setSleep = { _, _ in f.state = .disabled; return .notConfirmed }
        let model = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        model.toggle(true)
        #expect(model.status == .foreign)
        #expect(model.menuTitle.hasPrefix("⚠"))
        #expect(!model.canToggleMode)
        #expect(model.showsRestoreAction)
    }

    @Test func restoredPresetKeepsOriginalLimitAndElapsedDeadline() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456
        f.session.durationSeconds = 10800
        f.session.until = f.now.addingTimeInterval(4000)
        let deadline = f.session.until
        let model = f.model()
        #expect(model.duration == .h3)
        #expect(model.remaining == 4000)
        #expect(f.session.until == deadline)
        f.now = f.now.addingTimeInterval(120); model.tick()
        #expect(model.duration == .h3)
        #expect(model.remaining == 3880)
        #expect(f.session.until == deadline)
        model.setDuration(.h8)
        #expect(f.session.durationSeconds == 28800)
        #expect(f.session.until == f.now.addingTimeInterval(28800))
        #expect(model.duration == .h8)
    }

    @Test func legacyDeadlineIsRepresentedWithoutInventingPresetOrResettingTimer() {
        let f = Fixture(); f.active(); let deadline = f.session.until
        let model = f.model()
        #expect(model.duration == .saved)
        #expect(model.durations.contains(.saved))
        model.setDuration(.saved)
        #expect(f.session.until == deadline)
        #expect(f.saved.isEmpty)
        f.state = .enabled; model.tick()
        #expect(model.duration == .none)
        #expect(!model.durations.contains(.saved))
    }

    @Test func persistedTestLimitRemainsVisibleWithoutTestFlag() {
        let f = Fixture(); f.active(); f.session.durationSeconds = 120
        f.session.until = f.now.addingTimeInterval(60)
        let model = AppModel(testTimer: false, dependencies: f.dependencies, startTimer: false)
        #expect(model.duration == .test)
        #expect(model.durations.contains(.test))
        f.state = .enabled; model.tick()
        #expect(model.duration == .none)
        #expect(!model.durations.contains(.test))
    }

    @Test func unlimitedAndUnknownPresetFollowActualDeadline() {
        let f = Fixture(); f.active(); f.session.until = nil; f.session.durationSeconds = nil
        let model = f.model()
        #expect(model.duration == .none)
        #expect(model.remaining == nil)
        f.session.until = f.now.addingTimeInterval(600); f.session.durationSeconds = 999
        model.tick()
        #expect(model.duration == .saved)
        #expect(model.remaining == 600)
    }

    @Test func newSessionPersistsChosenLimit() {
        let f = Fixture(); let model = f.model()
        model.setDuration(.h3); model.toggle(true)
        #expect(f.session.durationSeconds == 10800)
        #expect(f.saved.allSatisfy { $0.durationSeconds == 10800 })
        model.toggle(false)
        #expect(f.session.durationSeconds == nil)
    }

    @Test func externalRestoreDoesNotClearUnrelatedDisplayError() {
        let f = Fixture(); let model = f.model()
        f.lid = true; f.displayResult = .init(code: 1, out: "", err: "mock display failure")
        model.toggle(true)
        let displayError = model.operationError
        #expect(displayError?.contains("экран") == true)
        f.state = .enabled; model.tick()
        #expect(model.status == .off)
        #expect(model.operationError == displayError)
        #expect(model.menuTitle.hasPrefix("⚠"))
    }

    @Test func blockedObservationCannotKeepShowingOrdinarySleep() {
        let f = Fixture(); let model = f.model()
        f.failLock = true; model.tick()
        #expect(model.status == .unknown)
        #expect(model.menuTitle.hasPrefix("⚠"))
        #expect(!model.canToggleMode)
        f.failLock = false; f.state = .disabled; model.tick()
        #expect(model.status == .foreign)
        #expect(model.operationError == nil)
        #expect(model.menuTitle.hasPrefix("⚠"))
    }

    @Test func originalDurationMetadataRoundTripsWithoutChangingDeadline() throws {
        let f = Fixture(); f.active(); f.session.durationSeconds = 10800
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(f.session))
        #expect(decoded.durationSeconds == 10800)
        #expect(decoded.until == f.session.until)
    }

    @Test func externalRestoreClearsForeignRecoveryWarningAndJournalAttention() {
        let f = Fixture(); f.state = .disabled; let model = f.model()
        f.outcome = .canceled; model.forceRestoreSleep()
        #expect(f.session.needsAttention == true)
        f.state = .enabled; model.tick()
        #expect(model.operationError == nil)
        #expect(f.session.needsAttention == nil)
        #expect(model.lastReason == "Обычный сон подтверждён системой")
        #expect(model.menuTitle == "— — —")
    }
}
