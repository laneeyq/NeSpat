import Foundation

/// Server-created, bounded, one-use challenge. Never accepted from Request or user JSON.
public struct EnrollmentChallenge: Equatable, Sendable {
    let nonce: UUID
    let engine: UUID
    let boot: UUID
    let ownerEpoch: UUID
    public let peer: Peer
    public let issuedAt: TimeInterval
}

/// An opaque result of a future independent trusted consent verifier.
/// No public initializer, Codable conformance, RPC field, or production issuer exists.
/// Internal construction is used only by isolated tests acting as the trusted authority.
public struct FreshAuthorization: Sendable {
    let challenge: EnrollmentChallenge
    let consentEvent: UUID
    let confirmedAt: TimeInterval
    let expires: TimeInterval
    init(trustedConsentFor challenge: EnrollmentChallenge, event: UUID = UUID(), confirmedAt: TimeInterval, expires: TimeInterval) {
        self.challenge = challenge; consentEvent = event; self.confirmedAt = confirmedAt; self.expires = expires
    }
}

public enum EnrollmentAuthorization: Sendable {
    // Time alone can authorize at most recovery of an existing own record, never Scope.full.
    case recoveryOnly(expires: TimeInterval)
    case fresh(FreshAuthorization)
    case localSetup(LocalSetupAuthorization)
}
