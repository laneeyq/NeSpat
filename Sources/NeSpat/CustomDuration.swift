import Foundation
import NeSpatNative

enum CustomDuration {
    // Binary64 represents all integer seconds through 2^53 exactly.
    static let exactSeconds = 9_007_199_254_740_992.0
    struct Invalid: LocalizedError {
        var errorDescription: String? { "Введите положительное целое число минут, представимое без переполнения и потери точности срока." }
    }
    static func seconds(_ text: String) throws -> TimeInterval {
        guard !text.isEmpty, text.utf8.count <= String(Int.max).count,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let minutes = Int(text), minutes > 0 else { throw Invalid() }
        let seconds = nespat_minutes_to_seconds(Int64(minutes))
        guard seconds > 0 else { throw Invalid() }
        return Double(seconds)
    }
    static func deadline(seconds: TimeInterval, now: Date) throws -> Date {
        let start = now.timeIntervalSinceReferenceDate
        let end = start + seconds
        guard seconds.isFinite, seconds > 0, seconds <= exactSeconds,
              start.isFinite, end.isFinite, abs(end) <= exactSeconds, end > start,
              abs((end - start) - seconds) <= max(start.ulp, end.ulp) else { throw Invalid() }
        return Date(timeIntervalSinceReferenceDate: end)
    }
    static func validate(_ session: Session) throws {
        if let seconds = session.durationSeconds {
            guard seconds.isFinite, seconds > 0, seconds <= exactSeconds,
                  seconds.rounded() == seconds else { throw Invalid() }
        }
        if let date = session.until {
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  abs(date.timeIntervalSinceReferenceDate) <= exactSeconds else { throw Invalid() }
        }
    }
}
