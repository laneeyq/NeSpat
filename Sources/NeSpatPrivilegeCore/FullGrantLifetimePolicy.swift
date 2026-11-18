import Foundation

/// Trusted server bootstrap input, never decoded from RPC/config/environment. There is
/// intentionally no production default. Absence blocks new full grants, not own recovery.
public struct FullGrantLifetimePolicy: Sendable {
    // Explicitly approved by the user: one automatic session, never a sliding lease.
    public static let productionMaximumLifetime: TimeInterval = 43_200
    public static var production: Self { try! Self(maximumLifetime: productionMaximumLifetime) }
    public let maximumLifetime: TimeInterval
    public init(maximumLifetime: TimeInterval) throws {
        guard maximumLifetime.isFinite, maximumLifetime > 0 else { throw PrivilegeError.blocked }
        self.maximumLifetime=maximumLifetime
    }
    func validate(confirmedAt: TimeInterval, expires: TimeInterval) throws {
        guard confirmedAt.isFinite, expires.isFinite else { throw PrivilegeError.denied }
        let duration=expires-confirmedAt
        // Check the subtraction itself: two finite endpoints can overflow to infinity.
        guard duration.isFinite, duration > 0, duration <= maximumLifetime else { throw PrivilegeError.denied }
    }
}
