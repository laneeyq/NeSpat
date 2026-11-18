import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor struct DisplayPolicyRegressionTests {
    @Test func adoptingActiveSessionWithClosedLidRequestsDisplaySleepOnce() {
        let f=Fixture();f.active();f.lid=true
        let model=f.model()
        #expect(f.displayCalls == 1)
        model.tick();model.tick()
        #expect(f.displayCalls == 1 && model.status == .on && f.calls.isEmpty)
    }
    @Test func unknownLidBecomingConfirmedClosedRequestsDisplaySleep() {
        let f=Fixture();f.lid=nil
        let model=f.model();model.toggle(true)
        #expect(f.displayCalls == 0)
        f.lid=true;model.tick()
        #expect(f.displayCalls == 1 && model.status == .on)
    }
    @Test func activationWhileClosedDoesNotRepeatOnNextSafetyTick() {
        let f=Fixture();let model=f.model();f.lid=true
        model.toggle(true)
        #expect(f.displayCalls == 1)
        model.tick();model.tick()
        #expect(f.displayCalls == 1 && model.status == .on)
    }
    @Test func openLidNeverSleepsDisplaysAndReclosingRequestsOnce() {
        let f=Fixture();let model=f.model();model.toggle(true)
        #expect(f.displayCalls == 0)
        f.lid=true;model.tick();#expect(f.displayCalls == 1)
        model.tick();model.tick();#expect(f.displayCalls == 1) // Input/wake/hotplug alone cannot force a loop.
        f.lid=false;model.tick();#expect(f.displayCalls == 1)
        f.lid=true;model.tick();#expect(f.displayCalls == 2)
        #expect(f.calls.map(\.disabled) == [true] && model.status == .on)
    }
    @Test func failedDisplayRequestIsVisibleAndNotAutomaticallyRepeated() {
        let f=Fixture();let model=f.model();f.lid=true
        f.displayResult = .init(code:1,out:"",err:"mock display failure")
        model.toggle(true);model.tick();model.tick()
        #expect(f.displayCalls == 1 && model.operationError?.contains("экран") == true)
        #expect(model.status == .on && f.emergencyRequests == 0)
    }
}
