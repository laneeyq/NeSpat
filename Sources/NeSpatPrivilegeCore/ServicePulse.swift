import NeSpatNative
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
        var value = NeSpatPulse(epoch: epoch.uuid, boot: boot.uuid, setup: setup.uuid, continuous: 0, pid: 0)
        guard nespat_publish_pulse(&value, role == .watchdog) else { throw PrivilegeError.denied }
    }
    public static func current(_ role: Role, boot: UUID, setup: UUID) -> Self? {
        var value = NeSpatPulse()
        value.boot = boot.uuid
        value.setup = setup.uuid
        guard nespat_read_pulse(&value, role == .watchdog) else { return nil }
        return Self(epoch: UUID(uuid: value.epoch), boot: boot, setup: setup, continuous: value.continuous, pid: value.pid, role: role)
    }
}
