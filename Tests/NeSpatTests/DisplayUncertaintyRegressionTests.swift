import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor struct DisplayUncertaintyRegressionTests {
    @Test func temporaryUnknownPowerDoesNotRepeatClosedLidRequest() {
        let f=Fixture();let model=f.model();f.lid=true;model.toggle(true)
        #expect(f.displayCalls == 1)
        f.state = .unknown;model.tick();f.state = .disabled;model.tick()
        #expect(f.displayCalls == 1 && model.status == .on)
    }
    @Test func temporaryUnknownLidDoesNotRepeatClosedLidRequest() {
        let f=Fixture();let model=f.model();f.lid=true;model.toggle(true)
        f.lid=nil;model.tick();f.lid=true;model.tick()
        #expect(f.displayCalls == 1 && model.status == .on)
    }
}
