import Testing
@testable import NeSpat
@Suite @MainActor struct StrictSensorPolicyTests {
    @Test func watchdogAlsoRestoresUnknownWithoutForcedSleep() {
        let f=Fixture();f.active();var d=f.dependencies;d.requireCompleteSafety=true
        #expect(Watchdog.tick(dependencies:d,log:{_ in}))
        #expect(f.calls.map(\.disabled) == [false] && f.emergencyRequests == 0 && !f.session.owned)
    }
    @Test func unknownPreventsNewActivation() {
        let f=Fixture();var d=f.dependencies;d.requireCompleteSafety=true
        let m=AppModel(testTimer:false,dependencies:d,startTimer:false);m.toggle(true)
        #expect(f.calls.isEmpty && m.status == .off && m.operationError != nil)
    }
    @Test func lossRestoresOnlyAndKeepsEvidenceOnFailure() {
        for fail in [false,true] {
            let f=Fixture();f.active();f.sample.batteryPercent=80;f.sample.externalPowerConnected=true;f.sample.temperatureC=40
            var d=f.dependencies;d.requireCompleteSafety=true
            let m=AppModel(testTimer:false,dependencies:d,startTimer:false)
            f.sample.temperatureC=nil;f.applyState = !fail;m.tick()
            #expect(f.calls.map(\.disabled) == [false] && f.emergencyRequests == 0)
            #expect(f.session.owned == fail && (m.status == .off) == !fail)
        }
    }
}
