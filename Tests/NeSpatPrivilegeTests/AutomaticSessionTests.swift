import Foundation
import Testing
@testable import NeSpatPrivilegeCore

actor AutoFixture: AutomaticSessionBackend {
    let boot = UUID()
    var value: AutomaticObservation
    var arms = 0, restores = 0, beats = 0
    var applyRestore = true
    init() {
        value = AutomaticObservation(serviceVerified: true, setupAuthorized: true, activeUser: true,
            lidClosed: false, power: .enabled, safety: fixtureSafetySnapshot, lease: nil, foreign: false,
            boot: boot, wall: Date(timeIntervalSince1970: 1_800_000_000), continuous: 1000)
    }
    func observation() -> AutomaticObservation { value }
    func prearm(maximumSeconds: TimeInterval) {
        arms += 1
        value.lease = AutomaticLease(id: UUID(), boot: boot, deadline: value.wall.addingTimeInterval(maximumSeconds), expires: value.continuous + maximumSeconds)
        value.power = .disabled
    }
    func pollRestoration(session: UUID) {
        restores += 1
        if applyRestore { value.power = .enabled; value.lease = nil }
    }
    var manualRequests = [UUID]()
    var changeBootDuringRecovery = false
    func substituteSession() { prearm(maximumSeconds: 120) }
    func simulateRestartDuringRecovery() { changeBootDuringRecovery = true }
    func manualRecovery(session: UUID) {
        manualRequests.append(session)
        value.power = .enabled
        value.lease = nil
        if changeBootDuringRecovery { reboot() }
    }
    var displayRequests: [UUID] = []
    func sleepDisplayIfClosed(session: UUID) { displayRequests.append(session) }
    func heartbeat(session: UUID) { beats += 1 }
    func counts() -> (Int, Int, Int) { (arms, restores, beats) }
    func lid(_ closed: Bool) { value.lidClosed = closed }
    func hazard(_ n: Int) {
        switch n {
        case 0: value.safety = .init(thermalSerious: true)
        case 1: value.safety = .init(batteryPercent: 10, externalPowerConnected: false, temperatureC: 40, thermalSerious: false)
        case 2: value.safety = .init()
        default: value.safety = .init(batteryPercent: 80, externalPowerConnected: true, temperatureC: 95, thermalSerious: false)
        }
    }
    func user(_ active: Bool) { value.activeUser = active }
    func advance(_ seconds: Double) { value.continuous += seconds; value.wall = value.wall.addingTimeInterval(seconds) }
    func watchdogCompleted() { value.power = .enabled; value.lease = nil }
    func failRestore() { applyRestore = false }
    func foreignState() { value.foreign = true; value.power = .disabled }
    func reboot() { value.boot = UUID() }
    func setup(_ valid: Bool) { value.setupAuthorized = valid }

}
@Suite struct AutomaticSessionTests {
    @Test func manualRecoveryRejectsSubstitutedSession() async {
        let backend = AutoFixture(), service = AutomaticSessionService(backend: backend)
        await service.setDesired(true)
        await backend.substituteSession()
        await service.restoreNow()
        #expect(await backend.manualRequests.isEmpty)
    }
    @Test func rebootDuringManualRecoveryCannotConfirmRestoration() async {
        let backend = AutoFixture(), service = AutomaticSessionService(backend: backend)
        await service.setDesired(true)
        await backend.simulateRestartDuringRecovery()
        await service.restoreNow()
        #expect(await service.state != .off)
        #expect(await service.operationError != nil)
    }
    @Test func displaySleepsOncePerClosureAndSessionKeepsRunning() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true)
        let lease = try #require(await f.observation().lease)
        #expect(await f.displayRequests.isEmpty)
        for closed in [true, true, false, true, true] {
            await f.lid(closed)
            await service.poll()
        }
        #expect(await f.displayRequests == [lease.id, lease.id])
        #expect(await f.observation().lease == lease)
        #expect(await f.restores == 0)
    }
    @Test func safeStartupPrearmsBeforeLidCloses() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true)
        let observation = await f.observation(), id = try #require(observation.lease?.id)
        #expect(await service.state == .prepared(id))
        #expect(await f.arms == 1)
    }
    @Test func lidCloseOpenAndControllerRestartDoNotSlideDeadline() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true); let initial = await f.observation(), lease = try #require(initial.lease)
        await f.lid(true); await service.poll()
        #expect(await service.state == .closed(lease.id))
        await f.advance(10); await f.lid(false); await service.poll()
        let restarted = AutomaticSessionService(backend: f); await restarted.setDesired(true)
        #expect(await restarted.state == .prepared(lease.id))
        #expect(await f.arms == 1)
        #expect(await f.observation().lease == lease)
    }
    @Test(arguments: Array(0..<4)) func criticalOrUnknownAutomaticallyRestores(_ condition: Int) async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true); await f.hazard(condition); await service.poll()
        let counts66 = await f.counts()
        #expect(counts66.1 == 1 && counts66.0 == 1)
        #expect(await service.observedPower == .enabled)
        #expect(await service.state == .off)
    }
    @Test(arguments: Array(0..<4)) func unsafeStartupCannotPrearm(_ condition: Int) async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await f.hazard(condition); await service.setDesired(true)
        let counts73 = await f.counts()
        #expect(counts73.0 == 0 && counts73.1 == 0)
    }
    @Test func expiryStopsWithoutAutomaticLeaseExtension() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true); await f.advance(43200); await service.poll(); await service.poll()
        let counts78 = await f.counts()
        #expect(counts78.0 == 1 && counts78.1 == 1)
        #expect(await service.observedPower == .enabled)
    }
    @Test func noActiveUserAndRevokedSetupDoNotLeaveGlobalFlagOwned() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true); await f.user(false); await service.poll()
        #expect(await f.restores == 1)
        await f.user(true); await f.setup(false); await service.poll()
        #expect(await f.arms == 1)
    }
    @Test func failedRestorationIsNotReportedAsOff() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true); let value = await f.observation(), id = try #require(value.lease?.id)
        await f.failRestore(); await f.hazard(0); await service.poll()
        #expect(await service.state == .recovering(id))
        #expect(await service.observedPower == .disabled)
        #expect(await service.operationError != nil)
    }
    @Test func authenticatedWatchdogCompletionClearsPreviousRestoreWarning() async {
        let backend = AutoFixture(), service = AutomaticSessionService(backend: backend)
        await service.setDesired(true)
        await backend.failRestore()
        await backend.hazard(0)
        await service.poll()
        #expect(await service.operationError != nil)
        await backend.watchdogCompleted()
        await service.poll()
        #expect(await service.operationError == nil)
        #expect(await service.sessionFinished)
        #expect(await backend.arms == 1)
    }
    @Test func foreignPowerAndRebootCannotBeAdopted() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await f.foreignState(); await service.setDesired(true)
        let counts99 = await f.counts()
        #expect(counts99.0 == 0 && counts99.1 == 0)
        let g = AutoFixture(), other = AutomaticSessionService(backend: g)
        await other.setDesired(true); await g.reboot(); await other.poll()
        let counts102 = await g.counts()
        #expect(counts102.0 == 1 && counts102.1 == 0)
    }
    @Test func backgroundLoopHasNoPanelOrPasswordDependency() async throws {
        let f = AutoFixture(), service = AutomaticSessionService(backend: f)
        await service.setDesired(true)
        let loop = Task { try await service.run(every: .milliseconds(2)) }
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(15))
        loop.cancel(); _ = try? await loop.value
        #expect(await f.arms == 1)
        #expect(await f.beats > 0)
        await service.setDesired(false)
        #expect(await service.observedPower == .enabled)
    }
    @Test func approvedProductionMaximumIsExactlyTwelveHours() throws {
        #expect(FullGrantLifetimePolicy.productionMaximumLifetime == 43200)
        try FullGrantLifetimePolicy.production.validate(confirmedAt: 100, expires: 43300)
        #expect(throws: PrivilegeError.denied) { try FullGrantLifetimePolicy.production.validate(confirmedAt: 100, expires: 43301) }
    }

}
