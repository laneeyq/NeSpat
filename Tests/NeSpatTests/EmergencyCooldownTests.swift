import Foundation
import Testing
@testable import NeSpat

@MainActor private final class CooldownHarness {
    enum Interrupted: Error { case afterIntentSave }
    let f = Fixture()
    var snapshots = 0
    var onSnapshot: (Int) -> Void = { _ in }
    var stopAfterIntentSave = false
    var restoreElapsed: TimeInterval = 0
    var afterRestore: () -> Void = {}
    init() { f.active(); f.sample.temperatureC = 95 }
    var dependencies: EmergencySleep.Dependencies {
        let d = f.dependencies
        return .init(lock: d.lock, load: d.load, save: { record in
            try d.save(record)
            if self.stopAfterIntentSave { throw Interrupted.afterIntentSave }
        }, identity: d.identity, readState: d.readState, snapshot: {
            self.snapshots += 1; self.onSnapshot(self.snapshots)
            return .init(sample: self.f.sample, thermalSerious: self.f.thermal)
        }, restore: {
            let outcome = d.setSleep(false, false); self.f.now = self.f.now.addingTimeInterval(self.restoreElapsed); self.afterRestore(); return outcome
        }, request: { self.f.emergencyRequests += 1; return self.f.emergencyResult }, now: d.now)
    }
    func run() -> EmergencySleep.Result { EmergencySleep.run(expectedSession: f.session.identifier!, dependencies: dependencies) }
    func model() -> AppModel {
        var d = f.dependencies
        d.emergency = { id in EmergencySleep.run(expectedSession: id, dependencies: self.dependencies) }
        let temperature = f.sample.temperatureC; f.sample.temperatureC = nil
        let model = AppModel(testTimer: false, dependencies: d, startTimer: false)
        f.sample.temperatureC = temperature
        return model
    }
}

@Suite @MainActor struct EmergencyCooldownTests {
    @Test func conditionLostAfterIntentDoesNotCreateFailureCooldown() {
        let h = CooldownHarness(); let before = h.f.session
        h.onSnapshot = { n in if n == 2 { h.f.sample.temperatureC = 94.9 } }
        guard case .failure = h.run() else { Issue.record("Cancelled preparation reported success"); return }
        #expect(h.f.calls.isEmpty && h.f.emergencyRequests == 0)
        #expect(h.f.session.retryAfter == nil)
        #expect(h.f.session.identifier == before.identifier && h.f.session.owner == before.owner)
        #expect(h.f.session.owned && h.f.session.phase == .active && h.f.session.until == before.until)
        #expect(!h.f.held)
    }
    @Test func expiredTimerIsNotDelayedByCancelledEmergencyIntent() async {
        let h = CooldownHarness(); let model = h.model(); h.f.now = h.f.now.addingTimeInterval(3601)
        h.onSnapshot = { n in if n == 2 { h.f.sample.temperatureC = 94.9 } }
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.isEmpty && h.f.session.owned)
        model.tick()
        #expect(h.f.calls.count == 1 && h.f.calls.first?.disabled == false)
        #expect(h.f.state == .enabled && !h.f.session.owned && model.status == .off)
        #expect(h.f.emergencyRequests == 0)
    }
    @Test func watchdogRecoversAfterSimulatedGUIAbortBetweenIntentAndRestore() {
        let h = CooldownHarness(); h.stopAfterIntentSave = true
        _ = h.run() // Controlled abort after the fake journal write; no process kill or power command.
        #expect(h.f.calls.isEmpty && h.f.session.owned && h.f.session.emergencyAttempt != nil)
        h.f.sample.temperatureC = nil
        var watchdog = h.f.dependencies
        var next = h.f.identity; next.pid += 1; next.startSeconds += 1
        watchdog.identity = { next }; watchdog.ownerAlive = { _ in false }
        #expect(Watchdog.tick(dependencies: watchdog, log: { _ in }))
        #expect(h.f.calls.count == 1 && h.f.calls.first?.prompt == false)
        #expect(h.f.state == .enabled && !h.f.session.owned && h.f.emergencyRequests == 0)
    }
    @Test func realFailureCooldownStartsAfterTheAttemptReturns() {
        let h = CooldownHarness(); h.f.outcome = .canceled; h.restoreElapsed = 301
        guard case .failure = h.run() else { Issue.record("Unrestored sleep reported success"); return }
        #expect(h.f.calls.count == 1 && h.f.session.owned)
        #expect(h.f.session.retryAfter == h.f.now.addingTimeInterval(300))
        #expect(h.f.emergencyRequests == 0)
    }
    @Test func cancelledPreparationPreservesAnExistingRealFailureCooldown() {
        let h = CooldownHarness(); let existing = h.f.now.addingTimeInterval(120)
        h.f.session.retryAfter = existing // A prior ordinary restore really failed; no emergency intent yet.
        h.onSnapshot = { n in if n == 2 { h.f.sample.temperatureC = 94.9 } }
        _ = h.run()
        #expect(h.f.calls.isEmpty && h.f.session.retryAfter == existing)
        #expect(h.f.session.owned && h.f.emergencyRequests == 0)
    }
    @Test(arguments: Array(0..<4)) func lastSnapshotCannotBypassRestorePreconditions(_ variant: Int) {
        let h = CooldownHarness()
        h.onSnapshot = { n in
            guard n == 2 else { return }
            switch variant {
            case 0: h.f.state = .unknown
            case 1: h.f.identityAvailable = false
            case 2: h.f.session.identifier = UUID()
            default: h.f.session.owner?.pid += 1
            }
        }
        guard case .failure = h.run() else { Issue.record("Conflict not rejected"); return }
        #expect(h.f.calls.isEmpty && h.f.emergencyRequests == 0)
        #expect(h.f.session.owned && !h.f.held)
    }
    @Test(arguments: [false, true]) func failedCooldownSaveStillThrottlesLiveModel(_ ordinaryTimer: Bool) async throws {
        let h = CooldownHarness(); let model = h.model()
        h.f.now = h.f.now.addingTimeInterval(3601); h.f.outcome = .canceled; h.f.failSaveAt = 2
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 1 && h.f.session.retryAfter == nil && h.f.session.owned)
        h.f.failSaveAt = nil
        if ordinaryTimer { h.f.sample.temperatureC = 94.9 }
        model.tick(); await model.waitForEmergency()
        try #require(h.f.calls.count == 1, "Failed cooldown persistence must not cause an immediate second real attempt")
        h.f.now = h.f.now.addingTimeInterval(301); h.f.outcome = .confirmed
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 2 && h.f.state == .enabled && !h.f.session.owned)
    }

    @Test func watchdogHonorsCooldownAfterActualGUIRestoreFailure() {
        let h = CooldownHarness(); h.f.outcome = .canceled; _ = h.run()
        let retry = h.f.session.retryAfter
        #expect(retry == h.f.now.addingTimeInterval(300) && h.f.calls.count == 1)
        var d = h.f.dependencies; var next = h.f.identity; next.pid += 1
        d.identity = { next }; d.ownerAlive = { _ in false }
        #expect(!Watchdog.tick(dependencies: d, log: { _ in }))
        #expect(h.f.calls.count == 1 && h.f.session.retryAfter == retry && h.f.session.owned)
        h.f.now = h.f.now.addingTimeInterval(301); h.f.outcome = .confirmed
        #expect(Watchdog.tick(dependencies: d, log: { _ in }))
        #expect(h.f.calls.count == 2 && !h.f.session.owned && h.f.state == .enabled)
    }
    @Test(arguments: Array(0..<4)) func failureCooldownDoesNotOverwriteChangedAuthority(_ variant: Int) {
        let h = CooldownHarness(); h.f.outcome = .canceled
        h.afterRestore = {
            switch variant {
            case 0: h.f.session.identifier = UUID()
            case 1: h.f.session.owner?.pid += 1
            case 2: h.f.identityAvailable = false
            default: h.f.failLoad = true
            }
        }
        guard case .failure = h.run() else { Issue.record("Failure/conflict reported success"); return }
        #expect(h.f.calls.count == 1 && h.f.saved.count == 1 && h.f.emergencyRequests == 0)
        #expect(h.f.session.retryAfter == nil && h.f.session.owned && !h.f.held)
        if variant == 1 { #expect(h.f.session.owner != h.f.identity) }
    }

    @Test func failedRestoreEvidenceSurvivesRefreshReadFailure() async {
        let h = CooldownHarness(); let model = h.model(); h.f.outcome = .canceled
        h.afterRestore = { h.f.failLoad = true }
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 1 && model.status == .unknown)
        h.f.failLoad = false; h.afterRestore = {}
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 1 && h.f.session.owned)
        h.f.now = h.f.now.addingTimeInterval(301); h.f.outcome = .confirmed
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 2 && !h.f.session.owned && model.status == .off)
    }
    @Test func confirmedNoClearsLocalRetryForANewSession() async {
        let h = CooldownHarness(); let model = h.model(); let old = h.f.session.identifier
        h.f.outcome = .canceled; h.f.failSaveAt = 2
        model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.count == 1 && h.f.session.retryAfter == nil)
        h.f.failSaveAt = nil; h.f.state = .enabled; model.tick()
        #expect(model.status == .off && !h.f.session.owned)
        h.f.sample.temperatureC = 36; h.f.outcome = .confirmed; model.toggle(true)
        #expect(h.f.session.identifier != old && model.status == .on)
        h.f.sample.temperatureC = 95; model.tick(); await model.waitForEmergency()
        #expect(h.f.calls.map(\.disabled) == [false,true,false])
        #expect(h.f.emergencyRequests == 1 && model.status == .off)
    }

    @Test func confirmedNoDuringCompletionDoesNotKeepRestoreFailureError() async {
        let h = CooldownHarness(); h.f.outcome = .canceled
        var d = h.f.dependencies
        d.emergency = { id in
            let result = EmergencySleep.run(expectedSession: id, dependencies: h.dependencies)
            h.f.state = .enabled // Independent normal sleep becomes observable before the completion refresh.
            return result
        }
        h.f.sample.temperatureC = nil
        let model = AppModel(testTimer: false, dependencies: d, startTimer: false)
        h.f.sample.temperatureC = 95; model.tick(); await model.waitForEmergency()
        #expect(model.status == .off && !h.f.session.owned && h.f.calls.count == 1)
        #expect(model.operationError == nil && h.f.emergencyRequests == 0)
    }
    @Test func subsequentExternalNoClearsRestoreFailureError() async {
        let h = CooldownHarness(); let model = h.model(); h.f.outcome = .canceled
        model.tick(); await model.waitForEmergency()
        #expect(model.operationError != nil && h.f.session.owned)
        h.f.state = .enabled; model.tick()
        #expect(model.status == .off && !h.f.session.owned && model.operationError == nil)
        #expect(h.f.calls.count == 1 && h.f.emergencyRequests == 0)
    }

    @Test func confirmedNoDoesNotEraseARequestFailure() async {
        let h = CooldownHarness(); let model = h.model(); h.f.emergencyResult = .failed
        model.tick(); await model.waitForEmergency(); model.tick()
        #expect(model.status == .off && !h.f.session.owned && model.operationError?.contains("запрос") == true)
        #expect(h.f.calls.count == 1 && h.f.emergencyRequests == 1)
    }

}
