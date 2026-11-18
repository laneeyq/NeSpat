import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct ExclusiveRecoveryTests {
    struct Rig {
        let f = PrivilegeFixture()
        let policy: ExclusivePolicy
        let peer: Peer
        init(selectedLifetime: Bool = false) throws {
            policy = try ExclusivePolicy(setup: UUID(), uid: 501, clientRequirement: "pinned", maximum: 120,
                helperEpoch: UUID(), selectedLifetime: selectedLifetime, canArm: { true })
            peer = Peer(connection: UUID(), uid: 501, auditSession: 3, codeIdentity: "pinned",
                process: OwnerProcessStamp(pid: 100, uid: 501, startSeconds: 100, startMicroseconds: 1, bootID: f.boot))
        }
        func engine(reading: @escaping () -> PowerSafetySnapshot = { fixtureSafetySnapshot }, sleep: (() -> Void)? = nil) -> PrivilegeEngine {
            let f = self.f
            return PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime },
                observe: { f.state }, setDisabled: { disabled in
                    f.changes.append(disabled)
                    if f.apply { f.state = disabled ? .disabled : .enabled }
                    if f.failSetter { throw PrivilegeError.unconfirmed }
                }, ownerLiveness: { _ in .active }, fullGrantPolicy: try! FullGrantLifetimePolicy(maximumLifetime: 120),
                heartbeatPolicy: policy.selectedLifetime ? try! HeartbeatPolicy(timeout: 20) : nil, safetySnapshot: reading, retryClock: { f.uptime },
                exclusivePolicy: policy, requestEmergencySleep: sleep, canFinalizePending: { true })
        }
        func begin(_ engine: PrivilegeEngine, minutes: Int? = 1) throws {
            let approval = FreshAuthorization(trustedConsentFor: try engine.enrollmentChallenge(for: peer), confirmedAt: f.uptime, expires: f.uptime + 120)
            try engine.admit(peer, authorization: .fresh(approval))
            _ = try engine.handle(Request(operation: .begin, minutes: minutes), from: peer)
        }
    }
    @Test(arguments: [nil, 1000] as [Int?])
    func selectedDurationSurvivesOldLimitsAndStops(minutes: Int?) throws {
        let r = try Rig(selectedLifetime: true), engine = r.engine(), watch = r.engine()
        try r.begin(engine, minutes: minutes)
        let record = try #require(r.f.journal.record)
        #expect(record.deadline == minutes.map { r.f.wall.addingTimeInterval(Double($0 * 60)) })
        for sequence in 1...4500 {
            r.f.uptime += 10; r.f.wall.addTimeInterval(10)
            let heartbeat = Request(operation: .heartbeat, session: record.id, heartbeatSequence: sequence)
            _ = try engine.handle(heartbeat, from: r.peer)
            if sequence == 4500 {
                #expect(throws: PrivilegeError.replay) { try engine.handle(heartbeat, from: r.peer) }
            }
        }
        try engine.tick()
        try watch.independentPoll(helperEpoch: r.policy.helperEpoch, emergency: false, externalPower: true)
        #expect(r.f.state == .disabled)
        if minutes != nil {
            r.f.uptime += 15000; r.f.wall.addTimeInterval(15000)
            try watch.independentPoll(helperEpoch: r.policy.helperEpoch, emergency: false, externalPower: true)
        } else {
            _ = try engine.handle(Request(operation: .pollRecovery, session: record.id), from: r.peer)
        }
        #expect(r.f.state == .enabled && r.f.changes == [true, false])
    }
    @Test(arguments: [false, true], [0, 1, 2, 3])
    func unplugContinuesAndOnlyConfirmedDangerRequestsSleep(watchFirst: Bool, hazard: Int) throws {
        let rig = try Rig(selectedLifetime: true)
        var sample = PowerSafetySnapshot(batteryPercent: 70, externalPowerConnected: true, temperatureC: 35, thermalSerious: false)
        var sleeps = 0
        let sleep = {
            #expect(rig.f.state == .enabled && rig.f.journal.record == nil)
            sleeps += 1
        }
        let helper = rig.engine(reading: { sample }, sleep: sleep)
        let watch = rig.engine(reading: { sample }, sleep: sleep)
        try rig.begin(helper, minutes: 180)
        let original = try #require(rig.f.journal.record)
        sample = .init(batteryPercent: 70, externalPowerConnected: false, temperatureC: 35, thermalSerious: false)
        try watch.independentPoll(helperEpoch: rig.policy.helperEpoch, emergency: false, externalPower: false)
        try helper.tick()
        #expect(rig.f.journal.record == original && rig.f.changes == [true] && sleeps == 0)
        sample = hazard == 3 ? .init() : .init(batteryPercent: hazard == 0 ? 10 : 70, externalPowerConnected: false,
                                               temperatureC: hazard == 1 ? 95 : 35, thermalSerious: hazard == 2)
        if !watchFirst { try helper.tick() }
        try watch.independentPoll(helperEpoch: rig.policy.helperEpoch, emergency: true, externalPower: false)
        try watch.independentPoll(helperEpoch: rig.policy.helperEpoch, emergency: true, externalPower: false)
        #expect(rig.f.changes == [true, false] && sleeps == (hazard == 3 ? 0 : 1))
    }
    @Test func watchdogRestoresUnlimitedOnDanger() throws {
        let r = try Rig(selectedLifetime: true), engine = r.engine()
        try r.begin(engine, minutes: nil)
        try r.engine().independentPoll(helperEpoch: r.policy.helperEpoch, emergency: true, externalPower: true)
        #expect(r.f.state == .enabled && r.f.journal.record == nil)
    }
    @Test func afterSetterCrashIndependentOwnerRecoversOnce() throws {
        let r = try Rig(), helper = r.engine()
        r.f.failSetter = true
        #expect(throws: PrivilegeError.unconfirmed) { try r.begin(helper) }
        let record = try #require(r.f.journal.record)
        #expect(record.phase == .pending && record.exclusiveAttempt?.session == record.id)
        r.f.failSetter = false
        let watchdog = r.engine()
        try watchdog.independentPoll(helperEpoch: nil, emergency: false)
        try watchdog.independentPoll(helperEpoch: nil, emergency: false)
        #expect(r.f.state == .enabled && r.f.journal.record == nil && r.f.changes == [true,false])
    }
    @Test(arguments: [0,1,2,3]) func damagedOrForeignYesCannotBeReset(_ change: Int) throws {
        let r = try Rig(); try r.begin(r.engine())
        switch change {
        case 0: r.f.journal.record?.exclusiveAttempt = nil
        case 1: r.f.journal.record?.interference = true
        case 2: r.f.journal.record?.id = UUID()
        default: r.f.journal.record?.authorityExpires = 999
        }
        #expect(throws: (any Error).self) { try r.engine().independentPoll(helperEpoch: nil, emergency: false) }
        #expect(r.f.journal.record != nil && r.f.changes == [true])
    }
    @Test func liveHelperHonorsDeadlineAndIndependentRetryBudget() throws {
        let r = try Rig(); try r.begin(r.engine())
        let watch = r.engine()
        try watch.independentPoll(helperEpoch: r.policy.helperEpoch, emergency: false, externalPower: true)
        #expect(r.f.changes == [true])
        r.f.uptime += 61; r.f.wall.addTimeInterval(61); r.f.apply = false
        #expect(throws: PrivilegeError.unconfirmed) { try watch.independentPoll(helperEpoch: r.policy.helperEpoch, emergency: false, externalPower: true) }
        try r.engine().independentPoll(helperEpoch: nil, emergency: false, externalPower: true)
        #expect(r.f.changes == [true,false] && r.f.journal.retry != nil)
        r.f.uptime += 300; r.f.apply = true
        try r.engine().independentPoll(helperEpoch: nil, emergency: false, externalPower: true)
        #expect(r.f.state == .enabled && r.f.journal.record == nil)
    }
}
