import Foundation
import NeSpatPrivilegeCore

// The GUI observes and requests; the helper independently samples/authorizes every change.
actor LocalAutomaticBackend: AutomaticSessionBackend {
    private var transport: PrivilegeTransport?
    private var cached: Reply?
    private var lastRPC = -Double.infinity
    private var heartbeatSequence = 0
    private func heartbeatRequest(_ session: UUID) -> Request {
        heartbeatSequence += 1
        return Request(operation: .heartbeat, session: session, heartbeatSequence: cached?.selectedLifetime == true ? heartbeatSequence : nil)
    }
    private var sampler: StatsSampler?
    private func connection() async throws -> PrivilegeTransport {
        if let transport { return transport }
        let profile = try LocalTrustProfile.load()
        guard profile.allowedUID == getuid() else { throw PrivilegeError.blocked }
        let result = try PrivilegeClient.connectLocal(profile: profile)
        try await result.handshake(); transport = result; return result
    }
    private func request(_ request: Request) async throws -> Reply {
        do {
            let result = try await connection().request(request)
            cached = result; lastRPC = RecoveryPolicy.continuousSeconds(); return result
        }
        catch { if let transport { await transport.close() }; transport = nil; cached = nil; throw error }
    }
    func observation() async throws -> AutomaticObservation {
        let time = RecoveryPolicy.continuousSeconds()
        let reply: Reply
        if cached?.session != nil, SystemSleepObservation.read() == .enabled {
            // The watchdog or deadline may have completed the session between GUI polls.
            reply = try await request(Request(operation: .status))
            if reply.session == nil, reply.state == .enabled {
                if let transport { await transport.close() }
                transport = nil
                cached = nil
            }
        } else if let cached, time >= lastRPC, time - lastRPC < 18 { reply = cached }
        else if let cached, cached.fullAuthority == true, let session = cached.session {
            reply = try await request(heartbeatRequest(session))
        } else { reply = try await request(Request(operation: .status)) }
        guard let boot = SystemBootIdentity.read() else { throw PrivilegeError.blocked }
        if sampler == nil { sampler = StatsSampler() }
        let sample = sampler!.sample()
        let thermal: Bool?
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: thermal = false
        case .serious, .critical: thermal = true
        @unknown default: thermal = nil
        }
        let lease: AutomaticLease?
        if reply.active == true, let id = reply.session, (reply.selectedLifetime == true || (reply.deadline != nil && reply.authorityExpires != nil)), (reply.deadline == nil) == (reply.authorityExpires == nil) {
            lease = AutomaticLease(id: id, boot: boot, deadline: reply.deadline, expires: reply.authorityExpires, selectedLifetime: reply.selectedLifetime == true)
        } else { lease = nil }
        var value = AutomaticObservation(serviceVerified: true, setupAuthorized: (try? LocalTrustProfile.load().currentlyEnabled) == true,
            activeUser: SystemSessionObservation.activeUID() == getuid(), lidClosed: SystemSessionObservation.lidClosed(),
            power: SystemSleepObservation.read(), safety: PowerSafetySnapshot(batteryPercent: sample.batteryLevel,
                externalPowerConnected: sample.externalPowerConnected, temperatureC: sample.temperatureC, thermalSerious: thermal),
            lease: lease, foreign: reply.session != nil && lease == nil, boot: boot, wall: Date(), continuous: RecoveryPolicy.continuousSeconds())
        value.recoveryOnly = reply.fullAuthority != true && lease != nil
        return value
    }
    func prearm(maximumSeconds: TimeInterval) async throws {
        guard maximumSeconds == FullGrantLifetimePolicy.productionMaximumLifetime else { throw PrivilegeError.blocked }
        let defaults = UserDefaults.standard
        let selection = defaults.object(forKey: "exclusive.durationChoice") as? Int ?? 60
        let minutes: Int?
        switch selection {
        case 0: minutes = nil
        case -1:
            let input = defaults.string(forKey: "exclusive.customMinutes") ?? "30"
            _ = try CustomDuration.seconds(input)
            minutes = Int(input)
        case 60, 180, 480: minutes = selection
        default: throw PrivilegeError.denied
        }
        _ = try await request(Request(operation: .begin, minutes: minutes))
    }
    func pollRestoration(session: UUID) async throws {
        let result = try await request(Request(operation: .pollRecovery, session: session))
        if result.state == .enabled, result.session == nil {
            if let transport { await transport.close() }; transport = nil
        }
    }
    func manualRecovery(session: UUID) async throws {
        let reply = try await request(Request(operation: .status))
        guard reply.session == session, let ticket = reply.recoveryTicket,
              let profile = try? LocalTrustProfile.load(), profile.exclusiveControl else { throw PrivilegeError.ownership }
        let helper = LocalTrustProfile.appPath + "/Contents/Library/Helpers/NeSpatPrivilegeHelper"
        guard profile.helperPin.matchesHardenedFile(URL(fileURLWithPath: helper)) else { throw PrivilegeError.blocked }
        // Both variable fields were decoded by the strict wire parser (UUID and lowercase SHA-256).
        let command = "'\(helper)' --approved-recovery \(session.uuidString) \(ticket)"
        let result = await Task.detached {
            Proc.run("/usr/bin/osascript", ["-e", "do shell script \"\(command)\" with administrator privileges"])
        }.value
        guard result.ok, SystemSleepObservation.read() == .enabled else { throw PrivilegeError.unconfirmed }
        cached = nil
    }
    func sleepDisplayIfClosed(session: UUID) throws {
        guard cached?.active == true, cached?.fullAuthority == true, cached?.session == session,
              SystemSessionObservation.activeUID() == getuid(),
              SystemSleepObservation.read() == .disabled,
              SystemSessionObservation.lidClosed() == true else { return }
        guard SleepControl.displaysleepnow().ok else { throw PrivilegeError.unconfirmed }
    }
    func heartbeat(session: UUID) async throws {
        let time = RecoveryPolicy.continuousSeconds()
        guard time >= lastRPC, time - lastRPC >= 12 else { return }
        _ = try await request(heartbeatRequest(session))
    }
}
