import Foundation
import NeSpatPrivilegeCore

/// Different namespace and authority; no production listener/client imports this module.
public enum LiveTestDeployment {
    public static let helperID = "local.nespat.live-test.helper"
    public static let watchdogID = "local.nespat.live-test.recovery"
    public static let clientID = "local.nespat.live-test.client"
    public static let maximumGrant: Double = 120
    // Root deployment and a real power adapter remain outside the rootless fixture.
    // Neither config, environment nor RPC can enable deployment or real power I/O.
    public static let rootDeploymentPermitted = false
}
enum LiveError: Error { case denied, duration, spent, state, clock, busy, pendingOwnership, cooldown }
enum LiveRole: String, Codable { case client, helper, recovery }
struct LivePeer: Codable, Equatable {
    let role: LiveRole
    let uid: UInt32
    let pid: Int32
    let started: UInt64
    let codeHash: String
    let signingID: String
}
struct LiveBinding: Codable, Equatable {
    let authorization: UUID // Separately provisioned one-shot admin authority, never client chosen.
    let boot: UUID
    let session: UUID // Pinned outside the mutable aggregate, same as boot/authorization.
    let uid: UInt32
    let exclusiveControl: Bool // Trusted setup only: approved test-only single-writer assumption.
    let clientHash: String
    let helperHash: String
    let recoveryHash: String
    func verify(_ p: LivePeer, role: LiveRole) throws {
        let id = role == .client ? LiveTestDeployment.clientID : role == .helper ? LiveTestDeployment.helperID : LiveTestDeployment.watchdogID
        let hash = role == .client ? clientHash : role == .helper ? helperHash : recoveryHash
        guard p.role == role, p.signingID == id, p.codeHash == hash,
              p.pid > 0, p.started > 0, p.uid == (role == .client ? uid : 0) else { throw LiveError.denied }
    }
}
enum LivePhase: String, Codable { case unused, activationReserved, active, recovery, completed }
struct LiveRetry: Codable, Equatable {
    var since: Double
    var last: Double
    var emergency: Bool
    let nonce: UUID
}
struct LiveAttempt: Codable, Equatable {
    let session: UUID
    let helper: LivePeer
    let client: LivePeer
    let at: Double
    let nonce: UUID
}
/// Trusted backend view of the shared recovery domain, never an RPC argument.
struct LiveRecoveryAdmission: Codable, Equatable {
    let boot: UUID
    let owner: UUID?
    let notBefore: Double
}
struct LiveRecord: Codable, Equatable {
    let version: Int
    let binding: LiveBinding
    let session: UUID
    var generation: UInt64 = 1
    var phase: LivePhase = .unused
    var owner: LivePeer?
    var issued: Double?
    var expires: Double?
    var lastClock: Double = 0
    var retired = false
    var initiated: Double?
    var retry: LiveRetry?
    var baselineNo: Bool?
    var admission: LiveRecoveryAdmission?
    var attempt: LiveAttempt?
    var interferenceDetected = false
    var failedAttempts: UInt64 = 0
    var lastFailure: Double?
    var consumed: Bool { phase != .unused }
    func validate() throws {
        guard session == binding.session, binding.uid > 0, version == 2, generation > 0, lastClock.isFinite, lastClock >= 0 else { throw LiveError.state }
        if consumed {
            guard let issued, let expires, let owner, issued.isFinite, expires.isFinite,
                  issued >= 0, issued <= lastClock, expires > issued, expires-issued <= 120 else { throw LiveError.state }
            try binding.verify(owner, role: .client)
            guard binding.exclusiveControl, baselineNo == true, let admission,
                  admission.boot == binding.boot, admission.owner == nil,
                  admission.notBefore.isFinite, admission.notBefore >= 0, admission.notBefore <= issued else { throw LiveError.state }
            if let attempt {
                try binding.verify(attempt.helper, role: .helper)
                guard attempt.session == session, attempt.client == owner, attempt.at.isFinite,
                      attempt.at >= issued, attempt.at < expires, attempt.at <= lastClock else { throw LiveError.state }
            }
            guard (phase != .active && phase != .recovery) || attempt != nil else { throw LiveError.pendingOwnership }
        } else {
            guard owner == nil, issued == nil, expires == nil, retry == nil, baselineNo == nil, admission == nil, attempt == nil, failedAttempts == 0, lastFailure == nil,
                  !retired, initiated == nil, lastClock == 0 else { throw LiveError.state }
            return
        }
        guard retired == (initiated != nil), (phase == .recovery) == (retry != nil),
              phase != .completed || retired else { throw LiveError.state }
        guard (failedAttempts == 0) == (lastFailure == nil) else { throw LiveError.state }
        if let lastFailure { guard lastFailure.isFinite, lastFailure >= 0, lastFailure <= lastClock else { throw LiveError.state } }
        if let retry { guard retry.since.isFinite, retry.last.isFinite, retry.since >= 0, retry.last >= retry.since, retry.last <= lastClock else { throw LiveError.state } }
        if let initiated { guard initiated.isFinite, initiated >= 0, initiated <= lastClock else { throw LiveError.state } }
    }
}
/// Per-operation challenge. The complete immutable snapshot prevents authorization adoption.
struct LiveManualRequest: Equatable {
    let id: UUID
    let client: LivePeer
    let record: LiveRecord
}
struct LiveManualApproval: Equatable {
    let request: LiveManualRequest
}
enum LivePlan: String { case activate, restore }
struct LiveReadings {
    var boot: UUID
    var continuous: Double
    var power: ObservedSleep
    var safety: PowerSafetySnapshot
    var lidOpen: Bool?
    var helperAlive: Bool?
    var recoveryAdmission: LiveRecoveryAdmission? = nil
    var foreignInterference: Bool? = nil // Unknown is STOP; false is valid only under approved test model.
}
protocol LiveBackend: AnyObject {
    func readings() -> LiveReadings
    func withSetterLock<T>(_ body: () throws -> T) throws -> T
    /// Result is command exit status, NOT confirmation of actual power state.
    func execute(_ plan: LivePlan) throws -> Int32
    func authorizeManualRecovery(_ request: LiveManualRequest) throws -> LiveManualApproval
}
extension LiveBackend {
    func authorizeManualRecovery(_ request: LiveManualRequest) throws -> LiveManualApproval { throw LiveError.denied }
}
protocol LiveStoring: AnyObject {
    func exclusive<T>(_ body: () throws -> T) throws -> T
    func load() throws -> LiveRecord
    func save(_ record: LiveRecord, replacing: LiveRecord) throws -> LiveRecord
}

final class RecoveryOnlyBackend: LiveBackend {
    let wrapped: any LiveBackend
    init(_ wrapped: any LiveBackend) { self.wrapped = wrapped }
    func readings() -> LiveReadings { wrapped.readings() }
    func withSetterLock<T>(_ body: () throws -> T) throws -> T { try wrapped.withSetterLock(body) }
    func authorizeManualRecovery(_ request: LiveManualRequest) throws -> LiveManualApproval { try wrapped.authorizeManualRecovery(request) }
    func execute(_ plan: LivePlan) throws -> Int32 {
        guard plan == .restore else { throw LiveError.denied }
        return try wrapped.execute(plan)
    }
}
