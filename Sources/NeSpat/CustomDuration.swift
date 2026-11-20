import Foundation
import NeSpatNative

enum CustomDuration {
    // Binary64 represents all integer seconds through 2^53 exactly.
    static let exactSeconds = 9_007_199_254_740_992.0
    struct Invalid: LocalizedError {
        var errorDescription: String? { "Введите положительное целое число минут, представимое без переполнения и потери точности срока." }
    }
    static func seconds(_ text: String) throws -> TimeInterval {
        var input = text
        let seconds = input.withUTF8 { nespat_parse_minutes($0.baseAddress, $0.count) }
        guard seconds > 0 else { throw Invalid() }
        return Double(seconds)
    }
    static func deadline(seconds: TimeInterval, now: Date) throws -> Date {
        let end = nespat_deadline(now.timeIntervalSinceReferenceDate, seconds)
        guard end.isFinite else { throw Invalid() }
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
