// TEST TARGET ONLY. No production import, listener, executor or deployment.
import Foundation
import Darwin
import CryptoKit
@testable import NeSpatPrivilegeCore

enum PCError: Error, Equatable { case storage, binding, denied, clock, throttled, unconfirmed, crash }
enum PCPoint: String, CaseIterable { case beforeReservation, afterWitnessPrepare, afterFileSync, afterRename, afterWitnessCommit, afterReservation, duringSetter, afterSetter, beforeConfirmation, beforeCleanup }
struct PCAuthority: Codable, Equatable {
    let record: PrivilegedRecord
    let generation: UInt64
}
struct PCRetry: Codable, Equatable {
    let authority: PCAuthority
    let nonce: UUID
    var since: Double
    var last: Double
    let delay: Double
    var failed: Bool
    var timeTrusted: Bool
}
struct PCEnvelope: Codable, Equatable {
    var version = 1
    var revision: UInt64
    var authority: PCAuthority?
    var retry: PCRetry?
}
struct PCStamp: Equatable { let revision: UInt64; let digest: String }
// MOCK independent non-rollback witness. Kept across store objects, not a production trust anchor.
final class PCWitness {
    var current: PCStamp?
    var pending: PCStamp?
    func reconcile(_ stamp: PCStamp) throws {
        if stamp == current { pending = nil; return }
        if stamp == pending { current = stamp; pending = nil; return }
        throw PCError.storage
    }
}
final class PCStore {
    let fd: Int32
    let lock: ProtectedJournal
    let witness: PCWitness
    var hook: (PCPoint) throws -> Void = { _ in }
    init(directoryFD: Int32, witness: PCWitness) throws {
        fd = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw PCError.storage }
        do { lock = try ProtectedJournal(testDirectoryFD: directoryFD, owner: getuid()) }
        catch { close(fd); throw error }
        self.witness = witness
    }
    deinit { close(fd) }
    static func bytes(_ value: PCEnvelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func stamp(_ value: PCEnvelope, _ data: Data) -> PCStamp {
        PCStamp(revision: value.revision, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private func check(_ f: Int32) throws {
        var s = stat()
        guard fstat(f, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG,
              s.st_mode & 0o077 == 0, s.st_nlink == 1, s.st_size <= 65536 else { throw PCError.storage }
        errno = 0
        if let acl = acl_get_fd_np(f, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw PCError.storage }
        guard errno == ENOENT else { throw PCError.storage }
    }
    private func raw() throws -> Data {
        let f = openat(fd, "combined.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard f >= 0 else { throw PCError.storage }; defer { close(f) }
        try check(f)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(f, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PCError.storage }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65536 else { throw PCError.storage }
        }
        return data
    }
    func load() throws -> PCEnvelope {
        let data = try raw(), value = try JSONDecoder().decode(PCEnvelope.self, from: data)
        guard value.version == 1, value.revision > 0, try Self.bytes(value) == data else { throw PCError.storage }
        try witness.reconcile(Self.stamp(value, data)); return value
    }
    // Caller holds lock.exclusive. A single envelope avoids split authority/retry commits.
    func save(_ value: PCEnvelope) throws {
        let data = try Self.bytes(value), stamp = Self.stamp(value, data)
        if let current = witness.current {
            guard current.revision < UInt64.max, value.revision == current.revision + 1,
                  SHA256.hash(data: try raw()).map({ String(format: "%02x", $0) }).joined() == current.digest else { throw PCError.storage }
        } else {
            var existing = stat()
            guard value.revision == 1, fstatat(fd, "combined.json", &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw PCError.storage }
        }
        witness.pending = stamp; try hook(.afterWitnessPrepare)
        let name = ".combined-\(UUID().uuidString)"
        let f = openat(fd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { throw PCError.storage }; defer { close(f); _ = unlinkat(fd, name, 0) }
        try check(f)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(f, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw PCError.storage }; offset += n
            }
        }
        guard fsync(f) == 0 else { throw PCError.storage }; try hook(.afterFileSync)
        guard renameat(fd, name, fd, "combined.json") == 0, fsync(fd) == 0 else { throw PCError.storage }
        try hook(.afterRename)
        witness.current = stamp; witness.pending = nil; try hook(.afterWitnessCommit)
    }
    // Explicit fixture bootstrap, never an RPC or recovery fallback.
    func provision(_ authority: PCAuthority) throws {
        try lock.exclusive { try save(PCEnvelope(revision: 1, authority: authority, retry: nil)) }
    }
}

// Mock authenticated dispatch context: no decoding/API to mint a grant from retry data.
struct PCRecoveryContext {
    let peer: Peer
    let hasRecoveryScope: Bool
    let operation: NeSpatPrivilegeCore.Operation
}
enum PCManualPolicy: Equatable { case sharedBudget, authorizedBypass }
final class PCPrototype {
    let store: PCStore
    let boot: UUID
    let delay: Double
    let manual: PCManualPolicy
    let clock: () -> Double
    let observe: () -> ObservedSleep
    let setter: () throws -> Void
    let authorize: (PCRecoveryContext?) throws -> Void
    var hook: (PCPoint) throws -> Void = { _ in }
    init(store: PCStore, boot: UUID, delay: Double, manual: PCManualPolicy,
         clock: @escaping () -> Double, observe: @escaping () -> ObservedSleep,
         authorize: @escaping (PCRecoveryContext?) throws -> Void, setter: @escaping () throws -> Void) throws {
        guard delay.isFinite, delay > 0 else { throw PCError.clock }
        self.store = store; self.boot = boot; self.delay = delay; self.manual = manual
        self.clock = clock; self.observe = observe; self.setter = setter; self.authorize = authorize
    }
    func recover(expected: PCAuthority, context: PCRecoveryContext?) throws {
        try store.lock.exclusive {
            try authorize(context)
            try expected.record.validateOwnership(boot: boot)
            try expected.record.validateTimer()
            guard expected.generation > 0, expected.record.phase == .active else { throw PCError.binding }
            if let context {
                guard context.hasRecoveryScope, context.peer.sameOwner(as: expected.record.owner),
                      [.recover, .revoke].contains(context.operation) else { throw PCError.denied }
            }
            var value = try store.load()
            guard value.authority == expected else { throw PCError.binding }
            if let retry = value.retry {
                guard retry.authority == expected, retry.delay == delay,
                      retry.since.isFinite, retry.last.isFinite, retry.since >= 0, retry.last >= retry.since else { throw PCError.binding }
            }
            let state = observe()
            guard try store.load() == value else { throw PCError.binding }
            if state == .enabled { try cleanup(&value); return }
            guard state == .disabled else { throw PCError.unconfirmed }
            let sample = clock()
            let bypass = context != nil && manual == .authorizedBypass
            let validTime = sample.isFinite && sample >= 0 && (value.retry.map({ sample >= $0.last }) ?? true)
            guard validTime else { throw PCError.clock }
            let time = validTime ? sample : (value.retry?.last ?? 0)
            if var retry = value.retry {
                if !retry.timeTrusted && !bypass {
                    retry.since = time; retry.last = time; retry.timeTrusted = true; value.retry = retry
                    try bump(&value); throw PCError.throttled
                }
                if time - retry.since < delay && !bypass {
                    retry.last = time; value.retry = retry
                    try bump(&value); throw PCError.throttled
                }
            }
            try hook(.beforeReservation)
            value.retry = PCRetry(authority: expected, nonce: UUID(), since: time, last: time, delay: delay, failed: false, timeTrusted: validTime)
            try bump(&value); try hook(.afterReservation)
            guard try store.load() == value, observe() == .disabled else { throw PCError.binding }
            try hook(.duringSetter)
            try authorize(context)
            guard try store.load() == value else { throw PCError.binding }
            do { try setter() }
            catch {
                if error as? PCError == .crash { throw error }
                try finishFailure(&value); throw error
            }
            try hook(.afterSetter); try hook(.beforeConfirmation)
            guard try store.load() == value else { throw PCError.binding }
            guard observe() == .enabled else { try finishFailure(&value); throw PCError.unconfirmed }
            try cleanup(&value)
        }
    }
    private func bump(_ value: inout PCEnvelope) throws {
        guard value.revision < UInt64.max else { throw PCError.storage }
        value.revision += 1; try store.save(value)
    }
    private func finishFailure(_ value: inout PCEnvelope) throws {
        guard try store.load() == value, var retry = value.retry else { throw PCError.binding }
        let time = clock()
        // Invalid completion clock leaves the conservative in-flight reservation intact.
        if time.isFinite && time >= retry.last { retry.since = time; retry.last = time; retry.timeTrusted = true }
        else { retry.timeTrusted = false }
        retry.failed = true; value.retry = retry; try bump(&value)
    }
    private func cleanup(_ value: inout PCEnvelope) throws {
        try hook(.beforeCleanup)
        guard try store.load() == value, observe() == .enabled else { throw PCError.binding }
        value.authority = nil; value.retry = nil; try bump(&value)
    }
}
