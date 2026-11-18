import Testing
@testable import NeSpat

@Suite @MainActor
struct WatchdogTests {
    @Test func deadOwnerRecoveryUsesNoPromptAndPreservesFailure() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456; f.outcome = .notConfirmed
        var messages: [String] = []
        #expect(!Watchdog.tick(dependencies: f.dependencies, log: { messages.append($0) }))
        #expect(f.session.canRestore)
        #expect(f.calls.count == 1)
        #expect(f.calls.first?.prompt == false)
        #expect(!messages.isEmpty)
        #expect(!Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.count == 1)
        f.now = f.now.addingTimeInterval(301); f.outcome = .confirmed
        #expect(Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(!f.session.owned)
        #expect(f.state == .enabled)
    }

    @Test func liveOwnerNoSafetyConditionMeansNoCommand() {
        let f = Fixture(); f.active()
        #expect(Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.isEmpty)
    }

    @Test(arguments: [11,12,13,14]) func activeBatteryAboveEmergencyThresholdIsNotEnded(_ percent: Int) {
        let f = Fixture(); f.active(); f.sample.batteryPercent = percent; f.sample.externalPowerConnected = false
        #expect(Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.isEmpty && f.session.owned)
    }

    @Test func watchdogChecksChipTemperatureAsWellAsThermalState() {
        let f = Fixture(); f.active(); f.sample.temperatureC = 95
        #expect(Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.count == 1)
        #expect(!f.session.owned)
    }

    @Test func uncertainOwnershipAndOtherBootAreNeverReset() {
        for variant in 0..<3 {
            let f = Fixture(); f.active(); f.session.owner?.pid = 456
            if variant == 0 { f.session.phase = .pending }
            if variant == 1 { f.session.originalSleepDisabled = nil }
            if variant == 2 { f.session.owner?.bootID = "old-boot" }
            #expect(!Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
            #expect(f.calls.isEmpty)
            #expect(f.session.owned)
        }
    }

    @Test func unknownStateAndCorruptStoreAreNotReset() {
        let f = Fixture(); f.active(); f.state = .unknown
        #expect(!Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        f.failLoad = true
        #expect(!Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.isEmpty)
    }

    @Test func heldLockPreventsWatchdogFromRacingGUI() {
        let f = Fixture(); f.active(); f.held = true
        #expect(Watchdog.tick(dependencies: f.dependencies, log: { _ in }))
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
    }
}
