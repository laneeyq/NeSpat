import Foundation

/// User-visible diagnostic history, NOT a journal, capability, owner or consent proof.
/// No power/quit/watchdog decision reads this record.
struct EmergencyReceipt: Codable, Equatable {
    enum Outcome: String, Codable { case restored, requested, failure }
    let session: UUID
    let recordedAt: Date
    let outcome: Outcome
    let message: String
    let retryAfter: Date?
    init(session: UUID, result: EmergencySleep.Result, recordedAt: Date) {
        self.session = session; self.recordedAt = recordedAt
        switch result {
        case .restored(let text): outcome = .restored; message = text; retryAfter = nil
        case .requested(let text): outcome = .requested; message = text; retryAfter = nil
        case .failure(let text, let retry): outcome = .failure; message = text; retryAfter = retry
        case .skipped: outcome = .failure; message = "Аварийная операция не выполнялась."; retryAfter = nil
        }
    }
}
enum EmergencyReceiptStore {
    static func save(_ receipt: EmergencyReceipt,
                     to file: URL = Paths.supportDir.appendingPathComponent("emergency-result.json")) throws {
        // A failed diagnostic write cannot erase or overwrite session.json recovery evidence.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
