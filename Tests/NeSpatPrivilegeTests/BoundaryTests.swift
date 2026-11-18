import Foundation
import Darwin
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct PrivilegeBoundaryTests {
    func canonical(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
    @Test func strictSchemaRejectsCommandPathShellAndIdentityClaims() throws {
        let base: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": "status"]
        #expect(try Request.decode(canonical(base)).operation == .status)
        for (key, value) in ["command":"id", "path":"/bin/sh", "script":"$(touch /tmp/injected)",
                             "argv":"-c id", "environment":"DYLD_INSERT_LIBRARIES=x", "uid":"0", "pid":"1", "file":"/etc/sudoers", "service":"other.daemon"] {
            var fields = base; fields[key] = value
            #expect(throws: (any Error).self) { try Request.decode(canonical(fields)) }
        }
        for bad in ["{", "[]", "null", String(repeating: "a", count: 4097),
                    "{\"version\":1,\"version\":1,\"id\":\"\(UUID())\",\"operation\":\"status\"}"] {
            #expect(throws: (any Error).self) { try Request.decode(Data(bad.utf8)) }
        }
        for value: Any in [true, 2, -1, "1", NSNull()] {
            var fields = base; fields["version"] = value
            #expect(throws: (any Error).self) { try Request.decode(canonical(fields)) }
        }
    }
    @Test func fixedInvocationPlansHaveNoCallerArguments() {
        #expect(FixedPowerInvocation.disableSleep.executable == "/usr/bin/pmset")
        #expect(FixedPowerInvocation.disableSleep.arguments == ["-a", "disablesleep", "1"])
        #expect(FixedPowerInvocation.restoreSleep.arguments == ["-a", "disablesleep", "0"])
    }
    @Test func invalidNumericInputsAndArgumentShapes() throws {
        for value: Any in [0, -1, 1.5, true, "500", NSNumber(value: UInt64.max)] {
            let data = try canonical(["version": 1, "id": UUID().uuidString, "operation":"begin", "minutes":value])
            #expect(throws: (any Error).self) { try Request.decode(data) }
        }
        #expect(throws: (any Error).self) { try Request(operation: .begin, minutes: Int.max).validate() }
        #expect(throws: (any Error).self) { try Request(operation: .status, minutes: 5).validate() }
        #expect(throws: (any Error).self) { try Request(operation: .end).validate() }
        #expect(throws: (any Error).self) { try Request(operation: .begin, minutes: 1).deadline(now: Date(timeIntervalSinceReferenceDate: .infinity)) }
        for minutes in [1, 35, 165, 480, 481, 500, 1440, 10000] {
            #expect(try Request.interval(minutes) == Double(minutes) * 60)
        }
    }
    @Test func disabledDeploymentDoesNotConnectRegisterOrUnregister() throws {
        #expect(!PrivilegeDeployment.enabled)
        #expect(throws: PrivilegeError.blocked) { try PrivilegeDeployment.register() }
        #expect(throws: PrivilegeError.blocked) { try PrivilegeDeployment.unregister() }
        #expect(throws: PrivilegeError.blocked) { try PrivilegeClient.connect(policy: SigningPolicy(teamID: "ABCDE12345")) }
    }
    @Test func realRequirementCompilerRejectsInjectionAndRealAppleCodeWithWrongIdentity() throws {
        for invalid in ["", "ANY", "ABCDE12345\" or true", "abcdefghij", "../escape"] {
            #expect(throws: PrivilegeError.blocked) { try SigningPolicy(teamID: invalid) }
        }
        let policy = try SigningPolicy(teamID: "ABCDE12345")
        #expect(policy.guiRequirement.contains("identifier \"local.nespat.app\""))
        #expect(policy.helperRequirement.contains("identifier \"local.nespat.privilege-helper\""))
        #expect(!policy.matchesFile(URL(fileURLWithPath: "/usr/bin/true"), helper: false))
        #expect(!policy.matchesFile(URL(fileURLWithPath: "/usr/bin/true"), helper: true))
    }
    @Test func readOnlyUnsignedDataAndCurrentExecutableFailPublisherRequirement() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent(".build/signature-fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = try SigningPolicy(teamID: "ABCDE12345")
        let unsigned = dir.appendingPathComponent("unsigned")
        try Data("unsigned data, never executed".utf8).write(to: unsigned)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        for file in [unsigned, executable] {
            #expect(!policy.matchesFile(file, helper: false))
            #expect(!policy.matchesFile(file, helper: true))
        }
        // No signing/removal commands. Spoofed-identifier fixture signing from v7.1
        // cannot be repeated under v7.2 constraints; it is not claimed as current coverage.
    }

    @Test func malformedPayloadFuzzNeverReachesExecutor() throws {
        // Deterministic hostile byte corpus, not a claim of exhaustive fuzzing.
        let f = PrivilegeFixture(); try f.admit()
        for size in 0..<512 {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ size) })
            do { _ = try f.engine.handle(Request.decode(data), from: f.peer); Issue.record("Accepted arbitrary bytes") }
            catch { }
        }
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}

@Suite struct ProtectedJournalTests {
    func fixture(_ body: (URL, Int32) throws -> Void) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent(".build/privilege-fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw PrivilegeError.journal }; defer { close(fd) }
        try body(dir, fd)
    }
    @Test func realFileRoundTripLockAndUserJSONSeparation() throws {
        try fixture { dir, fd in
            let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            let other = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            let record = PrivilegedRecord(id: UUID(), owner: Peer(connection: UUID(), uid: 501, auditSession: 1), bootID: UUID(), baselineEnabled: true, phase: .active, deadline: Date())
            try Data(#"{"owned":true,"pid":1}"#.utf8).write(to: dir.appendingPathComponent("session.json"))
            try store.exclusive {
                #expect(try store.load() == nil) // User journal is never consulted.
                #expect(throws: PrivilegeError.busy) { try other.exclusive { } }
                try store.save(record); #expect(try store.load() == record)
            }
            try other.exclusive { #expect(try other.load() == record); try other.save(nil) }
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("authority.json").path)
            #expect(attrs[.posixPermissions] as? Int == 0o600)
            #expect(throws: PrivilegeError.journal) { try store.load() }
        }
    }
    @Test func symlinksHardlinksWritableFilesAndWrongOwnerAreRejected() throws {
        for variant in 0..<5 {
            try fixture { dir, fd in
                if variant == 4 {
                    #expect(throws: PrivilegeError.journal) { try ProtectedJournal(testDirectoryFD: fd, owner: getuid() + 1) }; return
                }
                let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
                let file = dir.appendingPathComponent("authority.json")
                let target = dir.appendingPathComponent("target"); try Data("untrusted".utf8).write(to: target)
                if variant == 0 { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
                if variant == 1 { try FileManager.default.linkItem(at: target, to: file) }
                if variant == 2 { try Data("untrusted".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions:0o666], ofItemAtPath:file.path) }
                if variant == 3 { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
                #expect(throws: (any Error).self) { try store.exclusive { try store.load() } }
                #expect(throws: (any Error).self) { try store.exclusive { try store.save(nil) } }
                #expect(try Data(contentsOf: target) == Data("untrusted".utf8))
            }
        }
    }
    @Test func corruptTruncatedOversizedAndUnknownVersionAreNotEmptyState() throws {
        for bytes in [Data("{".utf8), Data(repeating:0,count:8193), Data(#"{"version":2}"#.utf8)] {
            try fixture { dir, fd in
                let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
                let file = dir.appendingPathComponent("authority.json"); try bytes.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
                #expect(throws: (any Error).self) { try store.exclusive { try store.load() } }
                #expect(throws: (any Error).self) { try store.exclusive { try store.save(nil) } }
                #expect(try Data(contentsOf:file) == bytes)
            }
        }
    }
    @Test func productionWalkerRejectsUserWritableParentsAndLinks() throws {
        try fixture { dir, _ in
            #expect(throws: PrivilegeError.journal) { try ProtectedJournal(path: dir.path, owner:0) }
            let link = dir.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL:dir)
            #expect(throws: PrivilegeError.journal) { try ProtectedJournal(path:link.path, owner:getuid()) }
        }
    }
    @Test func actualSecondProcessCannotTakeHeldJournalLock() throws {
        try fixture { dir, fd in
            let store = try ProtectedJournal(testDirectoryFD: fd, owner: getuid())
            func child() throws -> Int32 {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1], 'r+');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(77)", dir.appendingPathComponent("lock").path]
                try p.run(); p.waitUntilExit(); return p.terminationStatus
            }
            try store.exclusive {
                let status = try child(); #expect(status == 77)
            }
            let released = try child(); #expect(released == 0)
        }
    }
}
