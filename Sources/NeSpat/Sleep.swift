import Foundation
import NeSpatPrivilegeCore

// MARK: - Состояние сна системы (IOKit, без subprocess в установившемся режиме)

enum SleepState: Equatable, Sendable {
    case enabled      // обычный сон
    case disabled     // сон выключен
    case unknown      // не удалось прочитать
}

enum PowerInfo {
    /// IOPMrootDomain: SleepDisabled (источник правды на macOS 27).
    static func sleepState() -> SleepState {
        switch SystemSleepObservation.read() {
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .unknown: return .unknown
        }
    }

    static func observedSleepState() -> SleepState {
        let state = sleepState()
        return state == .unknown ? (sleepStateViaPmset() ?? .unknown) : state
    }

    /// Крышка закрыта? nil, если свойство недоступно.
    static func lidClosed() -> Bool? {
        SystemSessionObservation.lidClosed()
    }

    /// Запасной источник: pmset -g (на macOS 27 строка может отсутствовать).
    static func sleepStateViaPmset() -> SleepState? {
        let r = Proc.run("/usr/bin/pmset", ["-g"])
        guard r.ok else { return nil }
        return parsePmset(r.out)
    }

    static func parsePmset(_ output: String) -> SleepState? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0] == "SleepDisabled" else { continue }
            switch parts[1] {
            case "0": return .enabled
            case "1": return .disabled
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Управление сном

enum SleepControl {
    enum Outcome: Equatable {
        case confirmed
        case notConfirmed
        case canceled   // владелец отменил диалог пароля
    }

    /// Commands have fixed executable paths and arguments; tests replace both execution and observation.
    @discardableResult
    static func setSleepDisabled(
        _ disabled: Bool, allowPrompt: Bool = true,
        run: (String, [String]) -> Proc.Result = Proc.run,
        readState: () -> SleepState = PowerInfo.sleepState,
        wait: (TimeInterval) -> Void = Thread.sleep
    ) -> Outcome {
        let fast = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        if fast.ok {
            return verify(disabled, run: run, readState: readState, wait: wait) ? .confirmed : .notConfirmed
        }
        guard allowPrompt, fast.code >= 0 else { return .notConfirmed }
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let result = run("/usr/bin/osascript", ["-e", "do shell script \"\(command)\" with administrator privileges"])
        if result.ok {
            return verify(disabled, run: run, readState: readState, wait: wait) ? .confirmed : .notConfirmed
        }
        // Match the actual AppleScript cancellation code, not a localized word or substring.
        if result.err.range(of: #"\(-128\)\s*$"#, options: .regularExpression) != nil { return .canceled }
        return .notConfirmed
    }

    static func verify(
        _ expectDisabled: Bool,
        run: (String, [String]) -> Proc.Result = Proc.run,
        readState: () -> SleepState = PowerInfo.sleepState,
        wait: (TimeInterval) -> Void = Thread.sleep
    ) -> Bool {
        for _ in 0..<5 {
            var state = readState()
            if state == .unknown {
                let result = run("/usr/bin/pmset", ["-g"])
                if result.ok { state = PowerInfo.parsePmset(result.out) ?? .unknown }
            }
            if state == (expectDisabled ? .disabled : .enabled) { return true }
            wait(0.2)
        }
        return false
    }

    static func displaysleepnow() -> Proc.Result { Proc.displaysleepnow() }
}
