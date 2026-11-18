import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore
@Suite struct InheritedSetterLockTests {
    @Test func ordinaryChildKeepsLockAfterParentClosesItsDescriptor() throws {
        try ProtectedJournalTests().fixture { directory, fd in
            let file = directory.appendingPathComponent("child-lock")
            let held = openat(fd, "child-lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(held >= 0); try #require(flock(held, LOCK_EX | LOCK_NB) == 0)
            let done = directory.appendingPathComponent("finish-child")
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-I", "-c", "import os,sys,time; end=time.monotonic()+5\nwhile not os.path.exists(sys.argv[1]) and time.monotonic()<end: time.sleep(0.01)", done.path]
            child.standardInput = FileHandle(fileDescriptor: held, closeOnDealloc: false)
            try child.run(); close(held)
            let next = open(file.path, O_RDWR | O_CLOEXEC); try #require(next >= 0); defer { close(next) }
            #expect(flock(next, LOCK_EX | LOCK_NB) != 0)
            try Data().write(to: done)
            child.waitUntilExit(); #expect(child.terminationStatus == 0)
            #expect(flock(next, LOCK_EX | LOCK_NB) == 0)
            _ = flock(next, LOCK_UN)
        }
    }
}
