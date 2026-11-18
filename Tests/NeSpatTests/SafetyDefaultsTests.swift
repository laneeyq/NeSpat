import Foundation
import Testing
@testable import NeSpat
@Suite @MainActor struct SafetyDefaultsTests {
    func defaults(_ f:Fixture)->AppModel.Dependencies {
        let d=f.dependencies
        return .init(readState:d.readState,setSleep:d.setSleep,load:d.load,save:d.save,lock:d.lock,
            identity:d.identity,ownerAlive:d.ownerAlive,now:d.now,sample:d.sample,thermalSerious:d.thermalSerious,
            lidClosed:d.lidClosed,sleepDisplay:d.sleepDisplay)
    }
    @Test func omittedSafetyOverridesRemainStrict() {
        let f=Fixture();f.sample.batteryPercent=80;f.sample.externalPowerConnected=true;f.sample.temperatureC=40
        let d=defaults(f);#expect(d.requireCompleteSafety && !d.thermalAvailable())
        let m=AppModel(testTimer:false,dependencies:d,startTimer:false);m.toggle(true)
        #expect(f.calls.isEmpty && m.operationError != nil && !f.session.owned)
    }
    @Test(arguments:Array(0..<7)) func activationMatrix(_ variant:Int) {
        let f=Fixture();f.sample.batteryPercent=80;f.sample.externalPowerConnected=true;f.sample.temperatureC=40
        var d=defaults(f);d.thermalAvailable={variant != 3}
        switch variant {
        case 0:f.sample.batteryPercent=nil
        case 1:f.sample.externalPowerConnected=nil
        case 2:f.sample.temperatureC=nil
        case 4:f.sample.temperatureC = .nan
        case 6:f.thermal=true
        default:break
        }
        let m=AppModel(testTimer:false,dependencies:d,startTimer:false);m.toggle(true)
        #expect((m.status == .on) == (variant == 5))
        if variant != 5 {#expect(f.calls.isEmpty && m.operationError != nil && !f.session.owned)}
    }
    @Test func unknownRestoreFailureRetainsErrorCooldownAndDoesNotPromptOrLoop() {
        let f=Fixture();f.active();f.sample.batteryPercent=80;f.sample.externalPowerConnected=false;f.sample.temperatureC=40
        var d=defaults(f);d.thermalAvailable={true}
        let m=AppModel(testTimer:false,dependencies:d,startTimer:false)
        f.sample.temperatureC=nil;f.applyState=false;m.tick();let saved=f.session
        #expect(f.calls.count == 1 && f.calls[0].prompt == false && f.emergencyRequests == 0)
        #expect(saved.canRestore && saved.retryAfter != nil && saved.needsAttention == true && m.operationError != nil && m.status != .off)
        m.tick();m.tick();#expect(f.calls.count == 1 && f.session == saved)
        f.now=f.now.addingTimeInterval(301);f.applyState=true;m.tick()
        #expect(f.calls.count == 2 && f.emergencyRequests == 0 && m.status == .off && !f.session.owned)
    }
}
