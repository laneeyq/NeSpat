import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor struct V73RegressionTests {
    @Test func ordinaryOffTitleHasNoDotOrLeadingSpace() {
        let f = Fixture(); f.sample.temperatureC = 36; f.sample.cpuPercent = 13
        f.sample.memUsedBytes = 69; f.sample.memTotalBytes = 100
        let model = f.model()
        #expect(model.menuTitle == "36° 13% 69%")
    }
    @Test(arguments: [11,12,13,14]) func activeBatteryMustReachEmergencyThreshold(_ percent: Int) {
        let f = Fixture(); f.active(); let model = f.model()
        f.sample.batteryPercent = percent; f.sample.charging = false
        model.tick()
        #expect(f.calls.isEmpty)
        #expect(f.session.owned && model.status == .on)
    }
    @Test func emergencyIsNotOrdinaryTimerCompletion() {
        let f = Fixture(); f.active(); f.sample.temperatureC = 95
        #expect(SafetyPolicy.restoreReason(session: f.session, sample: f.sample, thermalSerious: false, now: f.now) == nil)
    }
    @Test(arguments: Array(0..<7)) func menuTitlesCoverEveryState(_ variant: Int) {
        let f = Fixture(); f.sample.temperatureC = 36; f.sample.cpuPercent = 13
        f.sample.memUsedBytes = 69; f.sample.memTotalBytes = 100
        if variant == 1 { f.active() }
        if variant == 2 { f.state = .disabled }
        if variant == 3 { f.state = .unknown }
        if variant == 5 { f.sample = .init() }
        if variant == 6 { f.sample.temperatureC = .nan; f.sample.cpuPercent = .infinity }
        let model = f.model()
        if variant == 4 { f.outcome = .canceled; model.toggle(true); #expect(model.status == .off && model.operationError != nil) }
        let expected = ["36° 13% 69%","☕ 36° 13% 69%","⚠ 36° 13% 69%","⚠ 36° 13% 69%","⚠ 36° 13% 69%","— — —","— — 69%"]
        #expect(model.menuTitle == expected[variant])
        #expect(model.menuTitle.first?.isWhitespace == false)
    }

}
