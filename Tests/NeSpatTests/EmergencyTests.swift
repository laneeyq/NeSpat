import Foundation
import IOKit.ps
import Testing
@testable import NeSpat

@MainActor private final class EmergencyHarness {
    let f = Fixture()
    var events: [String] = []
    var readCount = 0, loadCount = 0, snapshotCount = 0
    var onRead: (Int) -> Void = { _ in }
    var onLoad: (Int) -> Void = { _ in }
    var onSnapshot: (Int) -> Void = { _ in }
    var afterRestore: () -> Void = {}
    init() { f.active(); f.sample.temperatureC = 95 }
    func run() -> EmergencySleep.Result {
        let d = f.dependencies
        return EmergencySleep.run(expectedSession: f.session.identifier!, dependencies: .init(
            lock: { self.events.append("lock"); let unlock = try d.lock(); return { self.events.append("unlock"); unlock() } },
            load: { self.loadCount += 1; self.onLoad(self.loadCount); return try d.load() },
            save: { record in self.events.append(record.owned ? "save-active" : "save-ended"); try d.save(record) },
            identity: d.identity,
            readState: { self.readCount += 1; self.onRead(self.readCount); self.events.append("verify:\(self.f.state)"); return self.f.state },
            snapshot: { self.snapshotCount += 1; self.onSnapshot(self.snapshotCount); return .init(sample: self.f.sample, thermalSerious: self.f.thermal) },
            restore: { self.events.append("restore"); let result = d.setSleep(false, false); self.afterRestore(); return result },
            request: {
                self.events.append("sleepnow")
                #expect(self.f.state == .enabled && !self.f.session.owned && self.f.held)
                #expect(self.f.session.emergencyAttempt != nil)
                self.f.emergencyRequests += 1; return self.f.emergencyResult
            }, now: d.now))
    }
}

@Suite @MainActor struct EmergencyTests {
    @Test(arguments: Array(0..<9)) func temperatureBoundariesAndInvalidValues(_ index: Int) {
        let values: [Double?] = [94.9,95,96,nil,.nan,.infinity,-.infinity,0,150]
        var sample = StatsSampler.Sample(); sample.temperatureC = values[index]
        #expect((SafetyPolicy.emergencyReason(sample: sample, thermalSerious: false) != nil) == (index == 1 || index == 2))
    }
    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical])
    func independentThermalState(_ state: ProcessInfo.ThermalState) {
        let serious = SafetyPolicy.thermalEmergency(state)
        #expect(serious == (state == .serious || state == .critical))
        #expect((SafetyPolicy.emergencyReason(sample: .init(), thermalSerious: serious) != nil) == serious)
    }
    @Test(arguments: Array(0..<9)) func batteryAndACBoundaries(_ index: Int) {
        let cases: [(Int?, Bool?, Bool)] = [(9,false,true),(10,false,true),(11,false,false),(10,true,false),(10,nil,false),(nil,false,false),(-1,false,false),(101,false,false),(14,false,false)]
        var s = StatsSampler.Sample(); (s.batteryPercent,s.externalPowerConnected) = (cases[index].0,cases[index].1)
        #expect((SafetyPolicy.emergencyReason(sample: s, thermalSerious: false) != nil) == cases[index].2)
    }
    @Test func parserDistinguishesExternalPowerFromChargingAndUnknown() {
        for (state, expected): (String?, Bool?) in [(kIOPSACPowerValue,true),(kIOPSBatteryPowerValue,false),(nil,nil),(kIOPSOffLineValue,nil),("other",nil)] {
            var desc: [String: Any] = [kIOPSCurrentCapacityKey:10,kIOPSMaxCapacityKey:100,kIOPSIsChargingKey:false]
            desc[kIOPSPowerSourceStateKey] = state
            let parsed = StatsSampler.parseBattery(desc)
            #expect(parsed.percent == 10 && parsed.externalPowerConnected == expected)
        }
        for bad: Any in [true, -1, Double.nan, Double.infinity, "10"] {
            #expect(StatsSampler.parseBattery([kIOPSCurrentCapacityKey:bad,kIOPSMaxCapacityKey:100]).percent == nil)
        }
        for desc: [String:Any] in [[:],[kIOPSMaxCapacityKey:100],[kIOPSCurrentCapacityKey:10],[kIOPSCurrentCapacityKey:10,kIOPSMaxCapacityKey:0],[kIOPSCurrentCapacityKey:101,kIOPSMaxCapacityKey:100]] {
            #expect(StatsSampler.parseBattery(desc).percent == nil)
        }
    }
    @Test func fractionalBatteryDoesNotTriggerFromDisplayRounding() {
        let parsed = StatsSampler.parseBattery([kIOPSCurrentCapacityKey:104,kIOPSMaxCapacityKey:1000,kIOPSPowerSourceStateKey:kIOPSBatteryPowerValue])
        var sample = StatsSampler.Sample(); sample.batteryPercent = parsed.percent
        sample.batteryPercentExact = parsed.exact; sample.externalPowerConnected = parsed.externalPowerConnected
        #expect(sample.batteryPercent == 10 && sample.batteryLevel == 10.4)
        #expect(SafetyPolicy.emergencyReason(sample: sample, thermalSerious: false) == nil)
        #expect(StatsSampler.powerSourceText(nil) == "источник неизвестен")
        #expect(StatsSampler.powerSourceText(true) == "внешнее питание")
    }
    @Test func temperatureReaderDoesNotMixSensorKindsOrInventZero() {
        let selected = TemperatureReader.chipTemperatureC(from: [("PMU tdie0",94.9),("PMU tdie10",96),("PMU tdev1",120),("PMU tcal",130),("gas gauge battery",140),("PMU tdie_fake",149),("PMU tdie",148),("PMU tdie1",.nan),("PMU tdie2",.infinity)])
        #expect(selected == 96)
        #expect(TemperatureReader.chipTemperatureC(from: []) == nil)
        #expect(TemperatureReader.chipTemperatureC(from: [("PMU tdie0",0),("PMU tdie1",150)]) == nil)
    }
    @Test func restoreVerifyAndFinalCheckPrecedeRequest() {
        let h = EmergencyHarness(); let result = h.run()
        #expect(h.events == ["lock","verify:disabled","save-active","verify:disabled","restore","verify:enabled","save-ended","verify:enabled","sleepnow","unlock"])
        guard case .requested = result else { Issue.record("Unexpected \(result)"); return }
        #expect(h.f.calls.map(\.disabled) == [false] && h.f.calls.first?.prompt == false)
        #expect(!h.f.session.owned && h.f.state == .enabled && !h.f.held)
    }
    @Test(arguments: Array(0..<7)) func unprovenOwnershipModeOrConditionNeverExecutes(_ variant: Int) {
        let h = EmergencyHarness()
        switch variant {
        case 0: h.f.identityAvailable = false
        case 1: h.f.session.owner?.startSeconds += 1
        case 2: h.f.session.owned = false
        case 3: h.f.state = .unknown
        case 4: h.f.state = .enabled
        case 5: h.f.session.identifier = UUID(); h.onLoad = { _ in h.f.session.identifier = UUID() }
        default: h.f.sample.temperatureC = 94.9
        }
        #expect(h.run() == .skipped)
        #expect(h.f.calls.isEmpty && h.f.emergencyRequests == 0)
    }
    @Test(arguments: Array(0..<5)) func restorationFailuresKeepJournalAndDoNotRequest(_ variant: Int) {
        let h = EmergencyHarness()
        switch variant {
        case 0: h.f.outcome = .canceled
        case 1: h.f.applyState = false
        case 2: h.afterRestore = { h.f.state = .unknown }
        case 3: h.f.failSaveAt = 1
        default: h.f.failSaveAt = 2
        }
        guard case .failure = h.run() else { Issue.record("Failure was reported as success"); return }
        #expect(h.f.emergencyRequests == 0 && h.f.session.owned && h.f.session.identifier != nil)
        if variant == 3 { #expect(h.f.calls.isEmpty) }
        #expect(!h.f.held)
    }
    @Test func commandFailureDoesNotOverrideIndependentNoObservation() {
        let h = EmergencyHarness(); h.f.outcome = .notConfirmed; h.afterRestore = { h.f.state = .enabled }
        guard case .requested = h.run() else { Issue.record("Actual No ignored"); return }
        #expect(h.f.emergencyRequests == 1 && !h.f.session.owned)
    }
    @Test(arguments: Array(0..<6)) func finalRevalidationStopsConflicts(_ variant: Int) {
        let h = EmergencyHarness()
        if variant < 2 { h.onRead = { n in if n == 4 { h.f.state = variant == 0 ? .disabled : .unknown } } }
        if variant == 2 { h.onSnapshot = { n in if n == 3 { h.f.identityAvailable = false } } }
        if variant == 3 { h.onSnapshot = { n in if n == 3 { h.f.session = Session() } } }
        if variant == 4 { h.onLoad = { n in if n == 3 { h.f.session.owner?.pid += 1 } } }
        if variant == 5 { h.f.failLoad = true }
        guard case .failure = h.run() else { Issue.record("Conflict was not rejected"); return }
        #expect(h.f.emergencyRequests == 0 && !h.f.held)
    }
    @Test func ACChangeCancelsBatteryRequestButKeepsRestoredSleep() {
        let h = EmergencyHarness(); h.f.sample.temperatureC = nil; h.f.sample.batteryPercent = 10; h.f.sample.externalPowerConnected = false
        h.onSnapshot = { n in if n == 3 { h.f.sample.externalPowerConnected = true } }
        guard case .restored = h.run() else { Issue.record("Reconnected AC ignored"); return }
        #expect(h.f.emergencyRequests == 0 && !h.f.session.owned && h.f.state == .enabled)
    }
    @Test func failedRequestCannotReenableOrRepeatAfterWake() async {
        let f = Fixture(); f.active(); let model = f.model(); f.sample.temperatureC = 95; f.emergencyResult = .failed
        model.tick(); await model.waitForEmergency()
        #expect(f.emergencyRequests == 1 && f.calls.map(\.disabled) == [false])
        #expect(model.status == .off && !f.session.owned && model.operationError?.contains("запрос") == true)
        model.tick(); model.tick(); await model.waitForEmergency()
        #expect(f.emergencyRequests == 1 && f.calls.count == 1 && model.status == .off)
    }
    @Test func emergencyHasPriorityOverExpiredDeadline() async {
        let f = Fixture(); f.active(); let model = f.model()
        f.now = f.now.addingTimeInterval(3601); f.thermal = true
        model.tick(); await model.waitForEmergency()
        #expect(f.emergencyRequests == 1 && f.calls.map(\.disabled) == [false])
        #expect(f.session.lastReason?.contains("аварийная") == true)
    }
    @Test func inFlightEmergencySerializesManualOffQuitAndRepeatedTicks() async {
        let f = Fixture(); f.active(); var d = f.dependencies
        var resume: CheckedContinuation<Void,Never>?
        d.emergency = { id in await withCheckedContinuation { resume = $0 }; return f.runEmergency(id) }
        let model = AppModel(testTimer: false, dependencies: d, startTimer: false)
        f.thermal = true; model.tick()
        while resume == nil { await Task.yield() }
        #expect(model.busy && !model.canToggleMode)
        model.toggle(false); model.forceRestoreSleep(); model.tick(); model.setDuration(.h8)
        #expect(!model.prepareToQuit() && f.calls.isEmpty)
        resume?.resume(); await model.waitForEmergency()
        #expect(!model.busy && model.status == .off && f.calls.count == 1 && f.emergencyRequests == 1)
    }
    @Test func restorationFailureIsThrottledAndRemainsVisible() async {
        let f = Fixture(); f.active(); let model = f.model(); f.outcome = .canceled; f.thermal = true
        model.tick(); await model.waitForEmergency(); model.tick(); await model.waitForEmergency()
        #expect(f.calls.count == 1 && f.emergencyRequests == 0 && f.session.owned)
        #expect(model.operationError != nil && model.status == .on && f.session.needsAttention == true)
    }
    @Test func canceledConditionBeforeWorkerLeavesActiveUIConsistent() async {
        let f = Fixture(); f.active(); var d = f.dependencies
        var resume: CheckedContinuation<Void,Never>?
        d.emergency = { id in await withCheckedContinuation { resume = $0 }; return f.runEmergency(id) }
        let model = AppModel(testTimer: false, dependencies: d, startTimer: false)
        f.sample.batteryPercent = 10; f.sample.externalPowerConnected = false; model.tick()
        while resume == nil { await Task.yield() }
        f.sample.externalPowerConnected = true; resume?.resume(); await model.waitForEmergency()
        #expect(f.calls.isEmpty && f.emergencyRequests == 0 && f.session.owned)
        #expect(!model.busy && !model.emergencyInProgress && model.status == .on)
        #expect(model.menuTitle.hasPrefix("☕") && model.operationError == nil)
    }
    @Test func ordinaryRestoreCooldownDoesNotSuppressNewEmergency() async {
        let f = Fixture(); f.active(); let model = f.model()
        f.outcome = .canceled; f.now = f.now.addingTimeInterval(3601); model.tick()
        #expect(f.calls.count == 1 && f.session.retryAfter != nil && f.session.emergencyAttempt == nil)
        f.thermal = true; model.tick(); await model.waitForEmergency()
        #expect(f.calls.count == 2 && f.calls.last?.prompt == false)
        #expect(f.session.emergencyAttempt != nil && f.session.owned && f.emergencyRequests == 0)
        model.tick(); await model.waitForEmergency(); #expect(f.calls.count == 2)
    }
    @Test func stageGateAndPlanCannotInvokeRealSleep() {
        #expect(EmergencySleep.invocation.executable == "/usr/bin/pmset")
        #expect(EmergencySleep.invocation.arguments == ["sleepnow"])
        if case .blocked = EmergencySleep.blockedRequest() {} else { Issue.record("Production request activated") }
    }
}
