import Foundation
import NeSpatNative

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
        guard let proof = exclusiveAttempt else { throw PrivilegeError.ownership }
        var setup = policy.setup.uuid
        let encoded = try JSONEncoder().encode(self)
        guard encoded.withUnsafeBytes({ raw in
            withUnsafeBytes(of: &setup) { uuid in
                nespat_verify_record(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                    uuid.bindMemory(to: UInt8.self).baseAddress!, policy.uid,
                    policy.clientRequirement as CFString, policy.selectedLifetime, policy.maximum)
            }
        }) else { throw PrivilegeError.ownership }
        return proof
    }
}
