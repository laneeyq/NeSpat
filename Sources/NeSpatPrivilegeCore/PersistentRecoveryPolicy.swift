import Foundation
import Darwin

public struct RecoveryRetry: Codable, Equatable, Sendable {
    public var record: PrivilegedRecord
    public var generation: UInt64
    public let nonce: UUID
    public var since: TimeInterval
    public var last: TimeInterval
    public var emergency: Bool
    public var failures: UInt64? = nil
    public var clockFault: Bool
}
public struct RecoverySnapshot: Sendable {
    public let generation: UInt64
    public let retry: RecoveryRetry?
    public init(generation: UInt64, retry: RecoveryRetry?) { self.generation = generation; self.retry = retry }
}
public protocol PersistentRecoveryJournal: AuthorityJournal {
    func recoverySnapshot() throws -> RecoverySnapshot
    // Same exclusive transaction and aggregate file as authority; metadata is never ownership.
    func saveRecoveryRetry(_ retry: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws
}
public enum RecoveryPolicy {
    public static let ordinary: TimeInterval = 300
    public static let emergency: TimeInterval = 30
    // Kernel boot-scoped continuous clock, includes system sleep; no Instant serialization.
    public static func continuousSeconds() -> TimeInterval {
        let ticks = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        return ticks > 0 ? Double(ticks) / 1_000_000_000 : .nan
    }
}
