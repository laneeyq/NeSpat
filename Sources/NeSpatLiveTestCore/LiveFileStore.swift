import Foundation
import Darwin
import CryptoKit

/// Separate aggregate file. Authority+deadline+retry share one fsync/rename transaction.
/// No missing-file default and no reprovisioning path after one-shot consumption.
final class LiveFileStore: LiveStoring {
    private let directory: Int32
    private let lockFD: Int32
    private let uid: uid_t
    private let expected: LiveBinding
    private var held = false
    private let mutex = NSRecursiveLock()
    private struct Envelope: Codable { let payload: Data; let digest: String }
    init(pinnedDirectory: Int32, uid: uid_t, expected: LiveBinding) throws {
        directory = dup(pinnedDirectory); self.uid = uid; self.expected = expected
        guard directory >= 0 else { throw LiveError.state }
        do { try Self.check(directory, uid, true) } catch { close(directory); throw error }
        lockFD = openat(directory, "journal.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { close(directory); throw LiveError.state }
        do { try Self.check(lockFD, uid, false) } catch { close(lockFD); close(directory); throw error }
    }
    deinit { close(lockFD); close(directory) }
    private static func check(_ fd: Int32, _ uid: uid_t, _ dir: Bool) throws {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == uid,
              s.st_mode & S_IFMT == (dir ? S_IFDIR : S_IFREG), s.st_mode & 0o077 == 0,
              dir || s.st_nlink == 1 else { throw LiveError.state }
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw LiveError.state }
        guard errno == ENOENT else { throw LiveError.state }
    }
    func exclusive<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard !held else { throw LiveError.busy }
        // A short status read can overlap the result commit after a setter. Retry only
        // acquisition, never the transaction body or the command that preceded it.
        let limit = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw LiveError.state }
            guard ProcessInfo.processInfo.systemUptime < limit else { throw LiveError.busy }
            Thread.sleep(forTimeInterval: 0.002)
        }
        held = true; defer { held = false; _ = flock(lockFD, LOCK_UN) }
        try Self.check(directory, uid, true); try Self.check(lockFD, uid, false)
        var current = stat(); guard fstatat(directory, "journal.lock", &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw LiveError.state }
        var pinned = stat(); guard fstat(lockFD, &pinned) == 0, current.st_ino == pinned.st_ino, current.st_dev == pinned.st_dev else { throw LiveError.state }
        return try body()
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    func load() throws -> LiveRecord {
        guard held else { throw LiveError.state }
        try Self.check(directory, uid, true); try Self.check(lockFD, uid, false)
        var current = stat(), pinned = stat()
        guard fstatat(directory, "journal.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(lockFD, &pinned) == 0, current.st_ino == pinned.st_ino, current.st_dev == pinned.st_dev else { throw LiveError.state }
        let fd = openat(directory, "session.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw LiveError.state }; defer { close(fd) }
        try Self.check(fd, uid, false)
        var s = stat(); guard fstat(fd, &s) == 0, s.st_size > 0, s.st_size <= 16384 else { throw LiveError.state }
        var bytes = [UInt8](repeating: 0, count: 16385)
        let n = read(fd, &bytes, bytes.count); guard n == s.st_size else { throw LiveError.state }
        let data = Data(bytes.prefix(n)), envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard data == (try encode(envelope)), envelope.digest == Self.digest(envelope.payload) else { throw LiveError.state }
        let r = try JSONDecoder().decode(LiveRecord.self, from: envelope.payload)
        guard envelope.payload == (try encode(r)), r.binding == expected else { throw LiveError.denied }; try r.validate()
        return r
    }
    func save(_ record: LiveRecord, replacing old: LiveRecord) throws -> LiveRecord {
        guard held, try load() == old, old.generation < UInt64.max else { throw LiveError.state }
        var next = record; next.generation = old.generation+1; try next.validate()
        guard next.binding == old.binding, next.session == old.session,
              old.issued == nil || (next.issued == old.issued && next.expires == old.expires && next.owner == old.owner),
              !old.consumed || next.consumed,
              old.issued == nil || (next.baselineNo == old.baselineNo && next.admission == old.admission),
              old.attempt == nil || next.attempt == old.attempt,
              !old.interferenceDetected || next.interferenceDetected,
              next.failedAttempts >= old.failedAttempts else { throw LiveError.denied }
        try write(next); return next
    }
    private static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func write(_ record: LiveRecord) throws {
        let payload = try encode(record)
        let data = try encode(Envelope(payload: payload, digest: Self.digest(payload)))
        guard data.count <= 16384 else { throw LiveError.state }
        let name = "candidate-" + UUID().uuidString
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LiveError.state }
        defer { close(fd) }
        do {
            try data.withUnsafeBytes { b in
                var offset = 0
                while offset < b.count { let n = Darwin.write(fd, b.baseAddress!.advanced(by: offset), b.count-offset); guard n > 0 else { throw LiveError.state }; offset += n }
            }
            guard fsync(fd) == 0 else { throw LiveError.state }
            guard renameat(directory, name, directory, "session.json") == 0, fsync(directory) == 0 else { throw LiveError.state }
        } catch { throw error }
    }
    /// Provisioning is test-only and never substitutes absence for a new grant.
    static func provisionFixture(directory: URL, record: LiveRecord) throws -> LiveFileStore {
        guard geteuid() != 0 else { throw LiveError.denied }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LiveError.state }; defer { close(fd) }
        let existing = openat(fd, "session.json", O_RDONLY | O_NOFOLLOW)
        guard existing < 0, errno == ENOENT else { if existing >= 0 { close(existing) }; throw LiveError.state }
        let store = try LiveFileStore(pinnedDirectory: fd, uid: getuid(), expected: record.binding)
        try record.validate(); try store.exclusive { try store.write(record) }; return store
    }
}
