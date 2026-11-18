import Foundation
import Testing
@testable import NeSpat

@MainActor
final class Fixture {
    let identity = ProcessIdentity(pid: 123, executable: "/test/NeSpat", startSeconds: 10, startMicroseconds: 20, bootID: "boot-a")
    var preference: String?
    var session = Session()
    var state: SleepState = .enabled
    var outcome: SleepControl.Outcome = .confirmed
    var applyState = true
    var calls: [(disabled: Bool, prompt: Bool)] = []
    var saved: [Session] = []
    var saveAttempts = 0
    var failSaveAt: Int?
    var failLoad = false
    var failLock = false
    var otherOwnerAlive = false
    var identityAvailable = true
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var sample = StatsSampler.Sample()
    var thermal = false
    var lid: Bool? = false
    var displayCalls = 0
    var displayResult = Proc.Result(code: 0, out: "", err: "")
    var held = false
    var emergencyRequests = 0
    var emergencyResult = EmergencySleep.RequestResult.requested

    func runEmergency(_ id: UUID) -> EmergencySleep.Result {
        let d = dependencies
        return EmergencySleep.run(expectedSession: id, dependencies: .init(
            lock: d.lock, load: d.load, save: d.save, identity: d.identity, readState: d.readState,
            snapshot: { .init(sample: self.sample, thermalSerious: self.thermal) },
            restore: { d.setSleep(false, false) }, request: { self.emergencyRequests += 1; return self.emergencyResult }, now: d.now))
    }

    func active() {
        state = .disabled
        session = Session(owned: true, until: now.addingTimeInterval(3600), pid: identity.pid,
                          owner: identity, originalSleepDisabled: false, phase: .active, identifier: UUID())
    }

    var dependencies: AppModel.Dependencies {
        .init(readState: { self.state }, setSleep: { disabled, prompt in
            self.calls.append((disabled, prompt))
            if self.outcome == .confirmed, self.applyState { self.state = disabled ? .disabled : .enabled }
            return self.outcome
        }, load: {
            if self.failLoad { throw CocoaError(.fileReadCorruptFile) }
            return self.session
        }, save: { session in
            self.saveAttempts += 1
            if self.saveAttempts == self.failSaveAt { throw CocoaError(.fileWriteNoPermission) }
            self.session = session
            self.saved.append(session)
        }, lock: {
            if self.failLock || self.held { throw SessionError.busy }
            self.held = true
            return { self.held = false }
        }, identity: { self.identityAvailable ? self.identity : nil },
        ownerAlive: { owner in owner == self.identity || self.otherOwnerAlive },
        now: { self.now }, sample: { self.sample }, thermalSerious: { self.thermal },
        lidClosed: { self.lid }, sleepDisplay: {
            self.displayCalls += 1
            return self.displayResult
        }, loadPreference: { self.preference }, savePreference: { self.preference = $0 }, thermalAvailable: { true }, requireCompleteSafety: false, emergency: { self.runEmergency($0) })
    }

    func model() -> AppModel { AppModel(testTimer: true, dependencies: dependencies, startTimer: false) }
}

@Suite @MainActor
struct ModelTests {
    @Test func unknownIsNeverReportedAsOff() {
        let f = Fixture(); f.state = .unknown
        let model = f.model()
        #expect(model.status == .unknown)
        model.toggle(true)
        #expect(f.calls.isEmpty)
        #expect(model.operationError != nil)
    }

    @Test func preexistingDisabledFlagIsNotClaimed() {
        let f = Fixture(); f.state = .disabled
        let model = f.model()
        model.toggle(true)
        #expect(model.status == .foreign)
        #expect(!f.session.owned)
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
        #expect(model.prepareToQuit())
    }

    @Test func enableJournalsBeforeCommandAndRestoresOnlyItsChange() {
        let f = Fixture(); let model = f.model()
        model.setDuration(.h1)
        model.toggle(true)
        #expect(f.saved.map(\.phase) == [.pending, .active])
        #expect(f.session.originalSleepDisabled == false)
        #expect(f.session.owner == f.identity)
        #expect(f.session.until == f.now.addingTimeInterval(3600))
        #expect(model.status == .on)
        model.toggle(false)
        #expect(f.calls.map(\.disabled) == [true, false])
        #expect(!f.session.owned)
        #expect(model.status == .off)
    }

    @Test(arguments: [SleepControl.Outcome.canceled, .notConfirmed])
    func failedEnableIsNotSuccess(_ outcome: SleepControl.Outcome) {
        let f = Fixture(); f.outcome = outcome
        let model = f.model(); model.toggle(true)
        #expect(!f.session.owned)
        #expect(model.status == .off)
        #expect(model.operationError != nil)
    }

    @Test func unconfirmedChangeRetainsAmbiguousIntent() {
        let f = Fixture(); let model = f.model()
        var deps = f.dependencies
        deps.setSleep = { _, _ in f.state = .disabled; return .notConfirmed }
        let uncertain = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        uncertain.toggle(true)
        #expect(f.session.phase == .pending)
        #expect(!f.session.canRestore)
        #expect(uncertain.status == .foreign)
        #expect(!uncertain.prepareToQuit())
        #expect(model.status == .off)
    }

    @Test func writeFailureBeforeEnablePreventsCommand() {
        let f = Fixture(); let model = f.model(); f.failSaveAt = 1
        model.toggle(true)
        #expect(f.calls.isEmpty)
        #expect(!f.session.owned)
        #expect(model.operationError != nil)
    }

    @Test func writeFailureAfterEnableDoesNotInventOwnership() {
        let f = Fixture(); let model = f.model(); f.failSaveAt = 2
        model.toggle(true)
        #expect(f.state == .disabled)
        #expect(f.session.phase == .pending)
        #expect(!f.session.canRestore)
        #expect(model.status != .on)
        #expect(model.operationError != nil)
    }

    @Test(arguments: [SleepControl.Outcome.canceled, .notConfirmed])
    func failedRestoreKeepsOwnershipAndBlocksQuit(_ outcome: SleepControl.Outcome) {
        let f = Fixture(); f.active(); f.outcome = outcome
        let model = f.model(); model.toggle(false)
        #expect(f.session.canRestore)
        #expect(model.status == .on)
        #expect(model.operationError != nil)
        #expect(!model.prepareToQuit())
        #expect(f.session.owned)
    }

    @Test func canceledExplicitRestoreDoesNotClearActiveSession() {
        let f = Fixture(); f.active(); f.outcome = .canceled
        let model = f.model(); model.forceRestoreSleep()
        #expect(f.session.canRestore)
        #expect(model.operationError != nil)
    }

    @Test func explicitForeignRestoreRequiresConfirmedObservation() {
        let f = Fixture(); f.state = .disabled; f.outcome = .notConfirmed
        let model = f.model(); model.forceRestoreSleep()
        #expect(model.status == .foreign)
        #expect(model.operationError != nil)
        f.outcome = .confirmed
        model.forceRestoreSleep()
        #expect(model.status == .off)
        #expect(!f.session.owned)
    }

    @Test func successfulOrdinaryTerminationRestoresSleep() {
        let f = Fixture(); f.active(); let model = f.model()
        #expect(model.prepareToQuit())
        #expect(f.calls.map(\.disabled) == [false])
        #expect(f.state == .enabled)
        #expect(!f.session.owned)
    }

    @Test func missingOrCorruptStatePreventsMutation() {
        let f = Fixture(); f.active(); f.failLoad = true
        let model = f.model(); model.toggle(true); model.forceRestoreSleep()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        #expect(f.session.canRestore)
        #expect(model.status == .unknown)
    }

    @Test func lockFailurePreventsMutation() {
        let f = Fixture(); let model = f.model(); f.failLock = true
        model.toggle(true)
        #expect(f.calls.isEmpty)
        #expect(model.operationError != nil)
    }

    @Test func liveOtherInstanceIsReadOnlyIncludingExplicitRecovery() {
        let f = Fixture(); f.active()
        f.session.owner?.startSeconds += 1
        f.otherOwnerAlive = true
        let original = f.session
        let model = f.model(); model.setDuration(.h8); model.toggle(true); model.forceRestoreSleep()
        #expect(f.session == original)
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
        #expect(model.status == .foreign)
        #expect(model.prepareToQuit())
    }

    @Test func deadOwnerIsAdoptedOnlyInSameBoot() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456
        let model = f.model()
        #expect(f.session.owner == f.identity)
        #expect(model.status == .on)
        #expect(f.calls.isEmpty)
    }

    @Test func oldBootAndLegacyAndPendingAreNotAutomaticallyOwned() {
        for variant in 0..<3 {
            let f = Fixture(); f.active()
            if variant == 0 { f.session.owner?.bootID = "older-boot" }
            if variant == 1 { f.session.owner = nil; f.session.originalSleepDisabled = nil; f.session.phase = nil }
            if variant == 2 { f.session.phase = .pending }
            let original = f.session
            let model = f.model()
            #expect(model.status == .foreign)
            #expect(f.calls.isEmpty)
            #expect(f.session == original)
            #expect(model.operationError != nil)
        }
    }

    @Test func externalSleepEnableReleasesOwnershipWithoutCommand() {
        let f = Fixture(); f.active(); let model = f.model()
        f.state = .enabled; model.tick()
        #expect(!f.session.owned)
        #expect(f.calls.isEmpty)
        #expect(model.status == .off)
        f.state = .disabled; model.tick()
        #expect(model.status == .foreign)
        #expect(model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test func timerFailureIsVisibleThrottledAndDoesNotRepeatPrompts() {
        let f = Fixture(); f.active(); let model = f.model()
        f.outcome = .canceled; f.now = f.now.addingTimeInterval(3601)
        model.tick(); model.tick(); model.tick()
        #expect(f.calls.count == 1)
        #expect(f.calls.first?.prompt == true)
        #expect(f.session.canRestore)
        #expect(f.session.needsAttention == true)
        #expect(model.operationError != nil)
        f.now = f.now.addingTimeInterval(301); model.tick()
        #expect(f.calls.count == 2)
        #expect(f.calls.last?.prompt == false)
    }

    @Test func timerSuccessAndChangingDuration() {
        let f = Fixture(); f.active(); let model = f.model()
        model.setDuration(.h3)
        #expect(f.session.until == f.now.addingTimeInterval(10800))
        model.setDuration(.none)
        #expect(f.session.until == nil)
        model.setDuration(.test); f.now = f.now.addingTimeInterval(121); model.tick()
        #expect(f.state == .enabled)
        #expect(!f.session.owned)
        #expect(model.lastReason?.contains("таймер") == true)
    }

    @Test func unsafeBatteryAndThermalConditionsRefuseActivation() {
        for variant in 0..<3 {
            let f = Fixture()
            if variant == 0 { f.sample.batteryPercent = 14; f.sample.charging = false }
            if variant == 1 { f.sample.temperatureC = 95 }
            if variant == 2 { f.thermal = true }
            let model = f.model(); model.toggle(true)
            #expect(f.calls.isEmpty)
            #expect(model.operationError != nil)
        }
    }

    @Test func safetyThresholdsAndACPower() {
        let f = Fixture(); f.sample.batteryPercent = 14; f.sample.charging = true
        #expect(SafetyPolicy.unsafeReason(sample: f.sample, thermalSerious: false) == nil)
        f.sample.charging = false; f.sample.batteryPercent = 15
        #expect(SafetyPolicy.unsafeReason(sample: f.sample, thermalSerious: false) == nil)
        f.sample.batteryPercent = 14
        #expect(SafetyPolicy.unsafeReason(sample: f.sample, thermalSerious: false) != nil)
        f.sample.temperatureC = 94.9; f.sample.batteryPercent = 100
        #expect(SafetyPolicy.unsafeReason(sample: f.sample, thermalSerious: false) == nil)
        f.sample.temperatureC = 95
        #expect(SafetyPolicy.unsafeReason(sample: f.sample, thermalSerious: false) != nil)
    }

    @Test func displaySleepFailureIsVisible() {
        let f = Fixture(); let model = f.model()
        f.lid = true; f.displayResult = .init(code: 1, out: "", err: "mock failure")
        model.toggle(true)
        #expect(model.status == .on)
        #expect(f.displayCalls == 1)
        #expect(model.operationError?.contains("экран") == true)
    }

    @Test func explicitRecoveryOfOwnPendingIntentWorks() {
        let f = Fixture(); f.active(); f.session.phase = .pending
        let model = f.model()
        #expect(!model.prepareToQuit())
        model.forceRestoreSleep()
        #expect(f.state == .enabled)
        #expect(!f.session.owned)
        #expect(model.status == .off)
        #expect(model.operationError == nil)
        #expect(model.prepareToQuit())
    }

    @Test func successfulRetryClearsFailureMessageAndMenuWarnsUntilThen() {
        let f = Fixture(); f.active(); let model = f.model()
        f.outcome = .canceled; model.toggle(false)
        #expect(model.menuTitle.hasPrefix("⚠"))
        f.outcome = .confirmed; model.toggle(false)
        #expect(model.operationError == nil)
        #expect(model.lastReason == "Сон возвращён")
        #expect(!model.menuTitle.hasPrefix("⚠"))
    }

    @Test func activeSafetyTransitionsRestoreSleep() async {
        for variant in 0..<3 {
            let f = Fixture(); f.active(); let model = f.model()
            if variant == 0 { f.sample.batteryPercent = 14; f.sample.charging = false }
            if variant == 1 { f.thermal = true }
            if variant == 2 { f.sample.temperatureC = 95 }
            model.tick(); await model.waitForEmergency()
            if variant == 0 {
                #expect(f.calls.isEmpty && f.session.owned && model.status == .on)
                #expect(f.emergencyRequests == 0) // 14% must not preempt the 10% emergency threshold.
            } else {
                #expect(f.calls.map(\.disabled) == [false])
                #expect(f.calls.first?.prompt == false)
                #expect(f.state == .enabled && !f.session.owned)
                #expect(f.emergencyRequests == 1)
            }
        }
    }

    @Test func missingIdentityCannotSilentlyQuitAnOwnedSession() {
        let f = Fixture(); f.active(); let model = f.model(); f.identityAvailable = false
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        #expect(f.session.canRestore)
        #expect(model.operationError != nil)
    }

    @Test func missingProcessIdentityPreventsEnable() {
        let f = Fixture(); let model = f.model(); f.identityAvailable = false
        model.toggle(true)
        #expect(f.calls.isEmpty)
        #expect(model.operationError != nil)
    }
}
