import NeSpatNative
import Foundation
import Security
import ServiceManagement

public struct SigningPolicy: Sendable {
    public static let guiIdentifier = "local.nespat.app"
    public static let helperIdentifier = "local.nespat.privilege-helper"
    public static let machService = "local.nespat.privilege-helper"
    public let guiRequirement: String
    public let helperRequirement: String
    public init(teamID: String) throws {
        guard teamID.utf8.count == 10, teamID.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw PrivilegeError.blocked }
        func requirement(_ id: String) -> String {
            // Developer ID chain + precise Team AND signing identifier. Self-signed CA not accepted.
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(id)\""
        }
        guiRequirement = requirement(Self.guiIdentifier); helperRequirement = requirement(Self.helperIdentifier)
        try Self.validate(guiRequirement); try Self.validate(helperRequirement)
    }
    public init(approvedLocalGUI gui: ExactCodePin, helper: ExactCodePin) throws {
        guard gui.signingIdentifier == Self.guiIdentifier, helper.signingIdentifier == Self.helperIdentifier else { throw PrivilegeError.blocked }
        guiRequirement = gui.requirement; helperRequirement = helper.requirement
        try Self.validate(guiRequirement); try Self.validate(helperRequirement)
    }
    private static func validate(_ text: String) throws {
        guard nespat_valid_requirement(text as CFString) else { throw PrivilegeError.blocked }
    }
    // Read-only real code-signing check. Does not establish the identity of an XPC peer.
    public func matchesFile(_ url: URL, helper: Bool) -> Bool {
        nespat_matches_code(url as CFURL, (helper ? helperRequirement : guiRequirement) as CFString, false)
    }
    // Listener-wide rejection occurs before the delegate; the per-message requirement
    // below remains mandatory too. Only anonymous/mach-service listeners support this.
    func requireClient(on listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(guiRequirement)
    }
}

@objc public protocol PrivilegeRPC {
    func request(_ bytes: Data, reply: @escaping (Data) -> Void)
}

// Intentionally not an XPC argument, user preference or environment toggle.
public enum PrivilegeDeployment {
    public static let blockedReason = "Legacy deployment entry point disabled. Local service requires an explicitly approved root-owned exact-pin profile."
    public static var enabled: Bool { false }
    public static func register() throws { throw PrivilegeError.blocked }
    public static func unregister() throws { throw PrivilegeError.blocked }
    // The service descriptor is compiled against the installed SDK, but not registered.
    public static func descriptor() -> SMAppService { .daemon(plistName: "local.nespat.privilege-helper.plist") }
}

public final class PrivilegeListener: NSObject, NSXPCListenerDelegate {
    private let policy: SigningPolicy
    private let engine: PrivilegeEngine
    private let enrollment: (EnrollmentChallenge) -> EnrollmentAuthorization?
    private var installedClientUID: UInt32?
    private var local = false
    public convenience init(localProfile: LocalTrustProfile, engine: PrivilegeEngine) throws {
        guard geteuid() == 0 else { throw PrivilegeError.blocked }
        try self.init(policy: localProfile.policy, engine: engine, enrollment: localProfile.authorization)
        installedClientUID = localProfile.allowedUID
        local = true
    }
    public convenience init(acceptanceProfile profile: LocalTrustProfile, engine: PrivilegeEngine) throws {
        guard geteuid() == 0, profile.acceptanceOnly else { throw PrivilegeError.blocked }
        try self.init(policy: profile.policy, engine: engine, enrollment: { _ in nil })
        local = true
    }
    public init(policy: SigningPolicy, engine: PrivilegeEngine, enrollment: @escaping (EnrollmentChallenge) -> EnrollmentAuthorization?) {
        self.policy = policy; self.engine = engine; self.enrollment = enrollment
    }
    public func preparedListener() throws -> NSXPCListener {
        guard PrivilegeDeployment.enabled || (local && geteuid() == 0) else { throw PrivilegeError.blocked }
        let listener = NSXPCListener(machServiceName: SigningPolicy.machService)
        policy.requireClient(on: listener)
        listener.delegate = self
        return listener // No activation or registration here.
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // No deployable listener in v7, even if someone instantiates this class manually.
        guard (PrivilegeDeployment.enabled || (local && geteuid() == 0)), connection.auditSessionIdentifier > 0,
              connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(policy.guiRequirement)
        connection.exportedInterface = NSXPCInterface(with: VerifiedPrivilegeRPC.self)
        let endpoint = HandshakingPrivilegeEndpoint(connection: connection, policy: policy, engine: engine, enrollment: enrollment, installedClientUID: installedClientUID)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.close() }
        connection.interruptionHandler = { endpoint.close() }
        connection.activate()
        return true
    }
}

// No identity supplied by the wire reaches enrollment. This wrapper creates the peer only
// during a requirement-checked dispatch, binds OS credentials and kernel process lifetime,
// and checks that each request belongs to this exact connection before touching the engine.
final class AuthenticatedPrivilegeEndpoint: NSObject, PrivilegeRPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let policy: SigningPolicy
    private let engine: PrivilegeEngine
    private let enrollment: (EnrollmentChallenge) -> EnrollmentAuthorization?
    private let mutex = NSLock()
    private var endpoint: PrivilegeEndpoint?
    private var boundPeer: Peer?
    private var closed = false
    init(connection: NSXPCConnection, policy: SigningPolicy, engine: PrivilegeEngine,
         enrollment: @escaping (EnrollmentChallenge) -> EnrollmentAuthorization?) {
        self.connection = connection; self.policy = policy; self.engine = engine; self.enrollment = enrollment
    }
    func request(_ bytes: Data, reply: @escaping (Data) -> Void) {
        mutex.lock()
        guard !closed, let connection, NSXPCConnection.current() === connection,
              connection.effectiveUserIdentifier != 0, connection.auditSessionIdentifier > 0 else {
            mutex.unlock(); reply(Data(#"{"error":"denied-or-unconfirmed"}"#.utf8)); return
        }
        if endpoint == nil {
            guard let boot = SystemBootIdentity.read(),
                  let stamp = SystemOwnerLiveness.capture(connection, boot: boot) else {
                mutex.unlock(); reply(Data(#"{"error":"denied-or-unconfirmed"}"#.utf8)); return
            }
            let peer = Peer(connection: UUID(), uid: connection.effectiveUserIdentifier,
                            auditSession: UInt32(connection.auditSessionIdentifier),
                            codeIdentity: policy.guiRequirement, process: stamp)
            endpoint = PrivilegeEndpoint(engine: engine, peer: peer, enrollment: enrollment)
            boundPeer = peer
        }
        guard boundPeer?.uid == connection.effectiveUserIdentifier,
              boundPeer?.auditSession == UInt32(connection.auditSessionIdentifier),
              boundPeer?.process?.pid == connection.processIdentifier else {
            mutex.unlock(); reply(Data(#"{"error":"denied-or-unconfirmed"}"#.utf8)); return
        }
        let target = endpoint!
        mutex.unlock()
        target.request(bytes, reply: reply)
    }
    func close() {
        mutex.lock(); closed = true; let target = endpoint; mutex.unlock()
        target?.close()
    }
}

// Internal for rootless integration tests; real RPC dispatch must enforce SigningPolicy first.
final class PrivilegeEndpoint: NSObject, PrivilegeRPC, @unchecked Sendable {
    private let engine: PrivilegeEngine
    private let peer: Peer
    private let enrollment: (EnrollmentChallenge) -> EnrollmentAuthorization?
    private let mutex = NSLock()
    private var admitted = false
    private var closed = false
    init(engine: PrivilegeEngine, peer: Peer, enrollment: @escaping (EnrollmentChallenge) -> EnrollmentAuthorization?) {
        self.engine = engine; self.peer = peer; self.enrollment = enrollment
    }
    func request(_ bytes: Data, reply: @escaping (Data) -> Void) {
        let response: Data
        mutex.lock()
        do {
            guard !closed else { throw PrivilegeError.denied }
            let request = try Request.decode(bytes)
            // Foundation has checked the peer requirement BEFORE dispatching this method.
            // No policy read, enrollment or admission is performed in the listener delegate.
            if !admitted {
                let challenge = try engine.enrollmentChallenge(for: peer)
                guard let authorization = enrollment(challenge) else { throw PrivilegeError.denied }
                try engine.admit(peer, authorization: authorization); admitted = true
            }
            response = try JSONEncoder().encode(engine.handle(request, from: peer))
        } catch { response = Data(#"{"error":"denied-or-unconfirmed"}"#.utf8) }
        mutex.unlock()
        reply(response) // Do not invoke external callbacks while holding the endpoint mutex.
    }
    func close() {
        mutex.lock(); defer { mutex.unlock() }
        guard !closed else { return }
        closed = true
        if admitted { try? engine.disconnect(peer) }
        else { engine.cancelEnrollment(for: peer) }
    }
}

// Compile-checked client transport. No GUI linkage or hidden fallback switch in v7.
public enum PrivilegeClient {
    public static func connect(policy: SigningPolicy) throws -> PrivilegeTransport {
        guard PrivilegeDeployment.enabled else { throw PrivilegeError.blocked }
        return PrivilegeTransport(channel:NSXPCHelperChannel(policy:policy))
    }
    public static func connectLocal(profile: LocalTrustProfile) throws -> PrivilegeTransport {
        guard profile.guiPin.matchesHardenedFile(Bundle.main.bundleURL) else { throw PrivilegeError.blocked }
        return PrivilegeTransport(channel: NSXPCHelperChannel(policy: try profile.policy))
    }
    // OS-derived values, never an EUID claimed in Reply. A fresh/unconnected transport
    // can report default credentials; a real remote PID is also mandatory. This is only
    // a prepared guard: no live GUI client exists and root-positive validation is a gate.
    static func validateReplyPeer(_ connection: NSXPCConnection) throws {
        guard connection.processIdentifier > 0, connection.effectiveUserIdentifier == 0 else {
            connection.invalidate(); throw PrivilegeError.denied
        }
    }
}
