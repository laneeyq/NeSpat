import Foundation
import Darwin
import NeSpatPrivilegeCore

// Separate executable target. The production invoker is not part of its source graph.
let args = CommandLine.arguments
guard args.count == 2 else { exit(64) }
if args[1] == "--preinstall-observe" {
    print(SystemSleepObservation.read() == .enabled ? "ordinary-sleep-confirmed" : "unknown-or-disabled")
    exit(SystemSleepObservation.read() == .enabled ? 0 : 2)
}
if args[1] == "--acceptance-selftest" {
    for value in [false, true] {
        do { try AcceptancePowerBoundary.setDisabled(value); exit(1) }
        catch PrivilegeError.blocked {} catch { exit(2) }
    }
    print("both setter directions denied; no command executor present")
    exit(0)
}
guard ["--serve-acceptance", "--check-local"].contains(args[1]), geteuid() == 0 else { exit(78) }
do {
    let profile = try LocalTrustProfile.load()
    let helper = URL(fileURLWithPath: LocalTrustProfile.appPath + "/Contents/Library/Helpers/NeSpatPrivilegeHelper")
    guard profile.acceptanceOnly, URL(fileURLWithPath: args[0]).standardizedFileURL == helper,
          profile.helperPin.matchesHardenedFile(helper), profile.guiPin.matchesHardenedFile(URL(fileURLWithPath: LocalTrustProfile.appPath)),
          let boot = SystemBootIdentity.read() else { throw PrivilegeError.blocked }
    if args[1] == "--check-local" {
        let safe = SystemSleepObservation.read() == .enabled
        print("acceptance postinstall: protected pins=true, full grants=denied, both setters=denied, ordinarySleep=\(safe)")
        exit(safe ? 0 : 2)
    }
    let engine = PrivilegeEngine(journal: AcceptanceAuthorityJournal(), boot: boot, now: Date.init,
        monotonic: RecoveryPolicy.continuousSeconds, observe: SystemSleepObservation.read,
        setDisabled: AcceptancePowerBoundary.setDisabled, fullGrantPolicy: nil)
    let delegate = try PrivilegeListener(acceptanceProfile: profile, engine: engine)
    let listener = try delegate.preparedListener()
    listener.activate()
    withExtendedLifetime((delegate, listener, engine)) { RunLoop.main.run() }
} catch { exit(78) }
