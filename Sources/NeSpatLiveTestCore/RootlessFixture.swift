import Foundation
import Darwin
import NeSpatPrivilegeCore

/// Explicit unprivileged process fixture, not a deployable root/watchdog entrypoint.
/// No real power conformer is linked. Root refuses fixture paths, even if caller supplies them.
public enum RootlessLiveFixture {
    public static func run(directory: String, boot: String, continuous: Double, arm: Bool, crashBefore: Bool = false, crashAfter: Bool = false, failRestore: Bool = false, watch: Bool = false, manual: Bool = false) throws {
        guard geteuid() != 0, let id = UUID(uuidString: boot) else { throw LiveError.denied }
        let url = URL(fileURLWithPath: directory)
        let marker = try Data(contentsOf: url.appendingPathComponent("fixture-only"))
        guard marker == Data("rootless-no-power-v1".utf8) else { throw LiveError.denied }
        guard let session = UUID(uuidString: try String(contentsOf: url.appendingPathComponent("fixture-session"), encoding: .utf8)) else { throw LiveError.state }
        let binding = LiveBinding(authorization: id, boot: id, session: session, uid: getuid(), exclusiveControl: true, clientHash: "fixture-client", helperHash: "fixture-helper", recoveryHash: "fixture-recovery")
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw LiveError.state }; defer { close(fd) }
        let store = try LiveFileStore(pinnedDirectory: fd, uid: getuid(), expected: binding)
        let backend = FileMockBackend(url: url, boot: id, continuous: continuous, crashBefore: crashBefore, crashAfter: crashAfter, failRestore: failRestore, liveClock: watch, manual: manual)
        let role: LiveRole = arm ? .helper : .recovery
        let actor = LivePeer(role: role, uid: 0, pid: getpid(), started: 1,
            codeHash: arm ? binding.helperHash : binding.recoveryHash,
            signingID: arm ? LiveTestDeployment.helperID : LiveTestDeployment.watchdogID)
        let controller = LiveController(store: store, backend: backend, actor: actor)
        if arm {
            let client = LivePeer(role: .client, uid: getuid(), pid: getpid(), started: 1, codeHash: binding.clientHash, signingID: LiveTestDeployment.clientID)
            try controller.arm(client: client, duration: 120)
        } else if manual {
            let owner = try store.exclusive { try store.load().owner }
            guard let owner else { throw LiveError.denied }
            try controller.manualRecover(client: owner)
        } else if watch {
            let done = DispatchSemaphore(value: 0)
            let events = LiveRecoveryEvents(directoryFD: fd) {
                do {
                    try controller.poll()
                    if try controller.canRemove() { done.signal() }
                } catch { print("MOCK obligation retained: \(error)") }
            }
            // Main blocks independently of GUI/helper; all polling runs on the event queue.
            // No root deployment, StartInterval or process sleep is involved.
            try Data("ready".utf8).write(to: url.appendingPathComponent("watch-ready"), options: .atomic)
            withExtendedLifetime(events) { done.wait() }
        } else { try controller.poll() }
        try store.exclusive {
            let r = try store.load()
            print("MOCK ONLY phase=\(r.phase.rawValue) expires=\(r.expires ?? -1) initiated=\(r.initiated ?? -1)")
        }
    }
}
private final class FileMockBackend: LiveBackend {
    let url: URL, boot: UUID, continuous: Double
    let crashBefore: Bool, crashAfter: Bool, failRestore: Bool, liveClock: Bool, manual: Bool
    init(url: URL, boot: UUID, continuous: Double, crashBefore: Bool, crashAfter: Bool, failRestore: Bool, liveClock: Bool, manual: Bool) { self.manual = manual; self.liveClock = liveClock; self.url = url; self.boot = boot; self.continuous = continuous; self.crashBefore = crashBefore; self.crashAfter = crashAfter; self.failRestore = failRestore }
    func readings() -> LiveReadings {
        let value = try? String(contentsOf: url.appendingPathComponent("mock-power"), encoding: .utf8)
        let time = liveClock ? (try? String(contentsOf: url.appendingPathComponent("mock-clock"), encoding: .utf8)).flatMap(Double.init) ?? .nan : continuous
        let interference = (try? String(contentsOf: url.appendingPathComponent("mock-interference"), encoding: .utf8)) == "foreign"
        return LiveReadings(boot: boot, continuous: time, power: value == "No" ? .enabled : value == "Yes" ? .disabled : .unknown,
            safety: PowerSafetySnapshot(batteryPercent: 80, externalPowerConnected: true, temperatureC: 35, thermalSerious: false), lidOpen: true, helperAlive: true, recoveryAdmission: LiveRecoveryAdmission(boot: boot, owner: nil, notBefore: 0), foreignInterference: interference)
    }
    func withSetterLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(url.appendingPathComponent("setter.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LiveError.state }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LiveError.busy }
        defer { _ = flock(fd, LOCK_UN) }; return try body()
    }
    private func pauseFixture(_ kind: String) throws {
        try Data("started".utf8).write(to: url.appendingPathComponent("mock-"+kind+"-started"), options: .atomic)
        let end = ProcessInfo.processInfo.systemUptime+5
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-"+kind+"-release").path) {
            guard ProcessInfo.processInfo.systemUptime < end else { throw LiveError.busy }
            Thread.sleep(forTimeInterval: 0.01) // Mock I/O/UI fault injection only.
        }
    }
    func authorizeManualRecovery(_ request: LiveManualRequest) throws -> LiveManualApproval {
        guard manual else { throw LiveError.denied }
        try pauseFixture("auth")
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-auth-cancel").path) { throw LiveError.denied }
        return LiveManualApproval(request: request)
    }
    func execute(_ plan: LivePlan) throws -> Int32 {
        let counter = url.appendingPathComponent("mock-"+plan.rawValue+"-count")
        let count = (try? String(contentsOf: counter, encoding: .utf8)).flatMap(Int.init) ?? 0
        try Data(String(count+1).utf8).write(to: counter, options: .atomic)
        if plan == .restore && FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-hold-restore").path) { try pauseFixture("restore") }
        if crashBefore { _exit(86) }
        // Simulated state file only: NO IOKit mutation, Process, shell or pmset.
        if plan == .restore && (failRestore || FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-fail-restore").path)) { return 0 }
        try Data((plan == .activate ? "Yes" : "No").utf8).write(to: url.appendingPathComponent("mock-power"), options: .atomic)
        if plan == .activate && FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-hold-activation").path) {
            try Data("started".utf8).write(to: url.appendingPathComponent("mock-setter-started"), options: .atomic)
            let end = ProcessInfo.processInfo.systemUptime+5
            // Fault injection of a slow setter, NOT a watchdog timer or a real power operation.
            while !FileManager.default.fileExists(atPath: url.appendingPathComponent("mock-setter-release").path) {
                guard ProcessInfo.processInfo.systemUptime < end else { throw LiveError.busy }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        if crashAfter { _exit(86) }
        return 0
    }
}
