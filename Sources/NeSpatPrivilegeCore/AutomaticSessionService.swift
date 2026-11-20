import NeSpatNative
import Foundation

public struct AutomaticLease: Sendable, Equatable {
    public let id: UUID
    public let boot: UUID
    public let deadline: Date?
    public let expires: TimeInterval?
    public let selectedLifetime: Bool
    public init(id: UUID, boot: UUID, deadline: Date?, expires: TimeInterval?, selectedLifetime: Bool = false) {
        self.id = id; self.boot = boot; self.deadline = deadline; self.expires = expires
        self.selectedLifetime = selectedLifetime
    }

}
public struct AutomaticObservation: Sendable {
    public var recoveryOnly = false
    public var serviceVerified: Bool
    public var setupAuthorized: Bool
    public var activeUser: Bool?
    public var lidClosed: Bool?
    public var power: ObservedSleep
    public var safety: PowerSafetySnapshot
    public var lease: AutomaticLease?
    public var foreign: Bool
    public var boot: UUID
    public var wall: Date
    public var continuous: TimeInterval
    public init(serviceVerified: Bool, setupAuthorized: Bool, activeUser: Bool?, lidClosed: Bool?,
                power: ObservedSleep, safety: PowerSafetySnapshot, lease: AutomaticLease?, foreign: Bool,
                boot: UUID, wall: Date, continuous: TimeInterval) {
        self.serviceVerified = serviceVerified; self.setupAuthorized = setupAuthorized
        self.activeUser = activeUser; self.lidClosed = lidClosed; self.power = power; self.safety = safety
        self.lease = lease; self.foreign = foreign; self.boot = boot; self.wall = wall; self.continuous = continuous
    }
}
// Trusted service-side adapter, NOT an RPC payload or a client claim. Implementations must
// independently authorize prearm and use the shared persistent gate for autonomous restore.
public protocol AutomaticSessionBackend: Sendable {
    func observation() async throws -> AutomaticObservation
    func prearm(maximumSeconds: TimeInterval) async throws
    func pollRestoration(session: UUID) async throws
    func manualRecovery(session: UUID) async throws
    func sleepDisplayIfClosed(session: UUID) async throws
    func heartbeat(session: UUID) async throws
}
public extension AutomaticSessionBackend {
    func manualRecovery(session: UUID) async throws { throw PrivilegeError.blocked }
}
public actor AutomaticSessionService {
    public enum State: Sendable, Equatable {
        case off, blocked(String), preparing, prepared(UUID), closed(UUID), recovering(UUID), fault(String)
    }
    public private(set) var state = State.off
    public var deadline: Date? { known?.deadline }
    public private(set) var operationError: String?
    public private(set) var observedPower = ObservedSleep.unknown
    private let backend: any AutomaticSessionBackend
    private var desired = false
    private var busy = false
    private var running = false
    private var displayRequestSession: UUID?
    private var displayRequestError: String?
    private var exhausted = false
    public var sessionFinished: Bool { exhausted && known == nil }
    private var known: AutomaticLease?
    private var lastTime: TimeInterval?
    public init(backend: any AutomaticSessionBackend) { self.backend = backend }
    public func setDesired(_ on: Bool) async {
        if on && !desired { exhausted = false }
        desired = on
        await poll()
    }
    // Owned by a background host, independent of the SwiftUI panel. Nothing schedules
    // this from helper main until deployment/authorization/storage gates are satisfied.
    public func run(every interval: Duration = .seconds(5)) async throws {
        guard interval > .zero, !running else { throw PrivilegeError.busy }
        running = true; defer { running = false }
        while !Task.isCancelled {
            await poll()
            try await Task.sleep(for: interval)
        }
    }
    public func poll() async {
        guard !busy else { return }
        if known == nil && !desired && operationError == nil { state = .off; return }
        if known == nil && exhausted { state = .blocked("Предыдущая сессия завершена; требуется новое разрешение"); return }
        busy = true; defer { busy = false }
        do {
            let observation = try await backend.observation()
            if try await apply(observation, afterPrepare: false) {
                try await backend.prearm(maximumSeconds: FullGrantLifetimePolicy.productionMaximumLifetime)
                let result = try await backend.observation()
                _ = try await apply(result, afterPrepare: true)
            }
        } catch {
            observedPower = .unknown
            operationError = "Операция не подтверждена; обычный сон необходимо проверить"
            state = .fault(operationError!)
        }
    }
    // The actor serializes effects. The Rust decision uses current intent after each observation.
    private func apply(_ o: AutomaticObservation, afterPrepare: Bool) async throws -> Bool {
        observedPower = o.power
        let lease = o.lease
        let input = NeSpatAutoObservation(
            now: o.continuous, wall: o.wall.timeIntervalSinceReferenceDate, last_time: lastTime ?? 0,
            expires: lease?.expires ?? 0, deadline: lease?.deadline?.timeIntervalSinceReferenceDate ?? 0,
            maximum: FullGrantLifetimePolicy.productionMaximumLifetime, has_expiry: lease?.expires != nil,
            has_deadline: lease?.deadline != nil, has_lease: lease != nil, selected_lifetime: lease?.selectedLifetime == true,
            service_verified: o.serviceVerified, authorized: o.setupAuthorized, active_user: o.activeUser == true,
            recovery_only: o.recoveryOnly, foreign_owner: o.foreign, known: known != nil, boot_matches: lease?.boot == o.boot,
            known_boot_matches: known?.boot == o.boot, lease_matches: lease == known,
            start_safe: o.safety.activationAssessment == .noDangerDetected, running_safe: o.safety.emergencyAssessment == .noDangerDetected,
            desired: desired, exhausted: exhausted, lid_closed: o.lidClosed.map { $0 ? 1 : 0 } ?? -1,
            sleep_disabled: o.power == .enabled ? 0 : o.power == .disabled ? 1 : -1)
        let decision = nespat_auto_decide(input, afterPrepare)
        if decision.record_time { lastTime = o.continuous }
        if decision.adopt_lease { known = lease }
        if decision.forget_lease { known = nil; operationError = nil }
        if decision.mark_finished { exhausted = true }
        switch decision.action {
        case NSAutoPrepare: state = .preparing; return true
        case NSAutoOff: state = .off; operationError = nil
        case NSAutoRestore:
            guard let lease else { throw PrivilegeError.blocked }
            await restore(lease)
        case NSAutoKeepActive:
            guard let lease else { throw PrivilegeError.blocked }
            if !afterPrepare { try await backend.heartbeat(session: lease.id) }
            await updateActiveState(lease, closed: o.lidClosed == true)
        case NSAutoUnverified: state = .blocked("Фоновая служба не проверена")
        case NSAutoClock: state = .blocked("Неподтверждённое время")
        case NSAutoOwnership: state = .blocked("Владение автоматической сессией не подтверждено")
        case NSAutoReplaced: state = .blocked("Запись автоматической сессии изменилась")
        case NSAutoLost: state = .blocked("Журнал утрачен; сон не подтверждён")
        case NSAutoForeign: state = .blocked("Системный сон или чужое владение не подтверждены")
        case NSAutoFinished: state = .blocked("Предыдущая сессия завершена; требуется новое разрешение")
        case NSAutoUnauthorized: state = .blocked("Требуется подтверждённая первоначальная настройка")
        case NSAutoOpenLid: state = .blocked("Для подготовки нужен активный пользователь и открытая крышка")
        case NSAutoUnsafe: state = .blocked("Датчики неполны или условия небезопасны")
        default: state = .fault("Подготовка или владение не подтверждены")
        }
        return false
    }
    private func updateActiveState(_ lease: AutomaticLease, closed: Bool) async {
        if !closed {
            displayRequestSession = nil
            displayRequestError = nil
        } else if displayRequestSession != lease.id {
            displayRequestSession = lease.id
            displayRequestError = nil
            do { try await backend.sleepDisplayIfClosed(session: lease.id) }
            catch { displayRequestError = "Не удалось погасить экран. Сессия продолжается." }
        }
        operationError = displayRequestError
        state = closed ? .closed(lease.id) : .prepared(lease.id)
    }
    public func restoreNow() async {
        desired = false
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let observation = try await backend.observation(); observedPower = observation.power
            guard observation.serviceVerified, let lease = observation.lease, !observation.foreign,
                  lease.boot == observation.boot, known == nil || known == lease else { state = .blocked("Владение не подтверждено"); return }
            known = lease
            state = .recovering(lease.id)
            try await backend.manualRecovery(session: lease.id)
            let result = try await backend.observation(); observedPower = result.power
            guard result.serviceVerified, result.boot == lease.boot, !result.foreign, result.power == .enabled, result.lease == nil else { operationError = "Обычный сон ещё не подтверждён"; return }
            known = nil; state = .off; operationError = nil
        } catch { observedPower = .unknown; operationError = "Ручное восстановление не подтверждено" }
    }
    private func restore(_ lease: AutomaticLease) async {
        state = .recovering(lease.id)
        do {
            // This is autonomous polling, NOT repeated manual .recover requests. The server
            // adapter must retain its persistent retry evidence across host restarts.
            try await backend.pollRestoration(session: lease.id)
            let value = try await backend.observation(); observedPower = value.power
            guard value.serviceVerified, value.boot == lease.boot, value.power == .enabled,
                  value.lease == nil, !value.foreign else {
                operationError = "Восстановление обычного сна ещё не подтверждено"; return
            }
            exhausted = desired
            known = nil; operationError = nil
            state = .off
        } catch { observedPower = .unknown; operationError = "Восстановление не подтверждено; повтор контролирует фоновая служба" }
    }
}
