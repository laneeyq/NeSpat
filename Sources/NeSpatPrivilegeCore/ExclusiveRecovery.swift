import Foundation

/// Root-provisioned policy. Never accepted in an XPC payload.
public struct ExclusivePolicy: Sendable {
    public let setup: UUID
    public let uid: UInt32
    public let clientRequirement: String
    public let selectedLifetime: Bool
    public let maximum: Double
    public let helperEpoch: UUID
    public let canArm: @Sendable () -> Bool
    public init(setup: UUID, uid: UInt32, clientRequirement: String, maximum: Double,
                helperEpoch: UUID, selectedLifetime: Bool = false, canArm: @escaping @Sendable () -> Bool) throws {
        guard uid > 0, !clientRequirement.isEmpty, maximum.isFinite,
              maximum > 0, maximum <= FullGrantLifetimePolicy.productionMaximumLifetime else { throw PrivilegeError.denied }
        self.setup = setup; self.uid = uid; self.clientRequirement = clientRequirement
        self.selectedLifetime = selectedLifetime; self.maximum = maximum; self.helperEpoch = helperEpoch; self.canArm = canArm
    }
}

public struct ExclusiveAttempt: Codable, Equatable, Sendable {
    let setup: UUID
    let session: UUID
    let helperEpoch: UUID
    let owner: Peer
    let boot: UUID
    let startedOnAC: Bool
    let issued: Double
    let expires: Double?
    let deadline: Date?
    var selectedLifetime: Bool? = nil
    var unlimited: Bool? = nil
    let nonce: UUID
}

extension PrivilegedRecord {
    func verifiedAttempt(_ policy: ExclusivePolicy) throws -> ExclusiveAttempt {
        try validateOwnership(boot: bootID)
        guard let proof = exclusiveAttempt, exclusiveReservation == policy.setup, proof.setup == policy.setup, proof.session == id,
              proof.owner == owner, owner.process != nil, owner.uid == policy.uid,
              owner.codeIdentity == policy.clientRequirement, proof.boot == bootID,
              proof.issued.isFinite, proof.issued >= 0,
              proof.expires == authorityExpires, proof.deadline == deadline,
              interference != true else { throw PrivilegeError.ownership }
        if proof.selectedLifetime == true {
            guard policy.selectedLifetime else { throw PrivilegeError.ownership }
        }
        if proof.unlimited == true {
            guard proof.selectedLifetime == true, proof.expires == nil, proof.deadline == nil else { throw PrivilegeError.ownership }
        } else {
            guard let expires = proof.expires, proof.deadline != nil, expires.isFinite, expires > proof.issued,
                  proof.selectedLifetime == true || expires - proof.issued <= policy.maximum else { throw PrivilegeError.ownership }
        }
        try validateTimer()
        return proof
    }
}
