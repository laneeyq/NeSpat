import NeSpatNative
import Foundation
import CoreFoundation
import Darwin
import IOKit

/// Read-only, independent observation. No pmset fallback and no inference from a setter's exit.
public enum SystemSleepObservation {
    public static func read() -> ObservedSleep {
        switch nespat_sleep_disabled() {
        case 0: .enabled
        case 1: .disabled
        default: .unknown
        }
    }
    static func decode(_ value: CFTypeRef?) -> ObservedSleep {
        guard let value else { return .unknown }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? .disabled : .enabled
        }
        guard CFGetTypeID(value) == CFNumberGetTypeID(),
              !CFNumberIsFloatType((value as! CFNumber)), let number = value as? NSNumber else { return .unknown }
        switch number.stringValue {
        case "0": return .enabled
        case "1": return .disabled
        default: return .unknown
        }
    }
}

public enum SystemBootIdentity {
    public static func read() -> UUID? {
        var bytes = [UInt8](repeating: 0, count: 128), count = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              count > 0, count <= bytes.count else { return nil }
        return decode(Array(bytes.prefix(count)))
    }
    static func decode(_ bytes: [UInt8]) -> UUID? {
        guard bytes.count == 37, bytes.last == 0,
              let text = String(bytes: bytes.dropLast(), encoding: .utf8),
              let id = UUID(uuidString: text), id.uuidString.lowercased() == text.lowercased() else { return nil }
        return id
    }
}

/// Kernel process generation for liveness, never a substitute for XPC code authentication.
/// There is no Request field or public constructor for this stamp.
public struct OwnerProcessStamp: Codable, Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let bootID: UUID
    var isValid: Bool { pid > 0 && uid != 0 && startSeconds > 0 && startMicroseconds < 1_000_000 }
}

public enum SystemOwnerLiveness {
    enum Snapshot { case process(OwnerProcessStamp), absent, unavailable }
    // Called only inside authenticated RPC dispatch using the OS connection PID/UID.
    // A process that dies during capture may conservatively delay recovery; a PID alone
    // never proves ownership, and failure to capture cannot authorize enrollment.
    static func isInstalledGUI(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0, path.contains(0) else { return false }
        return String(cString: path) == LocalTrustProfile.appPath + "/Contents/MacOS/NeSpat"
    }
    static func capture(_ connection: NSXPCConnection, boot: UUID) -> OwnerProcessStamp? {
        guard NSXPCConnection.current() === connection, connection.effectiveUserIdentifier != 0,
              case .process(let stamp) = snapshot(pid: connection.processIdentifier, boot: boot),
              stamp.uid == connection.effectiveUserIdentifier, stamp.isValid else { return nil }
        return stamp
    }
    static func snapshot(pid: Int32, boot: UUID) -> Snapshot {
        guard pid > 0 else { return .unavailable }
        var info = proc_bsdinfo()
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard result == MemoryLayout.size(ofValue: info) else { return errno == ESRCH ? .absent : .unavailable }
        guard info.pbi_pid == UInt32(pid) else { return .unavailable }
        let stamp = OwnerProcessStamp(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                                      startMicroseconds: info.pbi_start_tvusec, bootID: boot)
        guard stamp.isValid else { return .unavailable }
        return .process(stamp)
    }
    static func evaluate(_ expected: OwnerProcessStamp?, boot: UUID?, snapshot: Snapshot) -> OwnerLiveness {
        guard let expected, expected.isValid, boot == expected.bootID else { return .unknown }
        switch snapshot {
        case .absent: return .inactive
        case .unavailable: return .unknown
        case .process(let actual):
            guard actual.isValid, actual.bootID == expected.bootID, actual.pid == expected.pid else { return .unknown }
            return actual == expected ? .active : .inactive // PID reuse is not the original process.
        }
    }
    public static func read(_ peer: Peer) -> OwnerLiveness {
        guard let expected = peer.process, expected.uid == peer.uid,
              let boot = SystemBootIdentity.read(), boot == expected.bootID else { return .unknown }
        return evaluate(expected, boot: boot, snapshot: snapshot(pid: expected.pid, boot: boot))
    }
}

/// Narrow execution boundary. The only input is an unforgeable two-plan value, never
/// executable/argv/environment supplied by RPC. No live conformer or default runner exists.
protocol FixedPowerInvoking { func perform(_ plan: FixedPowerInvocation) throws -> Int32 }
struct VerifiedPowerExecutor {
    let invocation: any FixedPowerInvoking
    let observe: () -> ObservedSleep
    func setDisabled(_ disabled: Bool) throws {
        guard try invocation.perform(disabled ? .disableSleep : .restoreSleep) == 0 else { throw PrivilegeError.unconfirmed }
        switch observe() {
        case .unknown: throw PrivilegeError.unknownPower
        case let state where state == (disabled ? .disabled : .enabled): return
        default: throw PrivilegeError.unconfirmed
        }
    }
}

/// Explicit unavailable production verifier, not a simulated consent issuer. No API call
/// requests rights or modifies AuthorizationDB. A reviewed system consent design is a gate.
public enum SystemConsentVerifier {
    public static func authorize(_ challenge: EnrollmentChallenge) throws -> FreshAuthorization {
        throw PrivilegeError.blocked
    }
}
