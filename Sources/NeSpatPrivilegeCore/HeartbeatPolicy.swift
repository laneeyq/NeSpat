import Foundation

/// Trusted server liveness policy, separate from the immutable full-grant expiry.
/// No wire/config/environment decoder or production default is provided.
public struct HeartbeatPolicy: Sendable {
    public let timeout: TimeInterval
    public init(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0 else { throw PrivilegeError.blocked }
        self.timeout = timeout
    }
}
