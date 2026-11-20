import Foundation
import NeSpatNative
import NeSpatPrivilegeCore

// Serialize blocking XPC operations away from the AppKit main thread.
actor LocalAutomaticBackend: AutomaticSessionBackend {
    private final class Storage {
        let handle = nespat_session_new()
        deinit { nespat_session_drop(handle) }
    }
    private let storage = Storage()
    func observation() throws -> AutomaticObservation {
        try Task.checkCancellation()
        var o = NeSpatSessionObservation()
        guard nespat_session_observe(storage.handle, &o) else { throw PrivilegeError.unconfirmed }
        let boot = UUID(uuid: o.boot)
        let lease = o.has_session ? AutomaticLease(id: UUID(uuid: o.id), boot: boot,
            deadline: o.deadline.isFinite ? Date(timeIntervalSinceReferenceDate: o.deadline) : nil,
            expires: o.expires.isFinite ? o.expires : nil, selectedLifetime: o.selected) : nil
        func flag(_ value: Int8) -> Bool? { value < 0 ? nil : value == 1 }
        var result = AutomaticObservation(serviceVerified: true, setupAuthorized: o.permitted, activeUser: o.active_user,
            lidClosed: flag(o.lid), power: o.power < 0 ? .unknown : o.power == 1 ? .disabled : .enabled,
            safety: PowerSafetySnapshot(batteryPercent: o.battery, externalPowerConnected: flag(o.ac),
                                       temperatureC: o.temp, thermalSerious: flag(o.thermal)),
            lease: lease, foreign: o.foreign_owner, boot: boot, wall: Date(), continuous: o.now)
        result.recoveryOnly = o.recovery_only
        return result
    }
    func prearm(maximumSeconds: TimeInterval) throws {
        try Task.checkCancellation()
        guard maximumSeconds == FullGrantLifetimePolicy.productionMaximumLifetime, nespat_session_prepare(storage.handle) else {
            throw PrivilegeError.denied
        }
    }
    private func effect(_ id: UUID, _ call: (OpaquePointer, UnsafePointer<UInt8>) -> Bool) throws {
        var bytes = id.uuid
        let ok = withUnsafeBytes(of: &bytes) { call(storage.handle, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard ok else { throw PrivilegeError.unconfirmed }
    }
    func heartbeat(session: UUID) throws { try effect(session, nespat_session_heartbeat) }
    func sleepDisplayIfClosed(session: UUID) throws { try effect(session, nespat_session_display) }
    func pollRestoration(session: UUID) throws { try effect(session) { nespat_session_recover($0, $1, false) } }
    func manualRecovery(session: UUID) throws { try effect(session) { nespat_session_recover($0, $1, true) } }
}
