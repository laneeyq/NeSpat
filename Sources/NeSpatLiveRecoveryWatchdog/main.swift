import Foundation
import Darwin
import NeSpatLiveTestCore
// Distinct rootless executable. The approved pending policy is test-only; root trust,
// deployment and a real power adapter are still unavailable. No flag can enable root I/O.
guard geteuid() != 0, CommandLine.arguments.count == 5,
      ["--fixture-poll", "--fixture-poll-fail", "--fixture-recovery-crash-before", "--fixture-recovery-crash-after", "--fixture-watch", "--fixture-manual-wait"].contains(CommandLine.arguments[1]),
      let time = Double(CommandLine.arguments[4]) else {
    print("BLOCKED: live root deployment is not approved; no real power executor linked")
    exit(78)
}
do {
    try RootlessLiveFixture.run(directory: CommandLine.arguments[2], boot: CommandLine.arguments[3], continuous: time,
        arm: false, crashBefore: CommandLine.arguments[1] == "--fixture-recovery-crash-before",
        crashAfter: CommandLine.arguments[1] == "--fixture-recovery-crash-after",
        failRestore: CommandLine.arguments[1] == "--fixture-poll-fail", watch: CommandLine.arguments[1] == "--fixture-watch", manual: CommandLine.arguments[1] == "--fixture-manual-wait")
} catch { print("MOCK STOP: \(error)"); exit(2) }
