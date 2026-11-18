import Foundation
import Darwin

/// Independent event loop: load on startup, file-change notification, absolute obligation timer,
/// and a bounded awake backstop to re-evaluate continuous time after sleep/wake. Not StartInterval.
final class LiveRecoveryEvents: @unchecked Sendable {
    private var filePollScheduled = false
    private let queue = DispatchQueue(label: "local.nespat.live-test.recovery")
    private let timer: DispatchSourceTimer
    private let changes: DispatchSourceFileSystemObject
    private let poll: () -> Void
    init(directoryFD: Int32, poll: @escaping () -> Void) {
        self.poll = poll
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        changes = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFD, eventMask: [.write, .rename, .delete], queue: queue)
        timer.setEventHandler(handler: poll)
        changes.setEventHandler { [weak self] in
            guard let self, !self.filePollScheduled else { return }
            self.filePollScheduled = true
            self.queue.asyncAfter(deadline: .now()+1) { [weak self] in
                guard let self else { return }; self.filePollScheduled = false; self.poll()
            }
        }
        // Dispatch timer uses mach_absolute_time: continuous clock MUST be re-read in poll.
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(0))
        timer.resume(); changes.resume()
    }
    func obligationChanged(expires: Double, continuousNow: Double) throws {
        guard expires.isFinite, continuousNow.isFinite, continuousNow >= 0 else { throw LiveError.clock }
        let remaining = min(1, max(0, expires-continuousNow)) // Bound conversions and re-read the absolute deadline.
        timer.schedule(deadline: .now()+remaining, repeating: .seconds(1), leeway: .milliseconds(0))
        queue.async(execute: DispatchWorkItem(block: poll))
    }
    deinit { timer.cancel(); changes.cancel() }
}
