import AppKit
import Foundation
import SwiftUI
import NeSpatPrivilegeCore

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable { case on, off, foreign, unknown }

    // Test seams for every system-changing operation. Production uses the same code paths.
    struct Dependencies {
        var readState: () -> SleepState
        var setSleep: (Bool, Bool) -> SleepControl.Outcome
        var load: () throws -> Session
        var save: (Session) throws -> Void
        var lock: () throws -> (() -> Void)
        var identity: () -> ProcessIdentity?
        var ownerAlive: (ProcessIdentity) -> Bool
        var now: () -> Date
        var sample: () -> StatsSampler.Sample
        var thermalSerious: () -> Bool
        var lidClosed: () -> Bool?
        var sleepDisplay: () -> Proc.Result
        var loadForRecovery: (() throws -> Session)? = nil
        var loadPreference: () -> String? = { nil }
        var savePreference: (String) -> Void = { _ in }
        var thermalAvailable: () -> Bool = { false }
        var requireCompleteSafety = true // Safety is strict unless a test explicitly selects compatibility.
        var emergency: (@MainActor (UUID) async -> EmergencySleep.Result)? = nil

        static func live() -> Self {
            let sampler = StatsSampler()
            return Self(
                readState: PowerInfo.observedSleepState,
                setSleep: { SleepControl.setSleepDisabled($0, allowPrompt: $1) },
                load: { try SessionStore.load() }, save: { try SessionStore.save($0) },
                lock: { try SessionStore.lock() }, identity: { ProcessIdentity.read(getpid()) },
                ownerAlive: { $0.isAlive }, now: Date.init, sample: sampler.sample,
                thermalSerious: { SafetyPolicy.thermalEmergency(ProcessInfo.processInfo.thermalState) },
                lidClosed: PowerInfo.lidClosed, sleepDisplay: SleepControl.displaysleepnow,
                loadForRecovery: { try SessionStore.load(validatingTimer: false) },
                loadPreference: { UserDefaults.standard.string(forKey: "durationChoice.v6") },
                savePreference: { UserDefaults.standard.set($0, forKey: "durationChoice.v6") },
                thermalAvailable: {
                    switch ProcessInfo.processInfo.thermalState {
                    case .nominal, .fair, .serious, .critical: return true
                    @unknown default: return false
                    }
                },
                requireCompleteSafety: true,
                emergency: { id in
                    await Task.detached(priority: .userInitiated) {
                        EmergencySleep.run(expectedSession: id, dependencies: .live())
                    }.value
                }
            )
        }
    }

    enum Duration: String, CaseIterable, Identifiable {
        case none = "Без лимита"
        case h1 = "1 ч"
        case h3 = "3 ч"
        case h8 = "8 ч"
        case test = "2 мин (тест)"
        case saved = "До срока"
        case custom = "Своя"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .none, .saved, .custom: nil
            case .h1: 3600
            case .h3: 10800
            case .h8: 28800
            case .test: 120
            }
        }
    }

    @Published var menuTitle = "…"
    @Published private(set) var status: Status = .unknown
    @Published var sample = StatsSampler.Sample()
    @Published private(set) var duration: Duration = .none
    @Published private(set) var durationError: String?
    @Published private(set) var customMinutes: Int?
    @Published private(set) var countdownDeadline: Date?
    @Published private(set) var lastReason: String?
    @Published private(set) var operationError: String?
    @Published private(set) var busy = false
    @Published var launchAtLogin = false

    let testTimerAvailable: Bool
    private let dependencies: Dependencies
    private var timer: Timer?
    private var emergencyTask: Task<Void, Never>?
    // Failure evidence only, never ownership. Covers a failed cooldown write in this GUI process.
    private var emergencyFailureRetry: (session: UUID, until: Date)?
    private var session = Session()
    // One request per confirmed closed-lid interval and owned session, including adoption.
    // A failed request or a display wake/hotplug does not start a forced-sleep loop.
    private var displaySleepSession: UUID?
    // A missing/replaced journal must not erase this process's unresolved history.
    // This flag is not evidence authorizing a power change.
    private var journalRecoveryRequired = false
    private var lastLocalSessionID: UUID?
    private var hasLocalSessionHistory = false
    private enum ErrorContext { case sleep, observation, emergency, other }
    private var errorContext = ErrorContext.other
    private var ownsSession: Bool { !journalRecoveryRequired && session.belongsTo(dependencies.identity()) }

    init(testTimer: Bool, dependencies: Dependencies? = nil, startTimer: Bool = true) {
        self.dependencies = dependencies ?? .live()
        testTimerAvailable = testTimer
        restorePreference()
        if startTimer { launchAtLogin = LoginItem.isEnabled }
        perform {
            _ = try refresh(adopt: true)
        }
        tick()
        if startTimer {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    var durations: [Duration] {
        Duration.allCases.filter {
            if $0 == .custom { return duration == .custom }
            if $0 == .saved { return duration == .saved }
            if $0 == .test { return testTimerAvailable || duration == .test }
            return true
        }
    }

    var emergencyInProgress: Bool { emergencyTask != nil }
    var modeIsOn: Bool { status == .on }
    var canToggleMode: Bool { !busy && (status == .off || status == .on) }
    var showsRestoreAction: Bool { status == .foreign || status == .unknown || operationError != nil }
    // Presentation reads only the last validated deadline, never system metrics or the journal.
    var remaining: TimeInterval? { remaining(at: dependencies.now()) }

    func remaining(at date: Date) -> TimeInterval? {
        countdownDeadline.map { max(0, $0.timeIntervalSince(date)) }
    }

    var statusText: String { statusText(at: dependencies.now()) }

    func statusText(at date: Date) -> String {
        if emergencyInProgress { return "Аварийная защита · восстановление обычного сна" }
        switch status {
        case .on:
            if let remaining = remaining(at: date) {
                if remaining == 0 { return "Время истекло · обычный сон ещё не подтверждён" }
                return "Включено · осталось \(Fmt.duration(remaining))"
            }
            return "Включено · подтверждено системой"
        case .off: return "Выключено · обычный сон"
        case .foreign: return "Сон выключен · владелец режима не подтверждён"
        case .unknown: return "Не удалось подтвердить состояние сна"
        }
    }

    private func reportError(_ message: String, context: ErrorContext = .other) {
        operationError = message
        errorContext = context
    }

    private func restorePreference() {
        guard let value = dependencies.loadPreference() else { return }
        if value.hasPrefix("custom:"), let seconds = try? CustomDuration.seconds(String(value.dropFirst(7))),
           (try? CustomDuration.deadline(seconds: seconds, now: dependencies.now())) != nil {
            duration = .custom; customMinutes = Int(seconds / 60)
        } else if let preset = Duration(rawValue: value), preset != .custom, preset != .saved,
                  preset != .test || testTimerAvailable {
            duration = preset
        } else { durationError = "Сохранённая длительность повреждена; выберите срок заново." }
    }

    private func persistPreference() {
        if duration == .custom, let minutes = customMinutes {
            dependencies.savePreference("custom:\(minutes)")
        } else if duration != .saved { dependencies.savePreference(duration.rawValue) }
    }

    private func synchronizeDuration() {
        guard ownsSession else {
            if duration == .saved || (duration == .test && !testTimerAvailable) { duration = .none }
            return
        }
        guard session.until != nil else { duration = .none; return }
        if let seconds = session.durationSeconds, seconds > 0, seconds <= CustomDuration.exactSeconds,
           seconds.truncatingRemainder(dividingBy: 60) == 0,
           !Duration.allCases.contains(where: { $0.seconds == seconds }) {
            customMinutes = Int(seconds / 60)
            duration = .custom
        } else {
            duration = Duration.allCases.first { $0.seconds != nil && $0.seconds == session.durationSeconds } ?? .saved
        }
        persistPreference()
    }

    func setDuration(_ duration: Duration) {
        // A legacy deadline has no recoverable original preset. Selecting its label is a no-op.
        guard duration != .saved, duration != .custom else { return }
        perform {
            _ = try refresh()
            if ownsSession {
                var next = session
                next.until = duration.seconds.map { dependencies.now().addingTimeInterval($0) }
                next.durationSeconds = duration.seconds
                try persist(next)
            }
            self.duration = duration
            durationError = nil
            persistPreference()
            countdownDeadline = ownsSession ? session.until : nil
        }
    }

    private var selectedSeconds: TimeInterval? {
        duration == .custom ? customMinutes.map { Double($0) * 60 } : duration.seconds
    }

    func applyCustomMinutes(_ text: String) {
        let seconds: TimeInterval
        let end: Date
        do {
            seconds = try CustomDuration.seconds(text)
            end = try CustomDuration.deadline(seconds: seconds, now: dependencies.now())
        } catch { durationError = error.localizedDescription; return }
        perform {
            _ = try refresh()
            guard canToggleMode || status == .off || ownsSession else { throw CustomDuration.Invalid() }
            if ownsSession {
                var next = session
                next.until = end; next.durationSeconds = seconds
                try persist(next)
            }
            customMinutes = Int(seconds / 60); duration = .custom
            durationError = nil
            persistPreference()
            countdownDeadline = ownsSession ? session.until : nil
        }
    }

    func tick() {
        guard !busy else { return }
        var emergencyID: UUID?
        perform(reportBusy: false) {
            sample = dependencies.sample()
            let state = try refresh()
            let lid = dependencies.lidClosed()
            if lid == false { displaySleepSession = nil }
            guard ownsSession else { return }
            if let retry = emergencyFailureRetry, session.identifier == retry.session,
               retry.until > dependencies.now() { return }
            if SafetyPolicy.emergencyReason(sample: sample, thermalSerious: dependencies.thermalSerious()) != nil {
                // Emergency takes priority over an expired countdown. No independent polling loop.
                if state == .disabled,
                   session.emergencyAttempt == nil || session.retryAfter.map({ $0 <= dependencies.now() }) ?? true {
                    emergencyID = session.identifier
                }
                return
            }
            if dependencies.requireCompleteSafety, !dependencies.thermalAvailable() || SafetyPolicy.emergencyAssessment(sample: sample, thermalSerious: dependencies.thermalSerious()) == .unknown,
               session.retryAfter.map({ $0 <= dependencies.now() }) ?? true {
                _ = try restore(reason: "обязательные датчики недоступны", allowPrompt: false)
                return // Unknown never authorizes forced sleep.
            }
            if let reason = SafetyPolicy.restoreReason(session: session, sample: sample,
                                                       thermalSerious: dependencies.thermalSerious(), now: dependencies.now()),
               session.retryAfter.map({ $0 <= dependencies.now() }) ?? true {
                _ = try restore(reason: reason, allowPrompt: session.needsAttention != true)
                return
            }
            sleepDisplaysIfNeeded(state: state, lid: lid)
        }
        if let emergencyID { startEmergency(emergencyID) }
    }

    private func sleepDisplaysIfNeeded(state: SleepState, lid: Bool?) {
        guard ownsSession, let id = session.identifier else {
            displaySleepSession = nil; return
        }
        if lid == false { displaySleepSession = nil }
        guard state == .disabled else { return } // Uncertainty is not a new lid-close event.
        guard lid == true, displaySleepSession != id else { return }
        displaySleepSession = id // Consume before the one-shot request, even on failure.
        let result = dependencies.sleepDisplay() // All displays; no external-monitor veto.
        if !result.ok { reportError("Не удалось погасить экран: \(result.err)") }
    }

    private func startEmergency(_ id: UUID) {
        guard !busy, emergencyTask == nil else { return }
        guard let runner = dependencies.emergency else {
            reportError("Аварийная защита недоступна: восстановление и запрос сна не выполнены.", context: .emergency)
            updateMenuTitle(); return
        }
        busy = true
        emergencyTask = Task { @MainActor [weak self] in
            let result = await runner(id)
            guard let self else { return }
            self.emergencyTask = nil
            self.busy = false
            // Retain actual failure evidence even if refresh/lock/journal reading below fails.
            if case .failure(_, let retry?) = result {
                self.emergencyFailureRetry = (id, retry)
            }
            self.perform {
                let state = try self.refresh()
                switch result {
                case .failure(let message, let retry):
                    if retry != nil, state == .enabled {
                        self.operationError = nil // New independent No resolves an earlier restore failure.
                    } else {
                        self.reportError(message, context: retry == nil ? .emergency : .sleep)
                    }
                case .restored(let message), .requested(let message):
                    self.lastReason = message
                    self.operationError = nil
                case .skipped: break
                }
            }
        }
        updateMenuTitle()
    }

    // Test synchronization; no separate safety timer or user-triggerable production execution path.
    func waitForEmergency() async { await emergencyTask?.value }

    @discardableResult
    private func perform(reportBusy: Bool = true, _ operation: () throws -> Void) -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false; updateMenuTitle() }
        do {
            let unlock = try dependencies.lock()
            defer { unlock() }
            try operation()
            return true
        } catch {
            if !reportBusy, case SessionError.busy = error {
                reportError("Состояние сна временно не подтверждено: другой экземпляр NeSpat выполняет операцию.", context: .observation)
                status = .unknown
                return false
            }
            if case SessionError.identityUnavailable = error {
                reportError(error.localizedDescription, context: .sleep)
            } else {
                reportError(error.localizedDescription)
            }
            status = .unknown
            return false
        }
    }

    private func persist(_ next: Session) throws {
        try dependencies.save(next)
        session = next
        lastReason = next.lastReason
        rememberLocalSessionClaim()
        synchronizeDuration()
    }

    private func rememberLocalSessionClaim() {
        let identity = dependencies.identity()
        if !journalRecoveryRequired, session.owned, identity != nil, session.owner == identity {
            hasLocalSessionHistory = true
            lastLocalSessionID = session.identifier
        }
    }

    private func confirmOrdinarySleep() {
        emergencyFailureRetry = nil
        journalRecoveryRequired = false
        lastLocalSessionID = nil
        hasLocalSessionHistory = false
    }

    @discardableResult
    private func refresh(adopt: Bool = false, recovery: Bool = false) throws -> SleepState {
        session = try (recovery ? dependencies.loadForRecovery ?? dependencies.load : dependencies.load)()
        if !recovery { try CustomDuration.validate(session) }
        let state = dependencies.readState()
        let identity = dependencies.identity()
        if hasLocalSessionHistory,
           !session.belongsTo(identity) || session.identifier != lastLocalSessionID,
           state != .enabled {
            journalRecoveryRequired = true
        }
        if state == .enabled { confirmOrdinarySleep() }
        if adopt, !journalRecoveryRequired, session.canRestore, !session.belongsTo(identity), let identity,
           let owner = session.owner, owner.bootID == identity.bootID, !dependencies.ownerAlive(owner) {
            var adopted = session
            adopted.owner = identity
            adopted.pid = identity.pid
            try persist(adopted)
        }
        if state == .enabled, session.owned,
           session.owner == identity, identity != nil {
            try persist(session.ended(reason: "Обычный сон подтверждён системой"))
        }
        if state == .enabled, !session.owned, session.needsAttention == true,
           session.owner == nil || session.owner == identity {
            try persist(session.ended(reason: "Обычный сон подтверждён системой"))
        }
        switch state {
        case .enabled: status = .off
        case .disabled: status = ownsSession ? .on : .foreign
        case .unknown: status = .unknown
        }
        if state != .enabled, session.owned, !session.canRestore {
            reportError("Незавершённая или старая сессия. Владение изменением не доказано; проверьте сон и восстановите его явно.", context: .sleep)
        } else if state != .enabled, let owner = session.owner, session.owned,
                  let identity, owner.bootID != identity.bootID {
            reportError("Сессия от предыдущей загрузки macOS. Автоматическое восстановление запрещено; проверьте сон.", context: .sleep)
        }
        if state != .enabled, session.needsAttention == true, let reason = session.lastReason {
            reportError(reason, context: .sleep)
        }
        if journalRecoveryRequired {
            reportError("Запись активной сессии утрачена или заменена. Обычный сон не подтверждён; требуется явное восстановление. Выход остановлен.", context: .sleep)
        }
        rememberLocalSessionClaim()
        if state == .enabled, errorContext == .sleep { operationError = nil }
        if state != .unknown, errorContext == .observation { operationError = nil }
        if !recovery { synchronizeDuration() }
        countdownDeadline = !recovery && ownsSession ? session.until : nil
        lastReason = state == .enabled && session.needsAttention == true
            ? "Обычный сон подтверждён системой" : session.lastReason
        return state
    }

    private func updateMenuTitle() {
        let temp = TemperatureReader.validCelsius(sample.temperatureC).map { "\(Int($0.rounded()))°" } ?? "—"
        let cpu = sample.cpuPercent.flatMap { $0.isFinite && (0...100).contains($0) ? "\(Int($0.rounded()))%" : nil } ?? "—"
        let mem = sample.memTotalBytes > 0
            ? "\(Int(min(100, Double(sample.memUsedBytes) / Double(sample.memTotalBytes) * 100).rounded()))%" : "—"
        let icon: String?
        switch status {
        case .on: icon = emergencyInProgress || operationError != nil || session.needsAttention == true ? "⚠" : "☕"
        case .unknown, .foreign: icon = "⚠"
        case .off: icon = operationError != nil ? "⚠" : nil
        }
        let title = ([icon].compactMap { $0 } + [temp, cpu, mem]).joined(separator: " ")
        if title != menuTitle { menuTitle = title }
    }

    func toggle(_ on: Bool) {
        perform {
            operationError = nil
            let state = try refresh(adopt: true)
            if !on {
                _ = try restore(reason: nil)
                return
            }
            if ownsSession { return }
            guard state == .enabled else {
                reportError("Режим не включён: исходное состояние сна не подтверждено или флаг уже установлен другим приложением.", context: .sleep)
                return
            }
            sample = dependencies.sample()
            if dependencies.requireCompleteSafety, !dependencies.thermalAvailable() || SafetyPolicy.assessment(sample: sample, thermalSerious: dependencies.thermalSerious()) == .unknown {
                reportError("Режим не включён: обязательные датчики недоступны.", context: .sleep)
                return
            }
            if let reason = SafetyPolicy.unsafeReason(sample: sample, thermalSerious: dependencies.thermalSerious()) {
                reportError("Режим не включён: \(reason).", context: .sleep)
                return
            }
            guard let identity = dependencies.identity() else { throw SessionError.identityUnavailable }
            var pending = Session(owned: true,
                                  until: try selectedSeconds.map { try CustomDuration.deadline(seconds: $0, now: dependencies.now()) },
                                  pid: identity.pid, owner: identity, originalSleepDisabled: false,
                                  phase: .pending, identifier: UUID(), durationSeconds: selectedSeconds)
            // Failure here prevents pmset from being executed at all.
            try persist(pending)
            let outcome = dependencies.setSleep(true, true)
            let observed = dependencies.readState()
            if outcome == .confirmed, observed == .disabled {
                pending.phase = .active
                try persist(pending)
                status = .on
                countdownDeadline = pending.until
                sleepDisplaysIfNeeded(state: observed, lid: dependencies.lidClosed())
            } else {
                let message = outcome == .canceled ? "Авторизация отменена." : "Изменение сна не подтверждено."
                pending.lastReason = message + " Проверьте фактическое состояние сна."
                if observed == .enabled { pending = pending.ended(reason: pending.lastReason) }
                try persist(pending)
                reportError(pending.lastReason ?? message, context: .sleep)
                status = observed == .enabled ? .off : (observed == .disabled ? .foreign : .unknown)
            }
        }
    }

    // This is the only explicit user action allowed to reset an unowned/ambiguous flag.
    func forceRestoreSleep() {
        perform {
            operationError = nil
            _ = try refresh(recovery: true)
            _ = try restore(reason: nil, explicitForeign: true)
        }
    }

    @discardableResult
    private func restore(reason: String?, allowPrompt: Bool = true, explicitForeign: Bool = false) throws -> Bool {
        let state = dependencies.readState()
        guard ownsSession || explicitForeign else { return true }
        if explicitForeign, let owner = session.owner, owner != dependencies.identity(),
           dependencies.ownerAlive(owner) {
            reportError("Сессией управляет другой запущенный экземпляр NeSpat. Выключите режим в нём.", context: .sleep)
            return false
        }
        if state == .enabled {
            confirmOrdinarySleep()
            try persist(session.ended(reason: "Обычный сон подтверждён системой"))
            status = .off
            countdownDeadline = nil
            operationError = nil
            return true
        }
        guard state == .disabled else {
            reportError("Не удалось прочитать состояние сна. Запись сессии сохранена; восстановление не выполнено.", context: .sleep)
            status = .unknown
            return false
        }
        let outcome = dependencies.setSleep(false, allowPrompt)
        let observed = dependencies.readState()
        if observed == .enabled {
            confirmOrdinarySleep()
            let message = outcome == .confirmed
                ? (reason.map { "Сон возвращён: \($0)" } ?? "Сон возвращён")
                : "Обычный сон подтверждён системой; выполнение команды не подтверждено"
            try persist(session.ended(reason: message))
            status = .off
            countdownDeadline = nil
            operationError = nil
            return true
        }
        var failed = session
        failed.needsAttention = true
        failed.retryAfter = dependencies.now().addingTimeInterval(300)
        failed.lastReason = outcome == .canceled
            ? "Восстановление отменено. Сон может оставаться выключенным."
            : "Сон не восстановлен. Требуется повторная попытка с авторизацией."
        do { try CustomDuration.validate(failed); try persist(failed) }
        catch is CustomDuration.Invalid { /* Preserve the original damaged journal on failed recovery. */ }
        reportError(failed.lastReason ?? "Сон не восстановлен.", context: .sleep)
        status = observed == .unknown ? .unknown : (ownsSession ? .on : .foreign)
        return false
    }

    func setLaunchAtLogin(_ on: Bool) {
        operationError = nil
        if !LoginItem.setEnabled(on) { reportError("Не удалось изменить запуск при входе.") }
        launchAtLogin = LoginItem.isEnabled
    }

    /// Открыть системный «Мониторинг системы» (Activity Monitor).
    func openActivityMonitor() {
        let candidates = [
            "/System/Applications/Utilities/Activity Monitor.app",
            "/Applications/Utilities/Activity Monitor.app"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    // The delegate calls this for the button, Cmd-Q, ordinary termination and logout.
    // SIGKILL and forced logout/reboot cannot execute this code.
    func prepareToQuit() -> Bool {
        var safe = false
        let completed = perform {
            let state = try refresh()
            let identity = dependencies.identity()
            if state == .enabled {
                safe = true
            } else if session.owned, identity == nil {
                reportError("Не удалось подтвердить владельца сессии. Проверьте сон; выход остановлен.", context: .sleep)
            } else if journalRecoveryRequired {
                if session.canRestore, let owner = session.owner, let identity,
                   owner != identity, owner.bootID == identity.bootID, dependencies.ownerAlive(owner) {
                    safe = true // The confirmed foreign owner remains responsible; no power change.
                } else {
                    reportError("Журнал активной сессии утрачен или заменён; обычный сон не подтверждён. Выход остановлен.", context: .sleep)
                }
            } else if ownsSession {
                safe = try restore(reason: "выход из приложения")
                if safe, dependencies.readState() != .enabled {
                    safe = false
                    status = .unknown
                    reportError("Обычный сон после восстановления не подтверждён; выход остановлен.", context: .sleep)
                }
            } else if session.owned || session.phase != nil {
                if session.canRestore, let owner = session.owner, let identity,
                   owner != identity, owner.bootID == identity.bootID, dependencies.ownerAlive(owner) {
                    safe = true // A confirmed live foreign owner remains responsible for its session.
                } else {
                    reportError("Неполная или неподтверждённая сессия: обычный сон не подтверждён. Используйте явное восстановление; выход остановлен.", context: .sleep)
                }
            } else {
                safe = true
            }
        }
        return completed && safe
    }

    func quit() { NSApp.terminate(nil) }
}

enum SafetyPolicy {
    // Activation may be refused before the emergency threshold; this must not end an active mode.
    static func unsafeReason(sample: StatsSampler.Sample, thermalSerious: Bool) -> String? {
        snapshot(sample, thermalSerious).activationRefusalReason
    }

    static func thermalEmergency(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    static func emergencyReason(sample: StatsSampler.Sample, thermalSerious: Bool) -> String? {
        snapshot(sample, thermalSerious).emergencyReason
    }

    static func emergencyAssessment(sample: StatsSampler.Sample, thermalSerious: Bool) -> PowerSafetySnapshot.Assessment {
        snapshot(sample, thermalSerious).emergencyAssessment
    }
    static func assessment(sample: StatsSampler.Sample, thermalSerious: Bool) -> PowerSafetySnapshot.Assessment {
        snapshot(sample, thermalSerious).activationAssessment
    }
    private static func snapshot(_ sample: StatsSampler.Sample, _ thermalSerious: Bool) -> PowerSafetySnapshot {
        PowerSafetySnapshot(batteryPercent: sample.batteryLevel, externalPowerConnected: sample.externalPowerConnected,
                            temperatureC: sample.temperatureC, thermalSerious: thermalSerious)
    }

    // Normal completion is deadline-only. Emergencies have explicit higher priority in tick().
    static func restoreReason(session: Session, sample: StatsSampler.Sample, thermalSerious: Bool, now: Date) -> String? {
        if let until = session.until, until <= now { return "таймер закончился" }
        return nil
    }
}
