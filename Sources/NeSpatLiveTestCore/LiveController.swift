import Foundation
import NeSpatPrivilegeCore

/// Isolated trusted-controller contract. No production listener imports this module.
final class LiveController {
    let store: any LiveStoring
    let backend: any LiveBackend
    let actor: LivePeer
    init(store: any LiveStoring, backend: any LiveBackend, actor: LivePeer) {
        self.store = store; self.backend = actor.role == .recovery ? RecoveryOnlyBackend(backend) : backend; self.actor = actor
    }
    private func readings(_ r: LiveRecord) throws -> LiveReadings {
        guard try store.load() == r, !r.interferenceDetected else { throw LiveError.state }
        let s = backend.readings()
        if s.foreignInterference == true {
            var stopped = r; stopped.interferenceDetected = true
            _ = try store.save(stopped, replacing: r); throw LiveError.denied
        }
        guard s.boot == r.binding.boot, s.continuous.isFinite, s.continuous >= r.lastClock,
              s.foreignInterference == false, let gate = s.recoveryAdmission,
              gate.boot == r.binding.boot, gate.notBefore.isFinite, gate.notBefore >= 0,
              gate.owner == nil || gate.owner == r.session else { throw LiveError.denied }
        return s
    }
    private func mayActivate(_ s: LiveReadings, until: Double? = nil) throws {
        guard s.power == .enabled, s.lidOpen == true, s.safety.externalPowerConnected == true,
              s.safety.activationAssessment == .noDangerDetected,
              s.recoveryAdmission?.owner == nil, s.recoveryAdmission!.notBefore <= s.continuous,
              until == nil || s.continuous < until! else { throw LiveError.denied }
    }
    func arm(client: LivePeer, duration: Double) throws {
        let initial = try store.exclusive {
            let r = try store.load(); try r.validate()
            try r.binding.verify(actor, role: .helper); try r.binding.verify(client, role: .client)
            guard !r.consumed else { throw LiveError.spent }
            guard r.binding.exclusiveControl, duration.isFinite, duration > 0, duration <= 120 else { throw LiveError.duration }
            return r
        }
        try backend.withSetterLock {
            let reserved = try store.exclusive {
                let s = try readings(initial); try mayActivate(s)
                var r = initial; r.owner = client; r.issued = s.continuous; r.expires = s.continuous+duration
                guard r.expires!.isFinite, r.expires! > s.continuous else { throw LiveError.clock }
                r.baselineNo = true; r.admission = s.recoveryAdmission
                r.lastClock = s.continuous; r.phase = .activationReserved
                r = try store.save(r, replacing: initial)
                let current = try readings(r); try mayActivate(current, until: r.expires)
                // Durable POSSIBLE-attempt marker, not a syscall receipt. Its recovery authority
                // exists only under the opted-in, test-only single-writer assumption.
                var attempted = r
                attempted.attempt = LiveAttempt(session: r.session, helper: actor, client: client, at: current.continuous, nonce: UUID())
                attempted.lastClock = current.continuous
                r = try store.save(attempted, replacing: r)
                let ready = try readings(r)
                if ready.power == .disabled {
                    var stopped = r; stopped.interferenceDetected = true
                    _ = try store.save(stopped, replacing: r); throw LiveError.denied
                }
                try mayActivate(ready, until: r.expires)
                guard try store.load() == r else { throw LiveError.state }
                return r
            }
            // No journal lock across a potentially stuck activation. Setter exclusion remains
            // held, so watchdog can retire the grant but cannot race a second power command.
            let outcome = Result { try backend.execute(.activate) }
            try store.exclusive {
                let after = try readings(reserved) // A watchdog retirement invalidates promotion.
                guard after.continuous < reserved.expires! else {
                    var expired = reserved; expired.lastClock = after.continuous; expired.retired = true
                    if expired.initiated == nil { expired.initiated = after.continuous }
                    _ = try store.save(expired, replacing: reserved)
                    throw LiveError.state // Keep the possible-attempt proof; never confirm expired activation.
                }
                guard after.power == .disabled, try outcome.get() == 0 else { throw LiveError.state }
                var active = reserved; active.phase = .active; active.lastClock = after.continuous
                _ = try store.save(active, replacing: reserved)
            }
        }
    }
    func extend(client: LivePeer, duration: Double) throws { throw LiveError.denied }
    func autoArm() throws { throw LiveError.denied }
    func poll(forceOwnRecovery: Bool = false) throws { try recover(force: forceOwnRecovery, manual: nil) }
    /// No journal/setter lock is held across UI/authorization. Challenge is unique per call.
    func manualRecover(client: LivePeer) throws {
        let request = try store.exclusive {
            let r = try store.load(); try r.validate(); try r.binding.verify(actor, role: .recovery)
            try r.binding.verify(client, role: .client)
            guard r.phase != .unused, r.phase != .completed, !r.interferenceDetected else { throw LiveError.denied }
            return LiveManualRequest(id: UUID(), client: client, record: r)
        }
        let approval = try backend.authorizeManualRecovery(request)
        guard approval.request == request else { throw LiveError.denied }
        try recover(force: true, manual: request)
    }
    private func recover(force: Bool, manual: LiveManualRequest?) throws {
        // Short preparation transaction: record initiation before competing for the setter lock.
        let pending: LiveRecord? = try store.exclusive {
            var r = try store.load(); try r.validate(); try r.binding.verify(actor, role: .recovery)
            if let manual {
                try r.binding.verify(manual.client, role: .client)
                guard r == manual.record else { throw LiveError.state } // Includes generation, phase, deadline, owner.
            }
            guard r.phase != .unused, r.phase != .completed else { return nil }
            let s = try readings(r)
            let emergency = s.safety.emergencyAssessment != .noDangerDetected
            guard s.continuous >= r.expires! || s.helperAlive != true || emergency || force || r.retired else { return nil }
            var changed = r; changed.retired = true; changed.lastClock = s.continuous
            if changed.initiated == nil { changed.initiated = s.continuous }
            r = try store.save(changed, replacing: r)
            guard s.power != .unknown else { throw LiveError.state }
            return r
        }
        guard let pending else { return }
        // Acquisition and the complete setter call happen WITHOUT journal exclusivity.
        try backend.withSetterLock {
            let reserved: LiveRecord? = try store.exclusive {
                let current = try readings(pending) // Reject replacement/updates while acquiring the lock.
                if current.power == .enabled {
                    var done = pending; done.phase = .completed; done.retry = nil; done.lastClock = current.continuous
                    _ = try store.save(done, replacing: pending)
                    return nil
                }
                guard current.power == .disabled, pending.attempt != nil,
                      pending.baselineNo == true, pending.binding.exclusiveControl else { throw LiveError.pendingOwnership }
                if manual == nil {
                    guard current.continuous >= current.recoveryAdmission!.notBefore else { throw LiveError.cooldown }
                    if let retry = pending.retry {
                        guard current.continuous >= retry.last else { throw LiveError.clock }
                        let emergencyNow = current.safety.emergencyAssessment != .noDangerDetected
                        let interval = emergencyNow ? RecoveryPolicy.emergency : RecoveryPolicy.ordinary
                        guard (emergencyNow && !retry.emergency) || current.continuous-retry.since >= interval else { throw LiveError.cooldown }
                    }
                }
                var reservation = pending; reservation.phase = .recovery; reservation.lastClock = current.continuous
                reservation.retry = LiveRetry(since: current.continuous, last: current.continuous,
                    emergency: current.safety.emergencyAssessment != .noDangerDetected, nonce: UUID())
                let saved = try store.save(reservation, replacing: pending)
                guard try store.load() == saved else { throw LiveError.state }
                return saved
            }
            guard let reserved else { return }
            let outcome = Result { try backend.execute(.restore) }
            try store.exclusive {
                // Strict completion CAS. A competing watchdog can update the record during I/O;
                // its retirement/FAILED state must never be replaced using this stale snapshot.
                guard try store.load() == reserved else {
                    if case .failure = outcome { try failedAttempt(reserved) }
                    throw LiveError.state
                }
                do {
                    guard try outcome.get() == 0 else { throw LiveError.state }
                    let after = try readings(reserved)
                    guard after.power == .enabled else { throw LiveError.state }
                    var done = reserved; done.phase = .completed; done.retry = nil; done.lastClock = after.continuous
                    _ = try store.save(done, replacing: reserved)
                } catch {
                    try failedAttempt(reserved)
                    throw error
                }
            }
        }
    }
    private func failedAttempt(_ expected: LiveRecord) throws {
        let r = try store.load()
        // If our own interference latch was saved, retain it along with the FAILED result.
        guard r.binding == expected.binding, r.session == expected.session, r.owner == expected.owner,
              r.issued == expected.issued, r.expires == expected.expires, r.baselineNo == expected.baselineNo,
              r.admission == expected.admission, r.attempt == expected.attempt, r.retry == expected.retry,
              r.retired, r.initiated == expected.initiated, r.failedAttempts == expected.failedAttempts,
              r.lastFailure == expected.lastFailure, r.phase == .recovery, r.failedAttempts < UInt64.max else { throw LiveError.state }
        let s = backend.readings()
        let time = s.boot == r.binding.boot && s.continuous.isFinite && s.continuous >= r.lastClock ? s.continuous : r.lastClock
        var failed = r; failed.lastClock = time; failed.retry?.since = time; failed.retry?.last = time
        failed.failedAttempts += 1; failed.lastFailure = time
        if s.foreignInterference == true { failed.interferenceDetected = true }
        _ = try store.save(failed, replacing: r)
    }
    /// The future uninstaller must require this check; no deletion path exists in this module.
    func canRemove() throws -> Bool {
        try backend.withSetterLock {
            try store.exclusive {
                let r = try store.load(); try r.binding.verify(actor, role: .recovery)
                guard r.phase == .completed else { return false }
                return try readings(r).power == .enabled
            }
        }
    }
}
