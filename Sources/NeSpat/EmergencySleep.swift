import Foundation
import NeSpatPrivilegeCore

// GUI-owned session only. This does not extend the privileged helper or its RPC.
enum EmergencySleep {
    static let invocation = FixedPowerInvocation.emergencySleep // Same closed plan as the future helper.
    enum RequestResult { case requested, failed, blocked }
    enum Result: Equatable, Sendable {
        case skipped
        case restored(String)
        case requested(String)
        case failure(String, retryAfter: Date? = nil)
    }
    struct Snapshot {
        var sample: StatsSampler.Sample
        var thermalSerious: Bool
        var reason: String? { SafetyPolicy.emergencyReason(sample: sample, thermalSerious: thermalSerious) }
    }
    // Construct/use on one serial worker; never share a mutable StatsSampler across threads.
    struct Dependencies {
        var lock: () throws -> (() -> Void)
        var load: () throws -> Session
        var save: (Session) throws -> Void
        var identity: () -> ProcessIdentity?
        var readState: () -> SleepState
        var snapshot: () -> Snapshot
        var restore: () -> SleepControl.Outcome
        var request: () -> RequestResult
        var now: () -> Date
        // Diagnostic receipt only. Never read by ownership, restoration or consent code.
        var recordResult: (UUID, Result, Date) throws -> Void = { _, _, _ in }

        static func live() -> Self {
            let sampler = StatsSampler()
            return .init(lock: { try SessionStore.lock() }, load: { try SessionStore.load() },
                         save: { try SessionStore.save($0) }, identity: { ProcessIdentity.read(getpid()) },
                         readState: PowerInfo.observedSleepState,
                         snapshot: { Snapshot(sample: sampler.sample(), thermalSerious: SafetyPolicy.thermalEmergency(ProcessInfo.processInfo.thermalState)) },
                         restore: { SleepControl.setSleepDisabled(false, allowPrompt: false) },
                         request: blockedRequest, now: Date.init,
                         recordResult: { try EmergencyReceiptStore.save(.init(session: $0, result: $1, recordedAt: $2)) })
        }
    }
    // No switch, environment option or executable adapter can activate real sleepnow in v7.7.
    static func blockedRequest() -> RequestResult { .blocked }

    static func run(expectedSession: UUID, dependencies d: Dependencies) -> Result {
        let result = runLocked(expectedSession: expectedSession, dependencies: d)
        if result != .skipped {
            do { try d.recordResult(expectedSession, result, d.now()) }
            catch {
                // The original session evidence is untouched; do not repeat an emergency request.
                let detail: String
                switch result {
                case .failure(let message, _), .restored(let message), .requested(let message): detail = message
                case .skipped: detail = "Аварийная операция остановлена."
                }
                let retry: Date?
                if case .failure(_, let until) = result { retry = until } else { retry = nil }
                return .failure(detail + " Не удалось сохранить диагностический отчёт: \(error.localizedDescription)", retryAfter: retry)
            }
        }
        return result
    }

    private static func runLocked(expectedSession: UUID, dependencies d: Dependencies) -> Result {
        do {
            let unlock = try d.lock(); defer { unlock() }
            var session = try d.load()
            try CustomDuration.validate(session)
            guard session.identifier == expectedSession, session.belongsTo(d.identity()),
                  d.readState() == .disabled, let reason = d.snapshot().reason else { return .skipped }
            if session.emergencyAttempt != nil, let retry = session.retryAfter, retry > d.now() { return .skipped }
            let attempt = UUID()
            session.emergencyAttempt = attempt
            session.needsAttention = true
            session.lastReason = "Аварийная защита: \(reason). Обычный сон ещё не подтверждён."
            try d.save(session) // Persist intent BEFORE a potentially blocking restore.
            // Sampling can take time. Revalidate authority/state AFTER the final sample.
            guard d.snapshot().reason != nil,
                  try d.load() == session, session.belongsTo(d.identity()), d.readState() == .disabled else {
                return .failure("Аварийное восстановление остановлено: состояние или владелец изменились. Запись сохранена.")
            }
            _ = d.restore() // Exit status is not evidence of actual No.
            guard d.readState() == .enabled else {
                // Only an actual unsuccessful attempt starts/extends the failure cooldown.
                let retry = d.now().addingTimeInterval(300)
                do {
                    guard try d.load() == session, session.belongsTo(d.identity()) else {
                        return .failure("После попытки восстановления журнал или владелец изменились; запись не перезаписана.", retryAfter: retry)
                    }
                    session.retryAfter = retry
                    try d.save(session)
                } catch {
                    // The live GUI also retains this result locally if the journal write fails.
                    return .failure("Сон не восстановлен; не удалось сохранить ограничение повторов: \(error.localizedDescription). Запись требует проверки.", retryAfter: retry)
                }
                return .failure("Аварийная защита не подтвердила обычный сон. Запись сохранена; требуется восстановление.", retryAfter: retry)
            }
            guard try d.load() == session, session.belongsTo(d.identity()) else {
                return .failure("Сон наблюдался включённым, но журнал или владелец изменились; запрос сна остановлен.")
            }
            var ended = session.ended(reason: "Обычный сон подтверждён: аварийная защита (\(reason))")
            ended.emergencyAttempt = attempt // Receipt for this ended record, not authority to restore.
            try d.save(ended)
            // Final conflict/owner/AC/thermal checks under the SAME journal lock, right before request.
            guard try d.load() == ended, d.identity() == session.owner else {
                return .failure("Обычный сон был подтверждён; конфликт журнала/владельца остановил запрос сна.")
            }
            guard d.snapshot().reason != nil else {
                return .restored("Обычный сон восстановлен; аварийное условие больше не подтверждается.")
            }
            guard try d.load() == ended, d.identity() == session.owner, d.readState() == .enabled else {
                return .failure("Состояние сна, журнал или владелец изменились перед аварийным запросом. Запрос сна не выполнен.")
            }
            switch d.request() {
            case .requested: return .requested("Обычный сон восстановлен. Запрос аварийного сна отправлен (\(reason)); режим выключен.")
            case .failed: return .failure("Обычный сон восстановлен, но запрос аварийного сна (\(reason)) завершился ошибкой.")
            case .blocked: return .failure("Обычный сон восстановлен. Аварийный запрос сна (\(reason)) заблокирован на этапе v7.7.")
            }
        } catch {
            return .failure("Аварийная защита остановлена: \(error.localizedDescription). Проверьте сон и журнал восстановления.")
        }
    }
}
