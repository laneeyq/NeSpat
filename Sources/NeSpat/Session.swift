import Foundation
import Darwin

struct ProcessIdentity: Codable, Equatable {
    var pid: Int32
    var executable: String
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    var bootID: String

    static func read(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                == MemoryLayout.size(ofValue: info) else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0 else { return nil }
        var boot = [CChar](repeating: 0, count: 128)
        var size = boot.count
        guard sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0 else { return nil }
        return ProcessIdentity(
            pid: pid,
            executable: String(decoding: path.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self),
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            bootID: String(decoding: boot.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
    }

    var isAlive: Bool { Self.read(pid) == self }
}

// An intent is written atomically before pmset runs. An interrupted intent is NOT proof of ownership.
struct Session: Codable, Equatable {
    enum Phase: String, Codable { case pending, active }
    var owned = false
    var until: Date?
    var lastReason: String?
    var pid: Int32 = 0  // retained for reading the original file format
    var owner: ProcessIdentity?
    var originalSleepDisabled: Bool?
    var phase: Phase?
    var identifier: UUID?
    var needsAttention: Bool?
    var retryAfter: Date?
    /// Emergency attempt/ended-record receipt; never substitutes for ownership or actual No.
    var emergencyAttempt: UUID?
    /// Original selected limit, independent of the remaining time. Absent in older records.
    var durationSeconds: TimeInterval?

    var canRestore: Bool {
        owned && phase == .active && originalSleepDisabled == false && owner != nil && identifier != nil
    }

    func belongsTo(_ identity: ProcessIdentity?) -> Bool {
        canRestore && identity != nil && owner == identity
    }

    func ended(reason: String?) -> Session {
        var next = self
        next.owned = false
        next.phase = nil
        next.until = nil
        next.durationSeconds = nil
        next.needsAttention = nil
        next.retryAfter = nil
        next.emergencyAttempt = nil
        if let reason { next.lastReason = reason }
        return next
    }
}

enum SessionError: LocalizedError {
    case busy, unsafeFile, identityUnavailable
    var errorDescription: String? {
        switch self {
        case .busy: "Другой экземпляр NeSpat выполняет операцию. Повторите позже."
        case .unsafeFile: "Небезопасный файл состояния NeSpat: операция остановлена."
        case .identityUnavailable: "Не удалось определить процесс и загрузку macOS. Режим не включён."
        }
    }
}

enum SessionStore {
    static func load(from file: URL = Paths.sessionFile, validatingTimer: Bool = true) throws -> Session {
        do {
            let data = try Data(contentsOf: file)
            let session = try JSONDecoder().decode(Session.self, from: data)
            if validatingTimer { try CustomDuration.validate(session) }
            return session
        } catch CocoaError.fileReadNoSuchFile {
            return Session()
        }
    }

    static func save(_ session: Session, to file: URL = Paths.sessionFile) throws {
        try CustomDuration.validate(session)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // GUI instances and the existing optional watchdog use the same advisory lock.
    // O_CLOEXEC prevents a spawned authorization process from retaining this lock.
    static func lock(at file: URL = Paths.supportDir.appendingPathComponent("session.lock")) throws -> () -> Void {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SessionError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw SessionError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SessionError.busy
        }
        return { flock(fd, LOCK_UN); close(fd) }
    }
}
