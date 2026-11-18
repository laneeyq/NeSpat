import Darwin
import Foundation

/// The installer owns Runtime and its parent. Only root publishes. Clients only read.
public struct ServicePulse: Codable, Sendable {
    public enum Role: String, Codable, Sendable { case helper, watchdog }
    public let epoch: UUID
    let boot: UUID
    let setup: UUID
    let continuous: Double
    let pid: Int32
    let role: Role
    static func path(_ role: Role) -> URL {
        URL(fileURLWithPath: "/Library/Application Support/NeSpatPrivileged/Runtime/" + role.rawValue + ".json")
    }
    public static func publish(_ role: Role, epoch: UUID, boot: UUID, setup: UUID) throws {
        guard geteuid() == 0 else { throw PrivilegeError.denied }
        let pulse = Self(epoch: epoch, boot: boot, setup: setup, continuous: RecoveryPolicy.continuousSeconds(), pid: getpid(), role: role)
        try JSONEncoder().encode(pulse).write(to: path(role), options: .atomic)
    }
    public static func current(_ role: Role, boot: UUID, setup: UUID) -> Self? {
        guard let data = try? Data(contentsOf: path(role)), data.count <= 1024,
              let p = try? JSONDecoder().decode(Self.self, from: data), p.role == role,
              p.boot == boot, p.setup == setup, p.pid > 1 else { return nil }
        let age = RecoveryPolicy.continuousSeconds() - p.continuous
        guard age >= 0, age < 8, kill(p.pid, 0) == 0 || errno == EPERM else { return nil }
        return p
    }
}
