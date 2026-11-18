import Foundation
import Testing
import Darwin
@testable import NeSpatLiveTestCore

struct DiskRig {
    let url: URL
    let binding: LiveBinding
    let store: LiveFileStore
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("nespat-live-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let boot = UUID()
        binding = LiveBinding(authorization: boot, boot: boot, session: UUID(), uid: getuid(), exclusiveControl: true, clientHash: "fixture-client", helperHash: "fixture-helper", recoveryHash: "fixture-recovery")
        store = try LiveFileStore.provisionFixture(directory: url, record: LiveRecord(version: 2, binding: binding, session: binding.session))
        try Data("rootless-no-power-v1".utf8).write(to: url.appendingPathComponent("fixture-only"))
        try Data("No".utf8).write(to: url.appendingPathComponent("mock-power"))
        try Data(binding.session.uuidString.utf8).write(to: url.appendingPathComponent("fixture-session"))
    }
    func cleanup() throws { try FileManager.default.removeItem(at: url) }
    func reopen() throws -> LiveFileStore {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0 else { throw LiveError.state }; defer { close(fd) }
        return try LiveFileStore(pinnedDirectory: fd, uid: getuid(), expected: binding)
    }
    func spawn(_ name: String, _ operation: String, time: Double) throws -> Process {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
        let configuration = "Debug", simple = "debug"
        #else
        let configuration = "Release", simple = "release"
        #endif
        let choices = [repo.appendingPathComponent(".build/out/Products/\(configuration)/\(name)"),repo.appendingPathComponent(".build/\(simple)/\(name)")]
        guard let binary = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw LiveError.state }
        let p = Process(); p.executableURL = binary; p.arguments = [operation, url.path, binding.boot.uuidString, String(time)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); return p
    }
    func child(_ name: String, _ operation: String, time: Double) throws -> Int32 {
        let p = try spawn(name, operation, time: time); p.waitUntilExit(); return p.terminationStatus
    }
}
@Suite struct LiveFileTests {
    @Test func transientJournalReaderDoesNotDropResultTransaction() throws {
        let f = try DiskRig()
        defer { try? f.cleanup() }
        let fd = open(f.url.appendingPathComponent("journal.lock").path, O_RDWR)
        guard fd >= 0 else { throw LiveError.state }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LiveError.state }
        let released = DispatchGroup()
        released.enter()
        let readerStarted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            readerStarted.signal()
            Thread.sleep(forTimeInterval: 0.02)
            _ = flock(fd, LOCK_UN)
            released.leave()
        }
        readerStarted.wait()
        defer { released.wait() }
        let record = try f.store.exclusive { try f.store.load() }
        #expect(record.binding == f.binding)
    }
    @Test func separateHelperExitsAndIndependentWatchdogCompletesAndRepeats() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        let expires = try f.store.exclusive { try f.store.load().expires }
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130) == 0)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 131) == 0)
        try f.store.exclusive { let r = try f.store.load(); #expect(r.phase == .completed && r.expires == expires && r.initiated == 130) }
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-power"), encoding: .utf8) == "No")
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 132) != 0)
    }
    @Test(arguments: [false, true]) func processCrashWindowsRecoverOnlyWithOwnAttemptAndObservedNo(_ after: Bool) throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", after ? "--fixture-crash-after" : "--fixture-crash-before", time: 10) == 86)
        let result = try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130)
        #expect(result == 0)
        let record = try f.store.exclusive { try f.store.load() }
        #expect(record.phase == .completed)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-power"), encoding: .utf8) == "No")
    }
    @Test func corruptMissingAndReplayForeignBindingAreBlocked() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }; let file = f.url.appendingPathComponent("session.json"), original = try Data(contentsOf: f.url.appendingPathComponent("session.json"))
        try Data("{}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try f.store.exclusive { _ = try f.store.load() } }
        try original.write(to: file)
        let fd = open(f.url.path, O_RDONLY | O_DIRECTORY); defer { close(fd) }
        let wrong = LiveBinding(authorization: UUID(), boot: f.binding.boot, session: f.binding.session, uid: getuid(), exclusiveControl: true, clientHash: "fixture-client", helperHash: "fixture-helper", recoveryHash: "fixture-recovery")
        let other = try LiveFileStore(pinnedDirectory: fd, uid: getuid(), expected: wrong)
        #expect(throws: (any Error).self) { try other.exclusive { _ = try other.load() } }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try f.store.exclusive { _ = try f.store.load() } }
    }
    @Test func hardlinkSymlinkAndLockSubstitutionStop() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }; let file = f.url.appendingPathComponent("session.json"), second = f.url.appendingPathComponent("second")
        guard link(file.path, second.path) == 0 else { throw LiveError.state }
        #expect(throws: (any Error).self) { try f.store.exclusive { _ = try f.store.load() } }
        try FileManager.default.removeItem(at: second)
        let lock = f.url.appendingPathComponent("journal.lock"); try FileManager.default.removeItem(at: lock)
        FileManager.default.createFile(atPath: lock.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        #expect(throws: (any Error).self) { try f.store.exclusive { _ = try f.store.load() } }
        try FileManager.default.moveItem(at: file, to: second); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: second)
        let reopened = try f.reopen()
        #expect(throws: (any Error).self) { try reopened.exclusive { _ = try reopened.load() } }
    }
    @Test func fileStoreCannotExtendExpiryOrResetConsumedGrant() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }; let backend = MockBackend(boot: f.binding.boot)
        let helper = LivePeer(role: .helper, uid: 0, pid: 1, started: 1, codeHash: f.binding.helperHash, signingID: LiveTestDeployment.helperID)
        let client = LivePeer(role: .client, uid: getuid(), pid: 2, started: 1, codeHash: f.binding.clientHash, signingID: LiveTestDeployment.clientID)
        try LiveController(store: f.store, backend: backend, actor: helper).arm(client: client, duration: 60)
        try f.store.exclusive {
            let old = try f.store.load(); var next = old; next.expires = old.issued!+120
            #expect(throws: (any Error).self) { _ = try f.store.save(next, replacing: old) }
            next = old; next.phase = .unused
            #expect(throws: (any Error).self) { _ = try f.store.save(next, replacing: old) }
        }
    }
    @Test func repeatedProcessRecoveryKeepsReservationAndOrdinaryCooldown() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-recovery-crash-before", time: 130) == 86)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 429) == 2)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 430) == 0)
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.expires == 130 && r.initiated == 130 && r.phase == .completed)
    }
    @Test func independentProcessesRespectBusySetterLockAndRetainObligation() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        let fd = open(f.url.appendingPathComponent("setter.lock").path, O_RDWR); defer { close(fd) }
        guard fd >= 0, flock(fd, LOCK_EX|LOCK_NB) == 0 else { throw LiveError.state }
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130) == 2)
        let blocked = try f.store.exclusive { try f.store.load() }
        #expect(blocked.initiated == 130 && blocked.retired && blocked.retry == nil)
        _ = flock(fd, LOCK_UN)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 131) == 0)
    }

    @Test func independentProcessExitZeroDoesNotCompleteWithoutObservedNo() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-arm", time: 10) == 0)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll-fail", time: 130) == 2)
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.phase == .recovery && r.retry != nil)
        #expect(try String(contentsOf: f.url.appendingPathComponent("mock-power"), encoding: .utf8) == "Yes")
    }
    @Test func unsafePermissionsAndExpectedOwnerAreRejected() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        let fd = open(f.url.path, O_RDONLY | O_DIRECTORY); defer { close(fd) }
        #expect(throws: (any Error).self) { _ = try LiveFileStore(pinnedDirectory: fd, uid: 0, expected: f.binding) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.url.appendingPathComponent("session.json").path)
        #expect(throws: (any Error).self) { try f.store.exclusive { _ = try f.store.load() } }
    }
    @Test func durableOwnAttemptCannotBeReplacedByAnotherValidNonce() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-crash-after", time: 10) == 86)
        try f.store.exclusive {
            let old = try f.store.load(); let proof = old.attempt!; var next = old
            next.attempt = LiveAttempt(session: proof.session, helper: proof.helper, client: proof.client, at: proof.at, nonce: UUID())
            #expect(throws: (any Error).self) { _ = try f.store.save(next, replacing: old) }
            #expect(try f.store.load() == old)
        }
    }

}
