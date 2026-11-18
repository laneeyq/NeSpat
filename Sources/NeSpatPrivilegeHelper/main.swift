import Foundation
import Darwin
import IOKit.pwr_mgt
import NeSpatPrivilegeCore

// Default invocation remains inert. Only an explicitly installed/approved local daemon
// profile and root launch may enter the service; tests never pass --serve-local.
let manual = CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--approved-recovery"
guard manual || (CommandLine.arguments.count == 2 && ["--serve-local", "--watch-exclusive", "--check-local", "--check-removable"].contains(CommandLine.arguments[1])), geteuid() == 0 else {
    FileHandle.standardError.write(Data(("Local setup required; helper was not started.\n").utf8)); exit(78)
}
do {
    let profile = try LocalTrustProfile.load()
    let helper = URL(fileURLWithPath: LocalTrustProfile.appPath + "/Contents/Library/Helpers/NeSpatPrivilegeHelper")
    guard URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL == helper,
          profile.helperPin.matchesHardenedFile(helper), profile.guiPin.matchesHardenedFile(URL(fileURLWithPath: LocalTrustProfile.appPath)),
          let boot = SystemBootIdentity.read() else { throw PrivilegeError.blocked }
    let sampler = StatsSampler()
    if CommandLine.arguments[1] == "--check-local" {
        let sample = sampler.sample()
        let idle = LocalFixedPowerInvoker.inspectIdle()
        print("root read-only preflight: battery=\(sample.batteryLevel != nil), AC=\(sample.externalPowerConnected != nil), temperature=\(sample.temperatureC != nil), thermal=\(ProcessInfo.processInfo.thermalState.rawValue), sleep=\(SystemSleepObservation.read().rawValue), boot=true, setupEnabled=\(profile.currentlyEnabled), setterIdle=\(idle)")
        let thermal: Bool?
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: thermal = false
        case .serious, .critical: thermal = true
        @unknown default: thermal = nil
        }
        let safe = PowerSafetySnapshot(batteryPercent: sample.batteryLevel, externalPowerConnected: sample.externalPowerConnected,
            temperatureC: sample.temperatureC, thermalSerious: thermal).activationAssessment == .noDangerDetected
        exit(safe && idle && SystemSleepObservation.read() == .enabled && RecoveryPolicy.continuousSeconds().isFinite ? 0 : 2)
    }
    guard profile.exclusiveControl else { throw PrivilegeError.blocked }
    let journal = try ProtectedJournal.openSystemJournal(requireProvisioned: true)
    let invoker = try LocalFixedPowerInvoker()
    let watcher = CommandLine.arguments[1] == "--watch-exclusive"
    let epoch = UUID()
    let policy = try ExclusivePolicy(setup: profile.setupID, uid: profile.allowedUID,
        clientRequirement: profile.guiPin.requirement, maximum: profile.maximum, helperEpoch: epoch, selectedLifetime: profile.selectedLifetime,
        canArm: {
            guard !watcher, profile.currentlyEnabled, SystemSessionObservation.lidClosed() == false,
                  ServicePulse.current(.watchdog, boot: boot, setup: profile.setupID) != nil,
                  SystemSessionObservation.activeUID() == profile.allowedUID else { return false }
            return true
        })
    func safety() -> PowerSafetySnapshot {
        guard (watcher || ServicePulse.current(.watchdog, boot: boot, setup: profile.setupID) != nil),
              SystemSessionObservation.activeUID() == profile.allowedUID,
              SystemSessionObservation.lidClosed() != nil else { return PowerSafetySnapshot() }
        let sample = sampler.sample()
        let thermal: Bool?
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: thermal = false
        case .serious, .critical: thermal = true
        @unknown default: thermal = nil
        }
        return PowerSafetySnapshot(batteryPercent: sample.batteryLevel, externalPowerConnected: sample.externalPowerConnected,
            temperatureC: sample.temperatureC, thermalSerious: thermal)
    }
    let engine = PrivilegeEngine(journal: journal, boot: boot, now: Date.init,
        monotonic: RecoveryPolicy.continuousSeconds, observe: SystemSleepObservation.read,
        setDisabled: { disabled in
            if disabled {
                guard !watcher, policy.canArm(), safety().activationAssessment == .noDangerDetected,
                      profile.permitsTrialSource(safety().externalPowerConnected) else { throw PrivilegeError.denied }
            }
            try invoker.setDisabled(disabled)
        }, ownerLiveness: SystemOwnerLiveness.read,
        fullGrantPolicy: try FullGrantLifetimePolicy(maximumLifetime: profile.maximum),
        heartbeatPolicy: try HeartbeatPolicy(timeout: 20), safetySnapshot: safety,
        exclusivePolicy: policy, requestEmergencySleep: profile.trialOnly ? nil : {
            guard profile.currentlyEnabled else { return }
            let connection = IOPMFindPowerManagement(0)
            guard connection != 0 else {
                NSLog("NeSpat: power management unavailable for emergency sleep")
                return
            }
            defer { IOServiceClose(connection) }
            let result = IOPMSleepSystem(connection)
            if result != kIOReturnSuccess { NSLog("NeSpat: emergency sleep request failed (%d)", result) }
        }, canFinalizePending: invoker.canFinalizePending)
    if manual {
        guard let id = UUID(uuidString: CommandLine.arguments[2]), CommandLine.arguments[3].utf8.count == 64 else { throw PrivilegeError.denied }
        try engine.approvedRecovery(session: id, ticket: CommandLine.arguments[3])
        guard try engine.canRemoveOrUpdate(), SystemSleepObservation.read() == .enabled else { throw PrivilegeError.unconfirmed }
        print("Verified ordinary sleep")
        exit(0)
    }
    if CommandLine.arguments[1] == "--check-removable" {
        guard !profile.currentlyEnabled, try engine.canRemoveOrUpdate(), invoker.canFinalizePending() else { throw PrivilegeError.blocked }
        print("ordinary sleep confirmed; no recovery obligation; setter idle")
        exit(0)
    }
    if watcher {
        while true {
            do {
                let sample = safety()
                try engine.independentPoll(helperEpoch: ServicePulse.current(.helper, boot: boot, setup: profile.setupID)?.epoch,
                    emergency: !profile.currentlyEnabled || sample.emergencyAssessment != .noDangerDetected ||
                        !profile.permitsTrialSource(sample.externalPowerConnected), externalPower: sample.externalPowerConnected)
                try ServicePulse.publish(.watchdog, epoch: epoch, boot: boot, setup: profile.setupID)
            } catch {
                FileHandle.standardError.write(Data("Independent recovery pending: \(error)\n".utf8))
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
    let delegate = try PrivilegeListener(localProfile: profile, engine: engine)
    let listener = try delegate.preparedListener()
    listener.activate()
    try ServicePulse.publish(.helper, epoch: epoch, boot: boot, setup: profile.setupID)
    let pulse = DispatchSource.makeTimerSource()
    pulse.schedule(deadline: .now(), repeating: .seconds(1))
    pulse.setEventHandler { try? ServicePulse.publish(.helper, epoch: epoch, boot: boot, setup: profile.setupID) }
    pulse.resume()
    let watchdog = HelperWatchdog(engine: engine)
    Task { try? await watchdog.run(every: .seconds(5)) }
    withExtendedLifetime((delegate, listener, invoker, pulse)) { RunLoop.main.run() }
} catch {
    FileHandle.standardError.write(Data("Local helper preflight failed; no service started.\n".utf8)); exit(78)
}
