import Foundation
import NeSpatNative

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
        guard nespat_valid_requirement(requirement as CFString) else { throw PrivilegeError.blocked }
    }
    // A file check is not dynamic XPC peer authentication. No bytes/identity are trusted
    // merely because they live at a chosen pathname; signature integrity is checked too.
    public func matchesFile(_ url: URL) -> Bool {
        nespat_matches_code(url as CFURL, requirement as CFString, false)
    }
    public func matchesHardenedFile(_ url: URL) -> Bool {
        nespat_matches_code(url as CFURL, requirement as CFString, true)
    }
    // Requirement validated at construction; must be set once, before activation.
    // UID/audit/connection/root checks and the existing transport are still mandatory.
    func requirePeer(on connection: NSXPCConnection) { connection.installRequirement(requirement) }
    func requireClients(on listener: NSXPCListener) { listener.installRequirement(requirement) }
}
