import NeSpatNative
import Foundation
import Darwin

// Public pins contain no secret. Only an explicit admin setup may provision this fixed,
// root-owned path. No client pathname/hash is auto-trusted or accepted over XPC.
public struct LocalTrustProfile: Sendable {
    public static let appPath = "/Library/Application Support/NeSpatPrivileged/NeSpat.app"
    public static let path = "/Library/Application Support/NeSpatPrivileged/LocalTrust/profile.json"
    private final class Native: @unchecked Sendable {
        // Rust only exposes shared, immutable reads of this profile snapshot.
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { nespat_profile_drop(handle) }
    }
    private let storage: Native
    private let info: NeSpatProfileInfo
    public let guiPin: ExactCodePin
    public let helperPin: ExactCodePin
    public var policy: SigningPolicy { get throws { try SigningPolicy(approvedLocalGUI: guiPin, helper: helperPin) } }
    public var acceptanceOnly: Bool { info.acceptance }
    public var exclusiveControl: Bool { info.exclusive }
    public var setupID: UUID { UUID(uuid: info.setup) }
    public var selectedLifetime: Bool { info.selected }
    public var trialOnly: Bool { info.trial }
    public func permitsTrialSource(_ external: Bool?) -> Bool { !trialOnly || external == !info.on_battery }
    public var maximum: Double { trialOnly ? 120 : FullGrantLifetimePolicy.productionMaximumLifetime }
    public var allowedUID: UInt32 { info.uid }
    public static func load() throws -> Self {
        var info = NeSpatProfileInfo()
        guard let handle = nespat_profile_load(&info) else { throw PrivilegeError.blocked }
        let storage = Native(handle)
        return try Self(storage: storage, info: info,
            guiPin: ExactCodePin(codeDirectoryHash: nespat_profile_hash(handle, false) as String, signingIdentifier: SigningPolicy.guiIdentifier),
            helperPin: ExactCodePin(codeDirectoryHash: nespat_profile_hash(handle, true) as String, signingIdentifier: SigningPolicy.helperIdentifier))
    }
    public var matchesHost: Bool { nespat_profile_host(storage.handle) }
    public var currentlyEnabled: Bool { nespat_profile_enabled(storage.handle) }
    // Explicit delegated setup authority; never described as fresh human consent per RPC.
    func authorization(_ challenge: EnrollmentChallenge) -> EnrollmentAuthorization? {
        guard !info.acceptance_only, geteuid() == 0, challenge.peer.uid == allowedUID, SystemSessionObservation.activeUID() == allowedUID, challenge.peer.process != nil,
              let boot = SystemBootIdentity.read(), boot == challenge.boot else { return nil }
        let time = RecoveryPolicy.continuousSeconds()
        guard time.isFinite, time >= challenge.issuedAt else { return nil }
        if !currentlyEnabled { return .recoveryOnly(expires: time + FullGrantLifetimePolicy.productionMaximumLifetime) }
        var expires = time + maximum
        if trialOnly {
            guard let current = try? Self.load(), current.info.trial_expires.isFinite else { return nil }
            expires = min(expires, current.info.trial_expires)
        }
        return .localSetup(LocalSetupAuthorization(challenge: challenge, setup: setupID,
            issued: time, expires: expires))
    }
}
public struct LocalSetupAuthorization: Sendable {
    let challenge: EnrollmentChallenge
    let setup: UUID
    let event = UUID()
    let issued: TimeInterval
    let expires: TimeInterval
    init(challenge: EnrollmentChallenge, setup: UUID, issued: TimeInterval, expires: TimeInterval) {
        self.challenge = challenge; self.setup = setup; self.issued = issued; self.expires = expires
    }
}
