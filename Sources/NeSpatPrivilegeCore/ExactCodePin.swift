import Foundation
import Security

/// Isolated local trust proposal: identify one explicitly approved code version, not a
/// publisher. The pin MUST come from a separately protected/approved trust anchor.
/// Never auto-enroll a hash read from a caller-supplied executable, request or pathname.
/// Selected only through an explicitly installed protected LocalTrustProfile; no self-enrollment.
public struct ExactCodePin: Sendable {
    public let codeDirectoryHash: String
    public let signingIdentifier: String
    public let requirement: String
    public init(codeDirectoryHash: String, signingIdentifier: String) throws {
        guard codeDirectoryHash.utf8.count == 40,
              codeDirectoryHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              !signingIdentifier.isEmpty, signingIdentifier.utf8.count <= 255,
              signingIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else {
            throw PrivilegeError.blocked
        }
        self.codeDirectoryHash=codeDirectoryHash.lowercased(); self.signingIdentifier=signingIdentifier
        requirement="cdhash H\"\(self.codeDirectoryHash)\" and identifier \"\(signingIdentifier)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString,[],&parsed) == errSecSuccess else { throw PrivilegeError.blocked }
    }
    // A file check is not dynamic XPC peer authentication. No bytes/identity are trusted
    // merely because they live at a chosen pathname; signature integrity is checked too.
    public func matchesFile(_ url: URL) -> Bool {
        var code: SecStaticCode?, parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL,[],&code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString,[],&parsed) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),parsed) == errSecSuccess
    }
    public func matchesHardenedFile(_ url: URL) -> Bool {
        guard matchesFile(url) else { return false }
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any], let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 /* CSCommon.h kSecCodeSignatureRuntime */ != 0 else { return false }
        let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return ["com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.cs.disable-library-validation",
                "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory"].allSatisfy { entitlements[$0] == nil }
    }
    // Requirement validated at construction; must be set once, before activation.
    // UID/audit/connection/root checks and the existing transport are still mandatory.
    func requirePeer(on connection: NSXPCConnection) { connection.setCodeSigningRequirement(requirement) }
    func requireClients(on listener: NSXPCListener) { listener.setConnectionCodeSigningRequirement(requirement) }
}
