import NeSpatNative
import Foundation
import CryptoKit
import Darwin

// File-system seam is internal for unprivileged fixture tests. Wire API never accepts a path.
public final class ProtectedJournal: PersistentRecoveryJournal {
    private let directory: Int32
    private let lockFD: Int32
    private var requireProvisioned = false
    private let uid: uid_t
    private var held = false
    private let mutex = NSRecursiveLock()
    private struct Envelope: Codable { let version: Int; let record: PrivilegedRecord?; let generation: UInt64?; let retry: RecoveryRetry?; var lastCompleted: UUID? = nil }

    // The production location is fixed, pre-provisioned by a separately approved installer.
    // It is deliberately not created by this process or derived from a user preference.
    public static func openSystemJournal(requireProvisioned: Bool = false) throws -> ProtectedJournal {
        let journal = try ProtectedJournal(path: "/Library/Application Support/NeSpatPrivileged/State", owner: 0)
        journal.requireProvisioned = requireProvisioned
        return journal
    }
    init(path: String, owner: uid_t) throws {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw PrivilegeError.journal }
        uid = owner
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PrivilegeError.journal }
        do {
            try Self.check(fd, directory: true, owner: owner)
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PrivilegeError.journal }
                close(fd); fd = next
                try Self.check(fd, directory: true, owner: owner)
            }
            directory = fd
            let locked = openat(fd, "lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard locked >= 0 else { throw PrivilegeError.journal }
            do { try Self.check(locked, directory: false, owner: owner) }
            catch { close(locked); throw error }
            lockFD = locked
        } catch { close(fd); throw error }
    }
    // Test adapter pins an already open fixture directory; does not relax the production walker.
    init(testDirectoryFD fd: Int32, owner: uid_t) throws {
        uid = owner
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw PrivilegeError.journal }
        do { try Self.check(copy, directory: true, owner: owner) } catch { close(copy); throw error }
        directory = copy
        let lock = openat(copy, "lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { close(copy); throw PrivilegeError.journal }
        do { try Self.check(lock, directory: false, owner: owner) } catch { close(lock); close(copy); throw error }
        lockFD = lock
    }
    deinit { close(lockFD); close(directory) }
    public func exclusive<T>(_ body: () throws -> T) throws -> T {
        guard mutex.try() else { throw PrivilegeError.busy }
        defer { mutex.unlock() }
        guard !held, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw PrivilegeError.busy }
        held = true; defer { held = false; _ = flock(lockFD, LOCK_UN) }
        try Self.check(directory, directory: true, owner: uid)
        try Self.check(lockFD, directory: false, owner: uid)
        return try body()
    }
    private struct Integrity: Codable { let payload: Data; let sha256: String }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func envelope() throws -> Envelope {
        guard held else { throw PrivilegeError.journal }
        var bytes = [UInt8](repeating: 0, count: 8193)
        let count = bytes.withUnsafeMutableBufferPointer { nespat_journal_read(directory, uid, $0.baseAddress, $0.count) }
        if count == -2 && !requireProvisioned { return Envelope(version: 2, record: nil, generation: 0, retry: nil) }
        guard count >= 0 else { throw PrivilegeError.journal }
        var payload = Data(bytes.prefix(Int(count)))
        if requireProvisioned {
            let box = try JSONDecoder().decode(Integrity.self, from: payload)
            guard box.sha256 == digest(box.payload), try canonical(box) == payload else { throw PrivilegeError.journal }
            payload = box.payload
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        if requireProvisioned, try canonical(envelope) != payload { throw PrivilegeError.journal }
        guard (envelope.version == 1 && envelope.generation == nil && envelope.retry == nil) || (envelope.version == 2 && (envelope.generation ?? 0) > 0) else { throw PrivilegeError.journal }
        if requireProvisioned {
            guard envelope.version == 2, let generation = envelope.generation, generation > 0 else { throw PrivilegeError.journal }
            if let retry = envelope.retry {
                guard retry.generation == generation, retry.record == envelope.record else { throw PrivilegeError.journal }
            }
        }
        return envelope
    }
    func recoveryTicket() throws -> String { try digest(canonical(envelope())) }
    func confirmsCompletion(of id: UUID) throws -> Bool {
        let value = try envelope()
        return requireProvisioned && value.record == nil && value.lastCompleted == id
    }
    public func load() throws -> PrivilegedRecord? { try envelope().record }
    public func recoverySnapshot() throws -> RecoverySnapshot {
        let value = try envelope()
        if let retry = value.retry {
            guard retry.record == value.record, retry.generation == value.generation else { throw PrivilegeError.ownership }
        }
        return RecoverySnapshot(generation: value.generation ?? 0, retry: value.retry)
    }
    public func saveRecoveryRetry(_ retry: RecoveryRetry, expected: PrivilegedRecord, generation: UInt64) throws {
        let value = try envelope()
        guard generation > 0, value.generation == generation, value.record == expected,
              retry.generation == generation, retry.record == expected else { throw PrivilegeError.ownership }
        try writeEnvelope(Envelope(version: 2, record: expected, generation: generation, retry: retry))
    }
    public func save(_ record: PrivilegedRecord?) throws {
        let value = try envelope()
        var generation = value.generation ?? 0
        if value.record != record || generation == 0 {
            guard generation < UInt64.max else { throw PrivilegeError.journal }; generation += 1
        }
        var retry = value.retry
        if let record, let previous = value.record, record.id == previous.id,
           record.owner == previous.owner, record.bootID == previous.bootID,
           record.baselineEnabled == previous.baselineEnabled, record.phase == previous.phase {
            retry?.record = record; retry?.generation = generation
        } else { retry = nil }
        try writeEnvelope(Envelope(version: 2, record: record, generation: generation, retry: retry, lastCompleted: record == nil ? value.record?.id ?? value.lastCompleted : nil))
    }
    private func writeEnvelope(_ value: Envelope) throws {
        guard held else { throw PrivilegeError.journal }
        _ = try envelope()
        let payload = try canonical(value)
        let data = requireProvisioned ? try canonical(Integrity(payload: payload, sha256: digest(payload))) : payload
        let saved = data.withUnsafeBytes { bytes in
            nespat_journal_write(directory, uid, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard saved else { throw PrivilegeError.journal }
    }
    private static func check(_ fd: Int32, directory: Bool, owner: uid_t) throws {
        guard nespat_journal_check(fd, directory, owner) else { throw PrivilegeError.journal }
    }
}
