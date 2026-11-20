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
        guard let text = nespat_code_pin(codeDirectoryHash as CFString, signingIdentifier as CFString) else {
            throw PrivilegeError.blocked
        }
        self.codeDirectoryHash = codeDirectoryHash.lowercased()
        self.signingIdentifier = signingIdentifier
        requirement = text as String
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
