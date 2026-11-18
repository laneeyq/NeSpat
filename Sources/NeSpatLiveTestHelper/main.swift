import Foundation
import Darwin
import NeSpatLiveTestCore
// Only unprivileged process fixtures are currently deployable. No real power adapter.
let args = CommandLine.arguments
guard geteuid() != 0, args.count == 5,
      ["--fixture-arm", "--fixture-crash-before", "--fixture-crash-after"].contains(args[1]),
      let time = Double(args[4]) else { print("BLOCKED: no live root deployment"); exit(78) }
do {
    try RootlessLiveFixture.run(directory: args[2], boot: args[3], continuous: time, arm: true,
        crashBefore: args[1] == "--fixture-crash-before", crashAfter: args[1] == "--fixture-crash-after")
} catch { print("MOCK STOP: \(error)"); exit(2) }
