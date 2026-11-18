import Foundation
import Testing
import Darwin
import NeSpatPrivilegeCore
@testable import NeSpatLiveTestCore

let healthy = PowerSafetySnapshot(batteryPercent: 80, externalPowerConnected: true, temperatureC: 35, thermalSerious: false)
final class MemoryStore: LiveStoring {
    var record: LiveRecord
    var busy = false
    init(_ r: LiveRecord) { record = r }
    func exclusive<T>(_ body: () throws -> T) throws -> T { guard !busy else { throw LiveError.busy }; busy = true; defer { busy = false }; return try body() }
    func load() throws -> LiveRecord { try record.validate(); return record }
    func save(_ r: LiveRecord, replacing: LiveRecord) throws -> LiveRecord {
        guard record == replacing else { throw LiveError.state }
        var next = r; next.generation += 1; try next.validate()
        guard r.binding == record.binding, r.session == record.session,
              record.issued == nil || (r.expires == record.expires && r.issued == record.issued && r.owner == record.owner) else { throw LiveError.denied }
        record = next; return next
    }
}
final class MockBackend: LiveBackend {
    var sample: LiveReadings
    var busy = false, applies = true, exitCode: Int32 = 0
    var calls: [LivePlan] = []
    var onExecute: (() throws -> Void)?
    var manualAllowed = false
    var manualSession: UUID?
    var onAuthorize: ((LiveManualRequest) throws -> LiveManualApproval)?
    var authorizationRequests: [UUID] = []
    func authorizeManualRecovery(_ request: LiveManualRequest) throws -> LiveManualApproval {
        authorizationRequests.append(request.id)
        if let onAuthorize { return try onAuthorize(request) }
        guard manualAllowed, manualSession == request.record.session else { throw LiveError.denied }
        return LiveManualApproval(request: request)
    }
    init(boot: UUID) { sample = LiveReadings(boot: boot, continuous: 10, power: .enabled, safety: healthy, lidOpen: true, helperAlive: true, recoveryAdmission: LiveRecoveryAdmission(boot: boot, owner: nil, notBefore: 0), foreignInterference: false) }
    var onRead: (() -> Void)?
    func readings() -> LiveReadings { onRead?(); return sample }
    func withSetterLock<T>(_ body: () throws -> T) throws -> T { guard !busy else { throw LiveError.busy }; busy = true; defer { busy = false }; return try body() }
    func execute(_ plan: LivePlan) throws -> Int32 {
        calls.append(plan); try onExecute?()
        if applies { sample.power = plan == .activate ? .disabled : .enabled }; return exitCode
    }
}
final class Rig {
    let binding: LiveBinding
    let store: MemoryStore
    let backend: MockBackend
    let client: LivePeer, helper: LivePeer, watcher: LivePeer
    init() {
        let boot = UUID()
        binding = LiveBinding(authorization: UUID(), boot: boot, session: UUID(), uid: 501, exclusiveControl: true, clientHash: "client", helperHash: "helper", recoveryHash: "watcher")
        store = MemoryStore(LiveRecord(version: 2, binding: binding, session: binding.session)); backend = MockBackend(boot: boot)
        client = LivePeer(role: .client, uid: 501, pid: 10, started: 1, codeHash: "client", signingID: LiveTestDeployment.clientID)
        helper = LivePeer(role: .helper, uid: 0, pid: 20, started: 1, codeHash: "helper", signingID: LiveTestDeployment.helperID)
        watcher = LivePeer(role: .recovery, uid: 0, pid: 30, started: 1, codeHash: "watcher", signingID: LiveTestDeployment.watchdogID)
    }
    var control: LiveController { LiveController(store: store, backend: backend, actor: helper) }
    var recovery: LiveController { LiveController(store: store, backend: backend, actor: watcher) }
    func arm(_ duration: Double = 120) throws { try control.arm(client: client, duration: duration) }
}

@Suite struct LiveGrantTests {
    @Test(arguments: [121.0, 43200, .infinity, .nan, 0, -1]) func overLimitOrInvalidNeverConsumesOrExecutes(_ duration: Double) {
        let f = Rig()
        #expect(throws: (any Error).self) { try f.arm(duration) }
        #expect(!f.store.record.consumed && f.backend.calls.isEmpty)
    }
    @Test func productionLimitPreservedAndNoProductionNamespace() {
        #expect(FullGrantLifetimePolicy.productionMaximumLifetime == 43200)
        #expect(!LiveTestDeployment.rootDeploymentPermitted)
        #expect(LiveTestDeployment.clientID != SigningPolicy.guiIdentifier)
        #expect(LiveTestDeployment.helperID != SigningPolicy.helperIdentifier)
    }
    @Test func extensionGUIAndHelperRestartNeverSlideDeadline() throws {
        let f = Rig(); try f.arm(); let expires = f.store.record.expires
        let replacement = LivePeer(role: .client, uid: 501, pid: 99, started: 2, codeHash: "client", signingID: LiveTestDeployment.clientID)
        #expect(throws: (any Error).self) { try f.control.extend(client: replacement, duration: 120) }
        #expect(throws: (any Error).self) { try f.control.arm(client: replacement, duration: 120) }
        #expect(f.store.record.expires == expires && f.backend.calls == [.activate])
    }
    @Test func noRepeatArmEvenAfterCompletion() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130; try f.recovery.poll()
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(f.store.record.phase == .completed)
    }
    @Test func autoArmAndProductionOrForgedClientAlwaysDenied() {
        let f = Rig()
        #expect(throws: (any Error).self) { try f.control.autoArm() }
        for id in [SigningPolicy.guiIdentifier, "forged"] {
            let peer = LivePeer(role: .client, uid: 501, pid: 10, started: 1, codeHash: "client", signingID: id)
            #expect(throws: (any Error).self) { try f.control.arm(client: peer, duration: 120) }
        }
        let substituted = LivePeer(role: .client, uid: 501, pid: 10, started: 1, codeHash: "substituted", signingID: LiveTestDeployment.clientID)
        #expect(throws: (any Error).self) { try f.control.arm(client: substituted, duration: 120) }
        #expect(f.backend.calls.isEmpty)
    }
    @Test(arguments: [0, 1, 2, 3]) func unknownSensorsOrMissingACOpenLidBlock(_ condition: Int) {
        let f = Rig()
        switch condition { case 0: f.backend.sample.safety = PowerSafetySnapshot(); case 1: f.backend.sample.lidOpen = nil; case 2: f.backend.sample.lidOpen = false; default: f.backend.sample.safety = PowerSafetySnapshot(batteryPercent: 80, externalPowerConnected: false, temperatureC: 35, thermalSerious: false) }
        #expect(throws: (any Error).self) { try f.arm() }; #expect(f.backend.calls.isEmpty)
    }
}

@Suite struct LiveRecoveryTests {
    @Test func failedCommandRetainsFailureUntilIndependentSafeObservation() throws {
        let f = Rig()
        try f.arm()
        f.backend.sample.continuous = 130
        f.backend.exitCode = 7
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.failedAttempts == 1)
        #expect(f.store.record.phase == .recovery)
        try f.recovery.poll()
        #expect(f.store.record.phase == .completed)
        #expect(f.backend.calls == [.activate, .restore])
    }
    @Test func independentControllerStartsAtExpiryAndDoesNotClaimEarlySuccess() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 129
        try f.recovery.poll(); #expect(f.backend.calls == [.activate])
        f.backend.sample.continuous = 130; try f.recovery.poll()
        #expect(f.store.record.initiated == 130 && f.store.record.phase == .completed)
        #expect(f.backend.sample.power == .enabled && f.backend.calls == [.activate, .restore])
        try f.recovery.poll(); #expect(f.backend.calls.count == 2)
    }
    @Test func helperDeathAndNewWatchdogUsePersistedObligation() throws {
        let f = Rig(); try f.arm(); f.backend.sample.helperAlive = false
        try f.recovery.poll()
        #expect(f.store.record.retired && f.store.record.phase == .completed)
        try f.recovery.poll(); #expect(f.backend.calls.count == 2)
    }
    @Test func occupiedLockRecordsInitiationButNotSetterAttempt() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130; f.backend.busy = true
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.initiated == 130 && f.store.record.retired && f.store.record.retry == nil)
        f.backend.busy = false; try f.recovery.poll(); #expect(f.store.record.phase == .completed)
    }
    @Test func ordinaryCooldownSurvivesWatchdogRestartAndMayDelayActualRestoreBeyond120() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 20; f.backend.applies = false
        #expect(throws: (any Error).self) { try f.recovery.poll(forceOwnRecovery: true) }
        f.backend.sample.continuous = 130
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.retired && f.backend.calls == [.activate, .restore])
        f.backend.sample.continuous = 319
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        f.backend.applies = true; f.backend.sample.continuous = 320; try f.recovery.poll()
        #expect(f.store.record.phase == .completed && f.backend.calls == [.activate, .restore, .restore])
    }
    @Test(arguments: [0, 1, 2]) func emergencyAndSensorLossKeepThirtySecondRetry(_ condition: Int) throws {
        let f = Rig(); try f.arm(); f.backend.applies = false
        switch condition { case 0: f.backend.sample.safety = PowerSafetySnapshot(batteryPercent: 80, externalPowerConnected: true, temperatureC: 100, thermalSerious: false)
        case 1: f.backend.sample.safety = PowerSafetySnapshot(batteryPercent: 5, externalPowerConnected: false, temperatureC: 35, thermalSerious: false)
        default: f.backend.sample.safety = PowerSafetySnapshot() }
        #expect(throws: (any Error).self) { try f.recovery.poll() }; #expect(f.store.record.retired)
        f.backend.sample.continuous = 39
        #expect(throws: (any Error).self) { try f.recovery.poll() }; #expect(f.backend.calls.count == 2)
        f.backend.sample.continuous = 40; f.backend.applies = true; try f.recovery.poll(); #expect(f.backend.calls.count == 3)
    }
    @Test func noExitZeroOnlyRestorationAndExternalNoClearsWithoutSetter() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130; f.backend.applies = false
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.sample.power == .disabled && f.store.record.phase != .completed)
        f.backend.sample.power = .enabled; try f.recovery.poll()
        #expect(f.store.record.phase == .completed && f.backend.calls.count == 2)
    }
    @Test func durableRecoveryReservationBeforeSetterSurvivesCrash() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130
        f.backend.onExecute = { throw LiveError.state }
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.retry != nil && f.store.record.phase == .recovery)
        f.backend.onExecute = nil; f.backend.sample.continuous = 131
        #expect(throws: (any Error).self) { try f.recovery.poll() }; #expect(f.backend.calls.count == 2)
    }
    @Test func pendingYesWithoutOwnAttemptStaysBlocked() throws {
        let f = Rig()
        f.backend.onExecute = { f.backend.sample.power = .disabled; throw LiveError.state }
        #expect(throws: (any Error).self) { try f.arm() }
        f.backend.onExecute = nil; f.backend.sample.continuous = 130
        f.store.record.attempt = nil
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.phase == .activationReserved && f.store.record.initiated == 130 && f.backend.calls.count == 1)
    }
    @Test func foreignOwnershipBootOrClockNeverRestores() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130
        let wrong = LivePeer(role: .recovery, uid: 0, pid: 99, started: 1, codeHash: "other", signingID: LiveTestDeployment.watchdogID)
        #expect(throws: (any Error).self) { try LiveController(store: f.store, backend: f.backend, actor: wrong).poll() }
        f.backend.sample.boot = UUID(); #expect(throws: (any Error).self) { try f.recovery.poll() }
        f.backend.sample.boot = f.binding.boot; f.backend.sample.continuous = .nan
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        f.backend.sample.continuous = 9; #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls == [.activate])
    }
    @Test func watchdogLowerBoundaryCannotActivateOrChangeOtherSettings() throws {
        let f = Rig()
        #expect(throws: (any Error).self) { try f.recovery.backend.execute(.activate) }
        #expect(throws: (any Error).self) { try f.recovery.arm(client: f.client, duration: 1) }
        #expect(LivePlan(rawValue: "sleepnow") == nil && LivePlan(rawValue: "displaysleep") == nil)
        #expect(f.backend.calls.isEmpty)
    }
    @Test func emergencyFirstAttemptPreemptsOrdinaryWaitOnceThenKeepsThirtySeconds() throws {
        let f = Rig(); try f.arm(); f.backend.applies = false
        #expect(throws: (any Error).self) { try f.recovery.poll(forceOwnRecovery: true) }
        f.backend.sample.continuous = 11; f.backend.sample.safety = PowerSafetySnapshot()
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls.count == 3)
        f.backend.sample.continuous = 40
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls.count == 3)
        f.backend.sample.continuous = 41; f.backend.applies = true; try f.recovery.poll()
        #expect(f.backend.calls.count == 4)
    }
    @Test func foreignSessionAndOwnerDoNotReachSetter() throws {
        let f = Rig(); try f.arm()
        let r = f.store.record
        f.store.record = LiveRecord(version: 2, binding: r.binding, session: UUID())
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        f.store.record = r
        f.store.record.owner = LivePeer(role: .client, uid: 502, pid: 10, started: 1, codeHash: "client", signingID: LiveTestDeployment.clientID)
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls == [.activate])
    }
    @Test(arguments: [0, 1, 2, 3]) func contradictoryPersistentPhasesStop(_ variant: Int) throws {
        let f = Rig(); try f.arm()
        switch variant {
        case 0: f.store.record.phase = .recovery // Missing durable reservation.
        case 1: f.store.record.phase = .completed // No recovery initiation / confirmation.
        case 2: f.store.record.retired = true // Missing initiation.
        default: f.store.record.lastClock = 0 // Before issuance.
        }
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls == [.activate])
    }
}
