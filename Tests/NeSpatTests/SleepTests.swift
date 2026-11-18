import Testing
@testable import NeSpat

@Suite
struct SleepTests {
    @Test func strictPmsetParsing() {
        #expect(PowerInfo.parsePmset(" SleepDisabled\t1\n") == .disabled)
        #expect(PowerInfo.parsePmset("SleepDisabled 0") == .enabled)
        #expect(PowerInfo.parsePmset("SleepDisabled unexpected") == nil)
        #expect(PowerInfo.parsePmset("System-wide power settings:") == nil)
    }

    @Test func commandSuccessRequiresSystemConfirmation() {
        var commands: [(String, [String])] = []
        let result = SleepControl.setSleepDisabled(true, run: { path, args in
            commands.append((path, args)); return .init(code: 0, out: "", err: "")
        }, readState: { .enabled }, wait: { _ in })
        #expect(result == .notConfirmed)
        #expect(commands.count == 1)
        #expect(commands[0].0 == "/usr/bin/sudo")
        #expect(commands[0].1 == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }

    @Test func promptCancellationIsNotSuccessEvenIfStateMatches() {
        var commands = 0
        let result = SleepControl.setSleepDisabled(false, run: { _, _ in
            commands += 1
            return .init(code: 1, out: "", err: commands == 2 ? "execution error: User canceled. (-128)\n" : "password required")
        }, readState: { .enabled }, wait: { _ in })
        #expect(result == .canceled)
        #expect(commands == 2)
    }

    @Test func watchdogDoesNotPrompt() {
        var commands = 0
        let result = SleepControl.setSleepDisabled(false, allowPrompt: false, run: { path, _ in
            commands += 1; #expect(path == "/usr/bin/sudo")
            return .init(code: 1, out: "", err: "password required")
        }, readState: { .disabled }, wait: { _ in })
        #expect(result == .notConfirmed)
        #expect(commands == 1)
    }

    @Test func timedOutFastPathDoesNotStartAnotherPrivilegedCommand() {
        var count = 0
        let result = SleepControl.setSleepDisabled(true, run: { _, _ in
            count += 1
            return .init(code: -2, out: "", err: "timeout")
        }, readState: { .disabled }, wait: { _ in })
        #expect(result == .notConfirmed)
        #expect(count == 1)
    }

    @Test func misleadingErrorTextIsNotTreatedAsCancellation() {
        let result = SleepControl.setSleepDisabled(false, run: { _, _ in
            .init(code: 1, out: "", err: "cannot cancel task -1280")
        }, readState: { .enabled }, wait: { _ in })
        #expect(result == .notConfirmed)
    }

    @Test func unknownIOKitFallsBackToReadOnlyPmset() {
        let verified = SleepControl.verify(true, run: { path, args in
            #expect(path == "/usr/bin/pmset"); #expect(args == ["-g"])
            return .init(code: 0, out: "SleepDisabled 1", err: "")
        }, readState: { .unknown }, wait: { _ in })
        #expect(verified)
    }
}
