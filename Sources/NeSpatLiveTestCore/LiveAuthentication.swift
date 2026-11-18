import Foundation
import Darwin
import Security
import NeSpatPrivilegeCore

/// Ready-to-bind OS authentication seam. No listener/deployment is enabled by this function.
/// Caller never supplies UID/PID/code identity in a wire payload.
enum LiveAuthentication {
    static func client(_ connection: NSXPCConnection, binding: LiveBinding) throws -> LivePeer {
        guard geteuid() == 0, NSXPCConnection.current() === connection,
              connection.effectiveUserIdentifier == binding.uid, binding.uid != 0,
              connection.auditSessionIdentifier > 0, connection.processIdentifier > 0,
              SystemBootIdentity.read() == binding.boot else { throw LiveError.denied }
        let pid = connection.processIdentifier, before = try stamp(pid, uid: binding.uid)
        let pin = try ExactCodePin(codeDirectoryHash: binding.clientHash, signingIdentifier: LiveTestDeployment.clientID)
        var guest: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest, SecRequirementCreateWithString(pin.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              try stamp(pid, uid: binding.uid) == before else { throw LiveError.denied }
        return LivePeer(role: .client, uid: binding.uid, pid: pid, started: before,
                        codeHash: binding.clientHash, signingID: LiveTestDeployment.clientID)
    }
    static func daemon(_ role: LiveRole, binding: LiveBinding) throws -> LivePeer {
        guard geteuid() == 0, role == .helper || role == .recovery,
              SystemBootIdentity.read() == binding.boot else { throw LiveError.denied }
        let id = role == .helper ? LiveTestDeployment.helperID : LiveTestDeployment.watchdogID
        let hash = role == .helper ? binding.helperHash : binding.recoveryHash
        let pin = try ExactCodePin(codeDirectoryHash: hash, signingIdentifier: id)
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(pin.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw LiveError.denied }
        return LivePeer(role: role, uid: 0, pid: getpid(), started: try stamp(getpid(), uid: 0), codeHash: hash, signingID: id)
    }
    private static func stamp(_ pid: Int32, uid: UInt32) throws -> UInt64 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_pid == UInt32(pid), info.pbi_uid == uid, info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { throw LiveError.denied }
        let (value, overflow) = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        let (stamp, additionOverflow) = value.addingReportingOverflow(info.pbi_start_tvusec)
        guard !overflow, !additionOverflow else { throw LiveError.denied }; return stamp
    }
}
