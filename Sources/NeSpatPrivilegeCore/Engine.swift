import NeSpatNative
import Foundation

// Isolated policy only. Trusted enrollment and system executors remain undeployed.
public final class PrivilegeEngine: @unchecked Sendable {
    enum Scope { case full, recovery(UUID), revoked }
    struct Grant {
        let peer: Peer
        let expires: TimeInterval
        var scope: Scope
        var ownedSession: UUID?
        var selectedSession = false
        var sessionExpires: Double?
        var heartbeatSequence = 0
        var requests = 0
        var lastHeartbeat: TimeInterval?
        var lastObservation: TimeInterval?
    }
    private let mutex = NSRecursiveLock()
    private let journal: any AuthorityJournal
    private let exclusivePolicy: ExclusivePolicy?
    private let boot: UUID
    private let fullGrantPolicy: FullGrantLifetimePolicy?
    private let heartbeatPolicy: HeartbeatPolicy?
    private let requireCompleteSafety: Bool
    private let safetySnapshot: (() -> PowerSafetySnapshot)?
    private let now: () -> Date
    private let monotonic: () -> TimeInterval
    private let retryClock: () -> TimeInterval
    private let canFinalizePending: () -> Bool
    private let observe: () -> ObservedSleep
    private let ownerLiveness: (Peer) -> OwnerLiveness
    private let requestEmergencySleep: (() -> Void)?
    private let setDisabled: (Bool) throws -> Void
    private var grants: [UUID: Grant] = [:]
    private let authorizationEpoch = UUID()
    private var ownerEpochs: [OwnerIdentity: UUID] = [:]
    private var challenges: [UUID: EnrollmentChallenge] = [:]
    private var consumedApprovals: Set<UUID> = []
    private var connected: Set<UUID> = []
    private var disconnectedOwners: Set<UUID> = []
    private var retiredOwners: Set<OwnerIdentity> = []
    // Tombstones and replay IDs span connections, are bounded, and never silently evicted.
    private var admittedConnections: Set<UUID> = []
    private var seenRequests: Set<UUID> = []
    private struct AuthorityIdentity: Equatable {
        let id: UUID
        let owner: Peer
        let proof: ExclusiveAttempt?
        let phase: PrivilegedRecord.Phase
        init(_ record: PrivilegedRecord) { id = record.id; owner = record.owner; phase = record.phase; proof = record.exclusiveAttempt }
    }
    private var remembered: AuthorityIdentity?
    private var lossDetected = false
    private var operating = false

    public init(journal: any AuthorityJournal, boot: UUID, now: @escaping () -> Date,
                monotonic: @escaping () -> TimeInterval, observe: @escaping () -> ObservedSleep,
                setDisabled: @escaping (Bool) throws -> Void,
                ownerLiveness: @escaping (Peer) -> OwnerLiveness = { _ in .unknown },
                fullGrantPolicy: FullGrantLifetimePolicy? = nil,
                heartbeatPolicy: HeartbeatPolicy? = nil,
                safetySnapshot: (() -> PowerSafetySnapshot)? = nil,
                requireCompleteSafety: Bool = true,
                retryClock: (() -> TimeInterval)? = nil,
                exclusivePolicy: ExclusivePolicy? = nil,
                requestEmergencySleep: (() -> Void)? = nil,
                canFinalizePending: @escaping () -> Bool = { false }) {
        self.exclusivePolicy = exclusivePolicy
        self.requestEmergencySleep = requestEmergencySleep
        self.journal = journal; self.boot = boot; self.now = now; self.monotonic = monotonic
        self.retryClock = retryClock ?? RecoveryPolicy.continuousSeconds
        self.canFinalizePending = canFinalizePending
        self.observe = observe; self.setDisabled = setDisabled; self.ownerLiveness = ownerLiveness
        self.fullGrantPolicy = fullGrantPolicy
        self.heartbeatPolicy = heartbeatPolicy
        self.requireCompleteSafety = requireCompleteSafety
        self.safetySnapshot = safetySnapshot
    }
    // Authentication and independent consent verification are external trusted boundaries.
    public func enrollmentChallenge(for peer: Peer) throws -> EnrollmentChallenge {
        try serialized {
            guard let identity = peer.ownerIdentity, !admittedConnections.contains(peer.connection),
                  admittedConnections.count < 4096 else { throw PrivilegeError.denied }
            if let pending = challenges[peer.connection] {
                guard pending.peer == peer else { throw PrivilegeError.denied }; return pending
            }
            guard challenges.count < 64 else { throw PrivilegeError.denied }
            if ownerEpochs[identity] == nil {
                guard ownerEpochs.count < 4096 else { throw PrivilegeError.denied }
                ownerEpochs[identity] = UUID()
            }
            let challenge = EnrollmentChallenge(nonce: UUID(), engine: authorizationEpoch, boot: boot,
                                                ownerEpoch: ownerEpochs[identity]!, peer: peer, issuedAt: monotonic())
            challenges[peer.connection] = challenge; return challenge
        }
    }
    public func cancelEnrollment(for peer: Peer) {
        mutex.lock(); defer { mutex.unlock() }
        if challenges[peer.connection]?.peer == peer { challenges.removeValue(forKey: peer.connection) }
    }
    // Compatibility is intentionally recovery-only: an expiry value is NOT proof of fresh consent.
    public func admit(_ peer: Peer, expires: TimeInterval) throws {
        try admit(peer, authorization: .recoveryOnly(expires: expires))
    }
    public func admit(_ peer: Peer, authorization: EnrollmentAuthorization) throws {
        try transaction {
            guard let identity = peer.ownerIdentity,
                  peer.process.map({ $0.bootID == boot }) ?? true,
                  !admittedConnections.contains(peer.connection), admittedConnections.count < 4096,
                  grants.count < 64 else { throw PrivilegeError.denied }
            var scope = Scope.full
            var owned: UUID?
            let record = try load()
            if let record {
                // Any active authority record forbids fresh full admission. Reconnect is recovery-only.
                guard record.owner.sameOwner(as: peer) else { throw PrivilegeError.ownership }
                try record.validateOwnership(boot: boot)
                guard record.phase == .active, !lossDetected else { throw PrivilegeError.ownership }
                let liveness = ownerLiveness(record.owner)
                let sameProcess = record.owner.process != nil && record.owner.process == peer.process
                guard liveness != .active || sameProcess,
                      disconnectedOwners.contains(record.owner.connection) || liveness == .inactive || sameProcess,
                      !connected.contains(record.owner.connection), !grants.values.contains(where: {
                    if case .recovery(let id) = $0.scope { return id == record.id }; return false
                }) else { throw PrivilegeError.ownership }
                scope = .recovery(record.id); owned = record.id
            }
            let expires: TimeInterval
            var bound: (challenge: EnrollmentChallenge, event: UUID, confirmed: TimeInterval)?
            switch authorization {
            case .recoveryOnly(let until):
                guard owned != nil else { throw PrivilegeError.denied }
                expires = until
            case .fresh(let approval):
                expires = approval.expires
                bound = (approval.challenge, approval.consentEvent, approval.confirmedAt)
            case .localSetup(let approval):
                expires = approval.expires
                bound = (approval.challenge, approval.event, approval.issued)
            }
            if let proof = bound {
                let challenge = proof.challenge
                guard challenge.engine == authorizationEpoch, challenge.boot == boot, challenge.peer == peer,
                      challenges[peer.connection] == challenge, ownerEpochs[identity] == challenge.ownerEpoch,
                      !consumedApprovals.contains(proof.event), consumedApprovals.count < 4096,
                      proof.confirmed.isFinite, proof.confirmed >= challenge.issuedAt,
                      proof.confirmed <= monotonic(), expires > proof.confirmed else { throw PrivilegeError.denied }
            }
            let admittedAt = monotonic()
            guard admittedAt.isFinite, expires.isFinite, expires > admittedAt else { throw PrivilegeError.denied }
            if case .full = scope {
                guard !lossDetected else { throw PrivilegeError.ownership }
                guard let persistence = journal as? any PersistentRecoveryJournal else { throw PrivilegeError.blocked }
                guard try persistence.recoverySnapshot().retry == nil else { throw PrivilegeError.ownership }
                guard retryClock().isFinite, retryClock() >= 0 else { throw PrivilegeError.blocked }
                guard let proof = bound else { throw PrivilegeError.denied }
                guard let fullGrantPolicy else { throw PrivilegeError.blocked }
                try fullGrantPolicy.validate(confirmedAt: proof.confirmed, expires: expires)
                // Defense A: at most one full grant per stable owner, regardless of connection.
                guard !grants.values.contains(where: {
                    if case .full = $0.scope { return $0.peer.ownerIdentity == identity }; return false
                }) else { throw PrivilegeError.denied }
                guard observe() == .enabled else { throw PrivilegeError.unknownPower }
            }
            if let proof = bound { consumedApprovals.insert(proof.event) }
            challenges.removeValue(forKey: peer.connection)
            // Do not remove retiredOwners: only the fresh bound proof permits a new grant epoch.
            grants[peer.connection] = Grant(peer: peer, expires: expires, scope: scope, ownedSession: owned,
                                            lastHeartbeat: admittedAt, lastObservation: admittedAt)
            admittedConnections.insert(peer.connection); connected.insert(peer.connection)
        }
    }
    // Defense B: owner-wide pure transition, independently tested on historical parallel grants.
    static func revoking(_ values: [UUID: Grant], owner: OwnerIdentity) -> [UUID: Grant] {
        var result = values
        for (id, var grant) in values where grant.peer.ownerIdentity == owner {
            if case .full = grant.scope {
                grant.scope = grant.ownedSession.map(Scope.recovery) ?? .revoked
                grant.requests = 0
                result[id] = grant
            }
        }
        return result
    }
    private func retire(_ owner: OwnerIdentity) {
        retiredOwners.insert(owner)
        ownerEpochs[owner] = UUID()
        grants = Self.revoking(grants, owner: owner)
        challenges = challenges.filter { $0.value.peer.ownerIdentity != owner }
    }
    private func permitsActivation(_ sample: PowerSafetySnapshot) -> Bool {
        sample.activationRefusalReason == nil && (!requireCompleteSafety || sample.activationAssessment != .unknown)
    }
    private func authorityExpired(_ grant: Grant, at time: TimeInterval) -> Bool {
        let expiry = grant.selectedSession ? grant.sessionExpires : grant.expires
        guard time.isFinite, expiry.map({ $0 > time }) ?? true else { return true }
        if let last = grant.lastObservation, time < last { return true }
        if let last = grant.lastHeartbeat {
            let elapsed = time - last
            guard elapsed.isFinite, elapsed >= 0 else { return true }
            if case .full = grant.scope, let heartbeatPolicy, elapsed >= heartbeatPolicy.timeout { return true }
        } else if heartbeatPolicy != nil { return true }
        return false
    }
    public func handle(_ request: Request, from peer: Peer) throws -> Reply {
        try serialized {
            try request.validate()
            guard var grant = grants[peer.connection], grant.peer == peer,
                  connected.contains(peer.connection) else { throw PrivilegeError.denied }
            let observedAt = monotonic()
            if authorityExpired(grant, at: observedAt) || request.operation == .revoke {
                if let identity = peer.ownerIdentity { retire(identity) }
                grant = grants[peer.connection]!
            }
            // Downgrade precedes I/O and even replay checks: failed revoke cannot retain full rights.
            switch grant.scope {
            case .full: break
            case .recovery:
                guard [.recover, .revoke, .status, .pollRecovery].contains(request.operation) else { throw PrivilegeError.denied }
            case .revoked:
                grants.removeValue(forKey: peer.connection); connected.remove(peer.connection)
                if request.operation == .revoke { return Reply(state: observe(), session: nil, deadline: nil) }
                throw PrivilegeError.denied
            }
            guard !seenRequests.contains(request.id) else { throw PrivilegeError.replay }
            let replayLimit: Int
            if case .recovery = grant.scope { replayLimit = 266240 } else { replayLimit = 262144 }
            if let sequence = request.heartbeatSequence {
                guard grant.selectedSession, grant.ownedSession == request.session, sequence > grant.heartbeatSequence else { throw PrivilegeError.replay }
                grant.heartbeatSequence = sequence
            } else {
                guard seenRequests.count < replayLimit, grant.requests < 4096 else { throw PrivilegeError.denied }
                seenRequests.insert(request.id); grant.requests += 1
            }
            grant.lastObservation = observedAt; grants[peer.connection] = grant
            return try journal.exclusive {
                let record = try load()
                if request.operation == .revoke {
                    guard let record, record.id == grant.ownedSession,
                          record.owner.sameOwner(as: peer) else { throw PrivilegeError.ownership }
                    try validateRecoveryOwner(record, from: peer)
                    try restore(record, allowDamagedTimer: true, from: peer, manual: true)
                    return reply(nil, peer: peer)
                }
                if request.operation == .status { return reply(record, peer: peer) }
                if request.operation == .heartbeat {
                    guard heartbeatPolicy != nil else { throw PrivilegeError.blocked }
                    guard let record, record.id == request.session, record.id == grant.ownedSession,
                          record.owner == peer, record.phase == .active, !lossDetected else { throw PrivilegeError.ownership }
                    try record.validateOwnership(boot: boot)
                    guard observe() == .disabled else {
                        if exclusivePolicy != nil, observe() == .enabled {
                            var stopped = record; stopped.interference = true; try journal.save(stopped)
                        }
                        throw PrivilegeError.unknownPower
                    }
                    if let exclusivePolicy { _ = try record.verifiedAttempt(exclusivePolicy) }
                    let time = monotonic()
                    guard !authorityExpired(grant, at: time) else {
                        if let identity = peer.ownerIdentity { retire(identity) }
                        throw PrivilegeError.denied
                    }
                    grant.lastHeartbeat = time; grant.lastObservation = time; grants[peer.connection] = grant
                    return reply(record, peer: peer) // Never changes grant.expires, sleep deadline or authority scope.
                }
                if request.operation == .begin {
                    guard let safetySnapshot else { throw PrivilegeError.blocked }
                    guard permitsActivation(safetySnapshot()) else { throw PrivilegeError.denied }
                    guard !lossDetected, record == nil else { throw PrivilegeError.ownership }
                    guard observe() == .enabled else { throw PrivilegeError.unknownPower }
                    var sessionExpires: Double? = grant.expires
                    var deadline = try request.deadline(now: now())
                    if let policy = exclusivePolicy {
                        guard let current = grants[peer.connection], case .full = current.scope else { throw PrivilegeError.denied }
                        guard peer.process != nil, peer.uid == policy.uid, peer.codeIdentity == policy.clientRequirement,
                              policy.canArm(),
                              grant.expires > observedAt, grant.expires - observedAt <= policy.maximum else { throw PrivilegeError.denied }
                        if policy.selectedLifetime {
                            sessionExpires = try request.minutes.map { observedAt + (try Request.interval($0)) }
                        } else {
                            let limit = now().addingTimeInterval(grant.expires - observedAt)
                            deadline = min(deadline ?? limit, limit)
                        }
                    }
                    var pending = PrivilegedRecord(id: UUID(), owner: peer, bootID: boot, baselineEnabled: true, phase: .pending, deadline: deadline, authorityExpires: sessionExpires)
                    pending.exclusiveReservation = exclusivePolicy?.setup
                    try journal.save(pending); remembered = AuthorityIdentity(pending)
                    grant.ownedSession = pending.id; grants[peer.connection] = grant
                    do {
                        // Sampling can block or observe a new critical condition. Revalidate
                        // the exact intent, actual No and lease after the final sample.
                        guard permitsActivation(safetySnapshot()) else { throw PrivilegeError.denied }
                        guard try load() == pending, !lossDetected, observe() == .enabled else { throw PrivilegeError.ownership }
                        guard try load() == pending, !lossDetected else { throw PrivilegeError.ownership }
                        guard !authorityExpired(grant, at: monotonic()) else {
                            if let identity = peer.ownerIdentity { retire(identity) }
                            throw PrivilegeError.denied
                        }
                    } catch {
                        // No setter was attempted. Only exact unchanged intent + independent
                        // No permits cleanup; ambiguous power/journal retains all evidence.
                        if let latest = try? load(), latest == pending, !lossDetected, observe() == .enabled {
                            try journal.save(nil); remembered = nil
                            if var current = grants[peer.connection] {
                                if case .full = current.scope {
                                    current.ownedSession = nil; grants[peer.connection] = current
                                } else {
                                    grants.removeValue(forKey: peer.connection); connected.remove(peer.connection)
                                }
                            }
                        }
                        throw error
                    }
                    let clock = retryClock()
                    guard clock.isFinite, clock >= 0 else { throw PrivilegeError.blocked }
                    if let policy = exclusivePolicy {
                        guard observe() == .enabled, policy.canArm() else { throw PrivilegeError.ownership }
                        pending.exclusiveAttempt = ExclusiveAttempt(setup: policy.setup, session: pending.id,
                            helperEpoch: policy.helperEpoch, owner: peer, boot: boot, startedOnAC: safetySnapshot().externalPowerConnected == true, issued: observedAt,
                            expires: sessionExpires, deadline: deadline, selectedLifetime: policy.selectedLifetime ? true : nil, unlimited: deadline == nil ? true : nil, nonce: UUID())
                        _ = try pending.verifiedAttempt(policy)
                        try journal.save(pending)
                        remembered = AuthorityIdentity(pending)
                        guard try load() == pending, monotonic() < grant.expires, deadline.map({ now() < $0 }) ?? true,
                              policy.canArm() else { throw PrivilegeError.denied }
                        if observe() != .enabled {
                            pending.interference = true
                            try journal.save(pending)
                            throw PrivilegeError.ownership
                        }
                    }
                    do { try setDisabled(true) }
                    catch PrivilegeError.interference {
                        guard try load() == pending else { throw PrivilegeError.ownership }
                        pending.interference = true
                        try journal.save(pending)
                        throw PrivilegeError.interference
                    }
                    guard observe() == .disabled else { throw PrivilegeError.unconfirmed }
                    if exclusivePolicy != nil {
                        guard try load() == pending, monotonic() < grant.expires,
                              deadline.map({ now() < $0 }) ?? true else { throw PrivilegeError.unconfirmed }
                    }
                    pending.phase = .active; try journal.save(pending)
                    if exclusivePolicy?.selectedLifetime == true {
                        grant.selectedSession = true; grant.sessionExpires = sessionExpires
                        grants[peer.connection] = grant
                    }
                    remembered = AuthorityIdentity(pending)
                    return reply(pending, peer: peer)
                }
                guard let record, record.id == request.session else { throw PrivilegeError.ownership }
                try record.validateOwnership(boot: boot)
                if case .recovery(let id) = grant.scope {
                    guard id == record.id else { throw PrivilegeError.ownership }
                    try validateRecoveryOwner(record, from: peer)
                } else {
                    guard record.owner == peer else { throw PrivilegeError.ownership }
                }
                switch request.operation {
                case .changeDeadline:
                    guard record.exclusiveAttempt == nil else { throw PrivilegeError.denied }
                    guard !lossDetected, record.phase == .active else { throw PrivilegeError.ownership }
                    try record.validateTimer()
                    guard observe() == .disabled else { throw PrivilegeError.unknownPower }
                    guard try load() == record, !lossDetected else { throw PrivilegeError.ownership }
                    guard let current = grants[peer.connection], case .full = current.scope,
                          !authorityExpired(current, at: monotonic()) else {
                        if let identity = peer.ownerIdentity { retire(identity) }
                        throw PrivilegeError.denied
                    }
                    var next = record; next.deadline = try request.deadline(now: now())
                    try journal.save(next); return reply(next, peer: peer)
                case .end: try restore(record, allowDamagedTimer: false, from: peer, manual: true)
                case .recover:
                    guard exclusivePolicy == nil else { throw PrivilegeError.denied }
                    try restore(record, allowDamagedTimer: true, from: peer, manual: true)
                case .pollRecovery:
                    if let identity = peer.ownerIdentity { retire(identity) }
                    try tickBody(authorizedRecoveryPeer: peer)
                default: throw PrivilegeError.malformed
                }
                return reply(try load(), peer: peer)
            }
        }
    }
    public func disconnect(_ peer: Peer) throws {
        try serialized {
            // Bind disconnect to the actual connection; fabricated peer data cannot evict another.
            guard let grant = grants[peer.connection], grant.peer == peer else { throw PrivilegeError.denied }
            if let identity = peer.ownerIdentity { retire(identity) }
            grants.removeValue(forKey: peer.connection); connected.remove(peer.connection)
            disconnectedOwners.insert(peer.connection)
            try journal.exclusive {
                if let record = try load(), record.id == grant.ownedSession, record.owner.sameOwner(as: peer) {
                    try validateRecoveryOwner(record, from: peer)
                    try restore(record, allowDamagedTimer: false, from: peer)
                }
            }
        }
    }
    public func tick() throws { try transaction { try tickBody() } }
    private func tickBody(authorizedRecoveryPeer: Peer? = nil) throws {
        guard let record = try load() else { return }
        if exclusivePolicy != nil {
            guard record.interference != true else { throw PrivilegeError.ownership }
            // A separate process owns pending/old-boot reconciliation.
            if record.phase == .pending || record.bootID != boot { return }
        }
        if record.bootID != boot {
            try record.validateOwnership(boot: record.bootID)
            guard !lossDetected, try load() == record, canFinalizePending(), observe() == .enabled,
                  try load() == record, !lossDetected, canFinalizePending(), observe() == .enabled else { throw PrivilegeError.ownership }
            try journal.save(nil); remembered = nil; lossDetected = false
            return
        }
        try record.validateOwnership(boot: boot); try record.validateTimer()
        if record.phase == .pending {
            guard !lossDetected, try load() == record, canFinalizePending(), observe() == .enabled,
                  try load() == record, !lossDetected, canFinalizePending(), observe() == .enabled else { throw PrivilegeError.ownership }
            if let identity = record.owner.ownerIdentity { retire(identity) }
            try journal.save(nil); remembered = nil; lossDetected = false
            for (id, grant) in Array(grants) where grant.ownedSession == record.id {
                grants.removeValue(forKey: id); connected.remove(id)
            }
            return
        }
        let grant = grants[record.owner.connection]
        if grant == nil, authorizedRecoveryPeer == nil, !disconnectedOwners.contains(record.owner.connection), ownerLiveness(record.owner) != .inactive { throw PrivilegeError.ownership }
        let observedAt = monotonic()
        let expired = grant == nil || authorityExpired(grant!, at: observedAt) || record.authorityExpires.map({ $0 <= observedAt }) == true
        let reading = safetySnapshot?()
        let critical = reading?.emergencyReason != nil
        let sensorsLost = requireCompleteSafety && (reading == nil || reading?.emergencyAssessment == .unknown)
        // Downgrade before restoration I/O. Failure cannot let a late heartbeat revive full rights.
        if expired || critical || sensorsLost, grant != nil, let identity = record.owner.ownerIdentity { retire(identity) }
        if var grant, !expired, !critical, !sensorsLost {
            grant.lastObservation = observedAt; grants[record.owner.connection] = grant
        }
        let recoveryOnly: Bool
        if let grant, case .full = grant.scope { recoveryOnly = false } else { recoveryOnly = true }
        if expired || critical || sensorsLost || recoveryOnly || record.deadline.map({ $0 <= now() }) == true {
            try restore(record, allowDamagedTimer: false, from: authorizedRecoveryPeer)

        }
    }
    /// Called by a separate launchd process. No peer or RPC can invoke this entry point.
    public func independentPoll(helperEpoch: UUID?, emergency: Bool, externalPower: Bool? = nil) throws {
        try reconcile(helperEpoch: helperEpoch, emergency: emergency, externalPower: externalPower, approval: nil)
    }
    /// A separately authorized root invocation of the exact installed helper. No XPC endpoint exports this.
    public func approvedRecovery(session: UUID, ticket: String) throws {
        guard geteuid() == 0 else { throw PrivilegeError.denied }
        try reconcile(helperEpoch: nil, emergency: false, externalPower: nil, approval: (session,ticket))
    }
    private func reconcile(helperEpoch: UUID?, emergency: Bool, externalPower: Bool?, approval: (UUID,String)?) throws {
        guard let policy = exclusivePolicy, let store = journal as? any PersistentRecoveryJournal else { throw PrivilegeError.blocked }
        try transaction {
            guard let record = try journal.load() else {
                if approval != nil { throw PrivilegeError.ownership }
                return
            }
            if let (id,ticket) = approval {
                guard let system = journal as? ProtectedJournal, record.id == id, record.exclusiveAttempt != nil,
                      try system.recoveryTicket() == ticket else { throw PrivilegeError.denied }
            }
            if record.exclusiveAttempt == nil {
                // A reservation before the marker cannot have executed a setter.
                guard record.exclusiveReservation == policy.setup, record.bootID == boot, record.baselineEnabled,
                      record.owner.uid == policy.uid, record.owner.codeIdentity == policy.clientRequirement, record.owner.process != nil,
                      record.phase == .pending, record.interference != true, canFinalizePending(),
                      observe() == .enabled, try journal.load() == record else { throw PrivilegeError.ownership }
                try journal.save(nil)
                return
            }
            let proof = try record.verifiedAttempt(policy)
            guard canFinalizePending() else { throw PrivilegeError.busy }
            let state = observe()
            if state == .enabled {
                guard try journal.load() == record, canFinalizePending() else { throw PrivilegeError.unconfirmed }
                guard observe() == .enabled else {
                    var stopped = record; stopped.interference = true
                    try journal.save(stopped)
                    throw PrivilegeError.interference
                }
                try journal.save(nil)
                return
            }
            guard state == .disabled, record.bootID == boot else { throw PrivilegeError.unknownPower }
            let time = monotonic()
            guard time.isFinite, time >= proof.issued else { throw PrivilegeError.blocked }
            let retry = try store.recoverySnapshot().retry
            let mustRecover = emergency || (!policy.selectedLifetime && proof.startedOnAC && externalPower != true)
            guard retry != nil || mustRecover || proof.helperEpoch != helperEpoch || record.phase == .pending ||
                  (proof.expires.map { time >= $0 } ?? false) || (proof.deadline.map { now() >= $0 } ?? false) || ownerLiveness(record.owner) != .active else { return }
            guard try reserveRecovery(record, emergency: mustRecover, manual: approval != nil) else { return }
            guard try journal.load() == record, canFinalizePending(), observe() == .disabled else { throw PrivilegeError.unconfirmed }
            do {
                try setDisabled(false)
                guard try journal.load() == record, observe() == .enabled else { throw PrivilegeError.unconfirmed }
            } catch {
                try recordRecoveryFailure(record)
                throw error
            }
            try journal.save(nil)
            sleepIfDangerPersists(record)
        }
    }

    // Both daemons hold the same journal lock. Only the process that completes
    // a verified recovery can issue this one-shot request for that session.
    private func sleepIfDangerPersists(_ record: PrivilegedRecord) {
        guard record.bootID == boot, record.exclusiveAttempt != nil, let requestEmergencySleep,
              safetySnapshot?().emergencyAssessment == .confirmedDanger,
              observe() == .enabled else { return }
        requestEmergencySleep()
    }

    public func canRemoveOrUpdate() throws -> Bool {
        try transaction { try load() == nil && !lossDetected && observe() == .enabled }
    }
    private func serialized<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard !operating else { throw PrivilegeError.busy }
        operating = true; defer { operating = false }
        return try body()
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try serialized { try journal.exclusive(body) }
    }
    private func load() throws -> PrivilegedRecord? {
        let value = try journal.load()
        // A UUID alone does not pin authority: a replacement can retain it while changing
        // the owner or promoting an unconfirmed pending operation. Only our successful
        // pending -> active commit may advance the pinned phase. Timer damage remains
        // explicitly recoverable without treating it as evidence of ownership.
        if let previous = remembered, value == nil, let store = journal as? ProtectedJournal,
           try store.confirmsCompletion(of: previous.id), observe() == .enabled {
            if let identity = previous.owner.ownerIdentity { retire(identity) }
            self.remembered = nil
        }
        if let remembered, value.map(AuthorityIdentity.init) != remembered { lossDetected = true }
        if let value, remembered == nil { remembered = AuthorityIdentity(value) }
        return value
    }
    private func validateRecoveryOwner(_ record: PrivilegedRecord, from peer: Peer) throws {
        guard record.owner.sameOwner(as: peer) else { throw PrivilegeError.ownership }
        if record.owner.connection != peer.connection {
            let liveness = ownerLiveness(record.owner)
            let sameProcess = record.owner.process != nil && record.owner.process == peer.process
            guard !connected.contains(record.owner.connection), liveness != .active || sameProcess,
                  disconnectedOwners.contains(record.owner.connection) || liveness == .inactive || sameProcess else { throw PrivilegeError.ownership }
        }
    }
    private func validateRestoreRecord(_ record: PrivilegedRecord, allowDamagedTimer: Bool, from peer: Peer?) throws {
        guard let latest = try load(), !lossDetected,
              AuthorityIdentity(latest) == AuthorityIdentity(record),
              allowDamagedTimer || latest == record else { throw PrivilegeError.ownership }
        if let peer { try validateRecoveryOwner(record, from: peer) }
        else if grants[record.owner.connection] == nil, !disconnectedOwners.contains(record.owner.connection), ownerLiveness(record.owner) != .inactive {
            throw PrivilegeError.ownership
        }
    }
    private func restore(_ record: PrivilegedRecord, allowDamagedTimer: Bool, from peer: Peer? = nil, manual: Bool = false) throws {
        try record.validateOwnership(boot: boot)
        guard record.phase == .active, !lossDetected else { throw PrivilegeError.ownership }
        if let exclusivePolicy { _ = try record.verifiedAttempt(exclusivePolicy) }
        if !allowDamagedTimer { try record.validateTimer() }
        try validateRestoreRecord(record, allowDamagedTimer: allowDamagedTimer, from: peer)
        let state = observe()
        // Recheck after potentially blocking observation, immediately before a setter.
        try validateRestoreRecord(record, allowDamagedTimer: allowDamagedTimer, from: peer)
        switch state {
        case .enabled: break
        case .disabled:
            let reading = safetySnapshot?()
            let emergency = reading?.emergencyReason != nil || (requireCompleteSafety && (reading == nil || reading?.emergencyAssessment == .unknown))
            if emergency, let identity = record.owner.ownerIdentity { retire(identity) }
            guard try reserveRecovery(record, emergency: emergency, manual: manual && exclusivePolicy == nil) else { return }
            try validateRestoreRecord(record, allowDamagedTimer: allowDamagedTimer, from: peer)
            do {
                try setDisabled(false)
                guard observe() == .enabled else { throw PrivilegeError.unconfirmed }
            } catch {
                try recordRecoveryFailure(record)
                throw error
            }
        case .unknown: throw PrivilegeError.unknownPower
        }
        try validateRestoreRecord(record, allowDamagedTimer: allowDamagedTimer, from: peer)
        guard observe() == .enabled else { throw PrivilegeError.unconfirmed }
        try validateRestoreRecord(record, allowDamagedTimer: allowDamagedTimer, from: peer)
        try journal.save(nil)
        if state == .disabled { sleepIfDangerPersists(record) }
        remembered = nil; lossDetected = false
        for (connection, var grant) in Array(grants) where grant.ownedSession == record.id {
            if case .recovery = grant.scope { grants.removeValue(forKey: connection); connected.remove(connection) }
            else { grant.selectedSession = false; grant.sessionExpires = nil; grant.ownedSession = nil; grants[connection] = grant }
        }
    }
    private func reserveRecovery(_ record: PrivilegedRecord, emergency: Bool, manual: Bool) throws -> Bool {
        guard let store = journal as? any PersistentRecoveryJournal else { throw PrivilegeError.blocked }
        var snapshot = try store.recoverySnapshot()
        if snapshot.generation == 0 {
            // Explicit legacy migration: reserve a possible prior attempt before autonomous I/O.
            try journal.save(record); snapshot = try store.recoverySnapshot()
            guard snapshot.generation > 0 else { throw PrivilegeError.journal }
            let time = retryClock(); guard time.isFinite, time >= 0 else { throw PrivilegeError.blocked }
            let retry = RecoveryRetry(record: record, generation: snapshot.generation, nonce: UUID(), since: time, last: time, emergency: emergency, clockFault: false)
            try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
            if !manual { return false }
            snapshot = try store.recoverySnapshot()
        }
        let time = retryClock()
        guard time.isFinite, time >= 0 else {
            if var retry = snapshot.retry {
                retry.clockFault = true; try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
            }
            throw PrivilegeError.blocked
        }
        if var retry = snapshot.retry {
            guard retry.record == record, retry.generation == snapshot.generation else { throw PrivilegeError.ownership }
            let interval = emergency ? RecoveryPolicy.emergency : RecoveryPolicy.ordinary
            switch nespat_retry_decision(time, retry.since, retry.last, retry.clockFault, retry.emergency, emergency, manual, interval) {
            case NSRetryReserve: break
            case NSRetryClockFault:
                retry.clockFault = true
                try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
                throw PrivilegeError.blocked
            case NSRetryRepairClock:
                retry.since = time; retry.last = time; retry.clockFault = false
                retry.emergency = retry.emergency || emergency
                try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
                if !manual { return false }
            case NSRetryWait:
                retry.last = time
                try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
                return false
            default: throw PrivilegeError.ownership
            }
        }
        let retry = RecoveryRetry(record: record, generation: snapshot.generation, nonce: UUID(), since: time, last: time, emergency: emergency, clockFault: false)
        var next = retry
        next.failures = snapshot.retry?.failures
        try store.saveRecoveryRetry(next, expected: record, generation: snapshot.generation)
        return true
    }
    private func recordRecoveryFailure(_ record: PrivilegedRecord) throws {
        guard let store = journal as? any PersistentRecoveryJournal else { throw PrivilegeError.blocked }
        let snapshot = try store.recoverySnapshot()
        guard var retry = snapshot.retry, retry.record == record, retry.generation == snapshot.generation else { throw PrivilegeError.ownership }
        let time = retryClock()
        guard (retry.failures ?? 0) < UInt64.max else { throw PrivilegeError.journal }
        retry.failures = (retry.failures ?? 0) + 1
        if time.isFinite, time >= retry.last { retry.since = time; retry.last = time }
        else { retry.clockFault = true }
        try store.saveRecoveryRetry(retry, expected: record, generation: snapshot.generation)
    }
    private func reply(_ record: PrivilegedRecord?, peer: Peer) -> Reply {
        let full: Bool
        if let grant = grants[peer.connection], case .full = grant.scope { full = true } else { full = false }
        var ticket: String?
        if let record, let policy = exclusivePolicy, (try? record.verifiedAttempt(policy)) != nil,
           record.owner.sameOwner(as: peer), let protected = journal as? ProtectedJournal {
            ticket = try? protected.recoveryTicket()
        }
        return Reply(state: observe(), session: record?.id, deadline: record?.deadline, authorityExpires: record?.authorityExpires,
                     active: record.map { $0.phase == .active }, fullAuthority: full, recoveryTicket: ticket, selectedLifetime: record?.exclusiveAttempt?.selectedLifetime)
    }
}
