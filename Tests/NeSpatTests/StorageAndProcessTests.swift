import Foundation
import Darwin
import Testing
@testable import NeSpat

@Suite
struct StorageAndProcessTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func durableSessionRoundTripMissingAndCorruptFiles() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        #expect(try SessionStore.load(from: file) == Session())
        let original = Session(owned: true, originalSleepDisabled: false, phase: .pending, identifier: UUID())
        try SessionStore.save(original, to: file)
        #expect(try SessionStore.load(from: file) == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        try Data("corrupt".utf8).write(to: file)
        #expect(throws: (any Error).self) { try SessionStore.load(from: file) }
    }

    @Test func legacyRecordDoesNotProveOwnership() throws {
        let data = Data(#"{"owned":true,"pid":123}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        #expect(session.owned)
        #expect(!session.canRestore)
    }

    @Test func realLockExcludesOtherDescriptorsAndRejectsSymlink() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.lock")
        let unlock = try SessionStore.lock(at: file)
        #expect(throws: SessionError.self) { try SessionStore.lock(at: file) }
        unlock()
        let unlockAgain = try SessionStore.lock(at: file); unlockAgain()
        let link = dir.appendingPathComponent("link.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: SessionError.self) { try SessionStore.lock(at: link) }
    }

    @Test func currentProcessIdentityMatchesExactlyAndPIDReuseDoesNot() throws {
        let identity = try #require(ProcessIdentity.read(getpid()))
        #expect(identity.isAlive)
        #expect(!identity.executable.isEmpty)
        #expect(!identity.bootID.isEmpty)
        var reused = identity; reused.startMicroseconds += 1
        #expect(!reused.isAlive)
        var wrongPath = identity; wrongPath.executable += "-NeSpat-impostor"
        #expect(!wrongPath.isAlive)
    }

    @Test func stderrLargerThanPipeCapacityCannotDeadlock() {
        let result = Proc.runTimed("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=256 >&2; printf done"], timeout: 5)
        #expect(result.ok)
        #expect(result.out == "done")
        #expect(result.err.utf8.count >= 262_144)
    }

    @Test func stuckCommandTimesOutAndMissingExecutableFails() {
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = Proc.runTimed("/bin/sleep", ["5"], timeout: 0.05)
        #expect(timeout.code == -2)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(!Proc.run("/does/not/exist", []).ok)
    }

    @Test func cpuTicksHandleSignedBoundaryAndWrap() {
        // CPU_STATE_USER=0, SYSTEM=1, IDLE=2, NICE=3 on this SDK.
        var previous = [UInt32](repeating: 0, count: Int(CPU_STATE_MAX))
        var current = previous
        previous[Int(CPU_STATE_USER)] = UInt32.max - 5
        current[Int(CPU_STATE_USER)] = 4 // ten user ticks through overflow
        current[Int(CPU_STATE_IDLE)] = 10
        #expect(StatsSampler.cpuUsage(current: current, previous: previous) == 50)
        previous[Int(CPU_STATE_USER)] = UInt32(Int32.max)
        current[Int(CPU_STATE_USER)] = UInt32(Int32.max) + 10
        #expect(StatsSampler.cpuUsage(current: current, previous: previous) == 50)
        #expect(StatsSampler.cpuUsage(current: current, previous: nil) == nil)
        #expect(StatsSampler.cpuUsage(current: current, previous: []) == nil)
    }
}
