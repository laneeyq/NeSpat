import Foundation
import NeSpatNative
import CoreFoundation

public enum PrivilegeError: Error, Equatable { case blocked, denied, malformed, replay, busy, journal, unknownPower, ownership, interference, unconfirmed }
public enum OwnerLiveness: Sendable { case active, inactive, unknown }
public enum ObservedSleep: String, Codable, Sendable { case enabled, disabled, unknown }
public enum Operation: String, Codable, Sendable { case status, begin, changeDeadline, end, recover, revoke, heartbeat, pollRecovery }

// There is deliberately no command/path/UID/PID/environment field on this boundary.
public struct Request: Sendable {
    public let id: UUID
    public let operation: Operation
    public let session: UUID?
    public let minutes: Int?
    public let heartbeatSequence: Int?
    public init(id: UUID = UUID(), operation: Operation, session: UUID? = nil, minutes: Int? = nil, heartbeatSequence: Int? = nil) {
        self.heartbeatSequence = heartbeatSequence
        self.id = id; self.operation = operation; self.session = session; self.minutes = minutes
    }
    private static let operations: [Operation] = [.status, .begin, .changeDeadline, .end, .recover, .revoke, .heartbeat, .pollRecovery]

    private var native: NeSpatRequest {
        var r = NeSpatRequest()
        r.id = id.uuid
        r.operation = UInt8(Self.operations.firstIndex(of: operation) ?? 255)
        if let session { r.has_session = true; r.session = session.uuid }
        if let minutes { r.has_minutes = true; r.minutes = Int64(minutes) }
        if let heartbeatSequence { r.has_sequence = true; r.sequence = Int64(heartbeatSequence) }
        return r
    }
    public static func decode(_ data: Data) throws -> Self {
        var r = NeSpatRequest()
        guard data.count <= 4096, data.withUnsafeBytes({
            nespat_decode_request($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &r)
        }), operations.indices.contains(Int(r.operation)) else { throw PrivilegeError.malformed }
        return Self(id: UUID(uuid: r.id), operation: operations[Int(r.operation)],
                    session: r.has_session ? UUID(uuid: r.session) : nil,
                    minutes: r.has_minutes ? Int(r.minutes) : nil,
                    heartbeatSequence: r.has_sequence ? Int(r.sequence) : nil)
    }
    func encoded() throws -> Data {
        var r = native
        guard let bytes = nespat_encode_request(&r) else { throw PrivilegeError.malformed }
        return bytes as Data
    }
    func validate() throws {
        var r = native
        guard nespat_valid_request(&r) else { throw PrivilegeError.malformed }
    }
    static func interval(_ minutes: Int) throws -> Double {
        let seconds = nespat_minutes_to_seconds(Int64(minutes))
        guard seconds > 0 else { throw PrivilegeError.malformed }
        return Double(seconds)
    }
    func deadline(now: Date) throws -> Date? {
        guard let minutes else { return nil }
        let seconds = try Self.interval(minutes), end = now.timeIntervalSinceReferenceDate + seconds
        guard end.isFinite, abs(end) <= 9_007_199_254_740_992, end > now.timeIntervalSinceReferenceDate else { throw PrivilegeError.malformed }
        return Date(timeIntervalSinceReferenceDate: end)
    }
}

public struct OwnerIdentity: Equatable, Hashable, Sendable {
    public let uid: UInt32
    public let auditSession: UInt32
    public let codeIdentity: String
}

// Created from the actual connection by the adapter, never decoded from Request.
public struct Peer: Codable, Equatable, Sendable {
    public let connection: UUID
    public let uid: UInt32
    public let auditSession: UInt32
    /// Trusted adapter's canonical signing requirement enforced by XPC, never a Request field.
    /// Optional only to decode v7 journals. Missing identity cannot authorize reconnect.
    public let codeIdentity: String?
    public let process: OwnerProcessStamp?
    public init(connection: UUID, uid: UInt32, auditSession: UInt32, codeIdentity: String? = nil, process: OwnerProcessStamp? = nil) {
        self.connection = connection; self.uid = uid; self.auditSession = auditSession; self.codeIdentity = codeIdentity
        self.process = process
    }
    var hasVerifiedIdentity: Bool {
        uid != 0 && auditSession != 0 && codeIdentity.map { !$0.isEmpty && $0.utf8.count <= 2048 } == true &&
        (process.map { $0.isValid && $0.uid == uid } ?? true)
    }
    var ownerIdentity: OwnerIdentity? {
        guard hasVerifiedIdentity, let codeIdentity else { return nil }
        return OwnerIdentity(uid: uid, auditSession: auditSession, codeIdentity: codeIdentity)
    }
    func sameOwner(as other: Peer) -> Bool {
        ownerIdentity != nil && ownerIdentity == other.ownerIdentity
    }
}
public struct Reply: Codable, Sendable {
    public let state: ObservedSleep
    public let session: UUID?
    public let deadline: Date?
    public let authorityExpires: TimeInterval?
    public let active: Bool?
    public let recoveryTicket: String?
    public let selectedLifetime: Bool?
    public let fullAuthority: Bool?
    public init(state: ObservedSleep, session: UUID?, deadline: Date?, authorityExpires: TimeInterval? = nil, active: Bool? = nil, fullAuthority: Bool? = nil, recoveryTicket: String? = nil, selectedLifetime: Bool? = nil) {
        self.selectedLifetime = selectedLifetime
        self.recoveryTicket = recoveryTicket
        self.active = active; self.fullAuthority = fullAuthority
        self.state = state; self.session = session; self.deadline = deadline; self.authorityExpires = authorityExpires
    }
}
public struct PrivilegedRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case pending, active }
    public var id: UUID
    public var owner: Peer
    public var bootID: UUID
    public internal(set) var exclusiveReservation: UUID?
    public internal(set) var exclusiveAttempt: ExclusiveAttempt?
    public internal(set) var interference: Bool?
    public var baselineEnabled: Bool
    public var phase: Phase
    public var deadline: Date?
    public var authorityExpires: TimeInterval?
    public init(id: UUID, owner: Peer, bootID: UUID, baselineEnabled: Bool, phase: Phase, deadline: Date?, authorityExpires: TimeInterval? = nil) {
        self.id = id; self.owner = owner; self.bootID = bootID; self.baselineEnabled = baselineEnabled; self.phase = phase; self.deadline = deadline; self.authorityExpires = authorityExpires
    }
    func validateOwnership(boot: UUID) throws {
        guard bootID == boot, baselineEnabled, owner.hasVerifiedIdentity else { throw PrivilegeError.ownership }
        guard owner.process.map({ $0.bootID == boot }) ?? true else { throw PrivilegeError.ownership }
    }
    func validateTimer() throws {
        if let authorityExpires { guard authorityExpires.isFinite, authorityExpires >= 0 else { throw PrivilegeError.journal } }
        if let date = deadline {
            guard date.timeIntervalSinceReferenceDate.isFinite, abs(date.timeIntervalSinceReferenceDate) <= 9_007_199_254_740_992 else { throw PrivilegeError.journal }
        }
    }
}
public protocol AuthorityJournal: AnyObject {
    func exclusive<T>(_ body: () throws -> T) throws -> T
    func load() throws -> PrivilegedRecord?
    func save(_ record: PrivilegedRecord?) throws
}

// Allowlisted invocation plan only. No Process/shell executor is connected in this stage.
public struct FixedPowerInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    private init(disabled: Bool) {
        executable = "/usr/bin/pmset"
        arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    }
    public static let disableSleep = Self(disabled: true)
    public static let restoreSleep = Self(disabled: false)
    private init(emergencySleep: Void) {
        executable = "/usr/bin/pmset"
        arguments = ["sleepnow"]
    }
    public static let emergencySleep = Self(emergencySleep: ()) // Plan only, no live invoker.
}
