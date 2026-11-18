import Foundation

/// Scheduling seam for the existing engine, not another owner or authority source.
/// Nothing starts it in helper main. The future approved daemon supplies its interval.
public actor HelperWatchdog {
    public enum Outcome: Equatable, Sendable {
        case notChecked, checked, recoveryRequired
    }
    public private(set) var outcome = Outcome.notChecked
    private let engine: PrivilegeEngine
    private var running = false
    public init(engine: PrivilegeEngine) { self.engine = engine }

    @discardableResult public func poll() -> Outcome {
        do { try engine.tick(); outcome = .checked }
        catch { outcome = .recoveryRequired }
        // 'checked' is not an OFF report. Only independent SleepDisabled observation is one.
        return outcome
    }
    public func run(every interval: Duration) async throws {
        guard interval > .zero, !running else { throw PrivilegeError.blocked }
        running = true; defer { running = false }
        while !Task.isCancelled {
            poll() // Restores own evidence on expiry/loss, never sends sleepnow.
            try await Task.sleep(for: interval)
        }
    }
}
