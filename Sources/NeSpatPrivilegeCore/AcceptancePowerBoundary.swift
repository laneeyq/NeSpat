import Foundation

/// Acceptance's only setter implementation: no executable path, Process, callback or configuration.
/// Both directions fail at the execution boundary, even with a valid recovery record.
public enum AcceptancePowerBoundary {
    public static func setDisabled(_ disabled: Bool) throws { throw PrivilegeError.blocked }
}

/// Never persists authority, so this service cannot create a power session.
public final class AcceptanceAuthorityJournal: AuthorityJournal {
    public init() {}
    public func exclusive<T>(_ body: () throws -> T) throws -> T { try body() }
    public func load() throws -> PrivilegedRecord? { nil }
    public func save(_ record: PrivilegedRecord?) throws { throw PrivilegeError.blocked }
}
