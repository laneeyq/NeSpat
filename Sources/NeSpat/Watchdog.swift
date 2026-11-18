import Foundation

// Existing optional LaunchAgent only. No service is installed by building/running the GUI.
@MainActor
enum Watchdog {
    static func run() -> Never {
        let success = tick(dependencies: .live(), log: Log.watchdog)
        exit(success ? 0 : 1)
    }

    @discardableResult
    static func tick(dependencies d: AppModel.Dependencies, log: (String) -> Void) -> Bool {
        do {
            let unlock = try d.lock()
            defer { unlock() }
            var session = try d.load()
            guard session.owned else { return true }
            guard session.canRestore, let owner = session.owner,
                  let current = d.identity(), current.bootID == owner.bootID else {
                log("Ownership is ambiguous or from another boot; manual recovery required.")
                return false
            }
            let state = d.readState()
            if state == .enabled {
                try d.save(session.ended(reason: "Обычный сон подтверждён системой (сторож)"))
                return true
            }
            guard state == .disabled else {
                log("Sleep state unknown; session retained.")
                return false
            }
            let sample = d.sample(), serious = d.thermalSerious()
            // Watchdog retains restore-only safety fallback for its validated journal owner.
            let reason = !d.ownerAlive(owner) ? "приложение не запущено" : (
                SafetyPolicy.emergencyReason(sample: sample, thermalSerious: serious) ?? (
                    d.requireCompleteSafety && (!d.thermalAvailable() || SafetyPolicy.emergencyAssessment(sample: sample, thermalSerious: serious) == .unknown)
                    ? "обязательные датчики недоступны" : nil) ?? SafetyPolicy.restoreReason(
                    session: session, sample: sample, thermalSerious: serious, now: d.now()))
            guard let reason else { return true }
            if let retryAfter = session.retryAfter, retryAfter > d.now() { return false }
            // A background agent must not create a password-dialog storm. Cached authorization
            // is best effort only: there is NO promise of recovery after SIGKILL/logout/reboot.
            let outcome = d.setSleep(false, false)
            if d.readState() == .enabled {
                let message = outcome == .confirmed ? "Сон возвращён: \(reason) (сторож)" : "Обычный сон подтверждён системой (сторож)"
                try d.save(session.ended(reason: message))
                log(message)
                return true
            }
            session.needsAttention = true
            session.retryAfter = d.now().addingTimeInterval(300)
            session.lastReason = "Сторож не смог вернуть сон. Откройте NeSpat и восстановите сон с авторизацией."
            try d.save(session)
            log(session.lastReason!)
            return false
        } catch SessionError.busy {
            return true // GUI currently holds the lock; try again at the next LaunchAgent tick.
        } catch {
            log("Watchdog failed; session retained: \(error.localizedDescription)")
            return false
        }
    }
}
