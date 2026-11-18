import Foundation
import Darwin

// Public pins contain no secret. Only an explicit admin setup may provision this fixed,
// root-owned path. No client pathname/hash is auto-trusted or accepted over XPC.
public struct LocalTrustProfile: Sendable {
    public static let appPath = "/Library/Application Support/NeSpatPrivileged/NeSpat.app"
    public static let path = "/Library/Application Support/NeSpatPrivileged/LocalTrust/profile.json"
    private struct Document: Codable, Equatable, Sendable {
        let version: Int
        let setup: UUID
        let allowedUID: UInt32
        let guiHash: String
        let helperHash: String
        let enabled: Bool
        let acceptanceOnly: Bool?
        let exclusiveControl: Bool?
        let hostModel: String?
        let osBuild: String?
        let selectedLifetime: Bool?
        let trialOnly: Bool?
        let trialOnBattery: Bool?
        let trialBoot: UUID?
        let trialExpires: Double?
    }
    private let document: Document
    public let guiPin: ExactCodePin
    public let helperPin: ExactCodePin
    public var policy: SigningPolicy { get throws { try SigningPolicy(approvedLocalGUI: guiPin, helper: helperPin) } }
    public var acceptanceOnly: Bool { document.acceptanceOnly == true && !document.enabled }
    public var exclusiveControl: Bool { document.exclusiveControl == true && document.acceptanceOnly != true }
    public var setupID: UUID { document.setup }
    public var selectedLifetime: Bool { exclusiveControl && !trialOnly && document.selectedLifetime == true }
    public var trialOnly: Bool { document.trialOnly == true }
    public func permitsTrialSource(_ external: Bool?) -> Bool {
        !trialOnly || external == (document.trialOnBattery != true)
    }
    public var maximum: Double { trialOnly ? 120 : FullGrantLifetimePolicy.productionMaximumLifetime }
    public var allowedUID: UInt32 { document.allowedUID }
    private init(_ document: Document) throws {
        guard document.version == 1, document.allowedUID != 0 else { throw PrivilegeError.blocked }
        self.document = document
        guiPin = try ExactCodePin(codeDirectoryHash: document.guiHash, signingIdentifier: SigningPolicy.guiIdentifier)
        helperPin = try ExactCodePin(codeDirectoryHash: document.helperHash, signingIdentifier: SigningPolicy.helperIdentifier)
    }
    public static func load() throws -> Self {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PrivilegeError.blocked }; defer { close(fd) }
        try check(fd, directory: true)
        let parts = path.split(separator: "/")
        for part in parts.dropLast() {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw PrivilegeError.blocked }; close(fd); fd = next
            try check(fd, directory: true)
        }
        let f = openat(fd, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard f >= 0 else { throw PrivilegeError.blocked }; defer { close(f) }
        try check(f, directory: false)
        var bytes = [UInt8](repeating: 0, count: 4097)
        let n = read(f, &bytes, bytes.count)
        guard n > 0, n <= 4096 else { throw PrivilegeError.blocked }
        return try Self(JSONDecoder().decode(Document.self, from: Data(bytes.prefix(n))))
    }
    private static func check(_ fd: Int32, directory: Bool) throws {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == 0, s.st_mode & 0o022 == 0,
              s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (s.st_nlink == 1 && s.st_size <= 4096) else { throw PrivilegeError.blocked }
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw PrivilegeError.blocked }
        guard errno == ENOENT else { throw PrivilegeError.blocked }
    }
    public var matchesHost: Bool {
        func value(_ name: String) -> String? {
            var buffer = [CChar](repeating: 0, count: 128)
            var size = buffer.count
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0, size > 1, size <= buffer.count,
                  buffer[size - 1] == 0 else { return nil }
            return String(decoding: buffer.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard let model = document.hostModel, let build = document.osBuild else { return false }
        return model == value("hw.model") && build == value("kern.osversion")
    }
    public var currentlyEnabled: Bool {
        guard let current = try? Self.load() else { return false }
        guard current.exclusiveControl, current.matchesHost, current.document.enabled,
              current.document.setup == document.setup, current.document.allowedUID == allowedUID,
              current.document.guiHash == document.guiHash, current.document.helperHash == document.helperHash,
              current.selectedLifetime == selectedLifetime, current.trialOnly == trialOnly, current.document.trialOnBattery == document.trialOnBattery else { return false }
        if trialOnly {
            guard let until = current.document.trialExpires, until.isFinite,
                  current.document.trialBoot == SystemBootIdentity.read(), current.document.trialBoot != nil else { return false }
            let remaining = until - RecoveryPolicy.continuousSeconds()
            return remaining > 0 && remaining <= 120
        }
        return true
    }
    // Explicit delegated setup authority; never described as fresh human consent per RPC.
    func authorization(_ challenge: EnrollmentChallenge) -> EnrollmentAuthorization? {
        guard document.acceptanceOnly != true, geteuid() == 0, challenge.peer.uid == allowedUID, SystemSessionObservation.activeUID() == allowedUID, challenge.peer.process != nil,
              let boot = SystemBootIdentity.read(), boot == challenge.boot else { return nil }
        let time = RecoveryPolicy.continuousSeconds()
        guard time.isFinite, time >= challenge.issuedAt else { return nil }
        if !currentlyEnabled { return .recoveryOnly(expires: time + FullGrantLifetimePolicy.productionMaximumLifetime) }
        var expires = time + maximum
        if trialOnly {
            guard let current = try? Self.load(), let until = current.document.trialExpires else { return nil }
            expires = min(expires, until)
        }
        return .localSetup(LocalSetupAuthorization(challenge: challenge, setup: document.setup,
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
