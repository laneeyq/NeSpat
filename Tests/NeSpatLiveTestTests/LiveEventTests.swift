import Foundation
import Testing
import Darwin
@testable import NeSpatLiveTestCore

private final class PollCount: @unchecked Sendable {
    let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@Suite struct LiveEventTests {
    @Test func startupDeadlineAndOwnFileWritesDoNotCreateFastLoop() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        let fd = open(f.url.path, O_RDONLY | O_DIRECTORY); defer { close(fd) }
        let count = PollCount()
        let events = LiveRecoveryEvents(directoryFD: fd) {
            count.increment()
            // Models a poll persisting state in its watched directory.
            try? Data("event".utf8).write(to: f.url.appendingPathComponent("event"), options: .atomic)
        }
        try events.obligationChanged(expires: 130, continuousNow: 130)
        Thread.sleep(forTimeInterval: 1.3)
        #expect(count.count >= 1 && count.count <= 6)
        withExtendedLifetime(events) {}
    }
    @Test func eventDeadlineRejectsInvalidClockAndBoundsHugeDelay() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        let fd = open(f.url.path, O_RDONLY | O_DIRECTORY); defer { close(fd) }
        let events = LiveRecoveryEvents(directoryFD: fd) {}
        #expect(throws: (any Error).self) { try events.obligationChanged(expires: .nan, continuousNow: 0) }
        #expect(throws: (any Error).self) { try events.obligationChanged(expires: 120, continuousNow: -1) }
        try events.obligationChanged(expires: .greatestFiniteMagnitude, continuousNow: 0)
    }
}
