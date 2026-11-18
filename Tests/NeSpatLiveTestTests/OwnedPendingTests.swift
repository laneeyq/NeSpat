import Foundation
import Testing
import NeSpatPrivilegeCore
@testable import NeSpatLiveTestCore

@Suite struct OwnedPendingTests {
    @Test func trustedOwnAttemptRecoversAfterHelperLostResult() throws {
        let f = Rig()
        f.backend.onExecute = { f.backend.sample.power = .disabled; throw LiveError.state }
        #expect(throws: (any Error).self) { try f.arm() }
        f.backend.onExecute = nil; f.backend.sample.continuous = 130
        try f.recovery.poll()
        #expect(f.store.record.phase == .completed && f.backend.sample.power == .enabled)
        #expect(f.backend.calls == [.activate, .restore])
    }
    @Test func processDiesBetweenMockSetterAndResultThenIndependentRecovery() throws {
        let f = try DiskRig(); defer { try? f.cleanup() }
        #expect(try f.child("NeSpatLiveTestHelper", "--fixture-crash-after", time: 10) == 86)
        #expect(try f.child("NeSpatLiveRecoveryWatchdog", "--fixture-poll", time: 130) == 0)
        let r = try f.store.exclusive { try f.store.load() }
        #expect(r.phase == .completed && r.expires == 130)
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5]) func incompleteOrForeignAttemptNeverRestores(_ variant: Int) throws {
        let f = Rig(); f.backend.onExecute = { throw LiveError.state }
        #expect(throws: (any Error).self) { try f.arm() }
        f.backend.onExecute = nil; f.backend.sample.power = .disabled; f.backend.sample.continuous = 130
        let own = f.store.record.attempt!
        switch variant {
        case 0: f.store.record.attempt = nil
        case 1: f.store.record.baselineNo = false
        case 2: f.store.record.baselineNo = nil
        case 3: f.store.record.attempt = LiveAttempt(session: UUID(), helper: own.helper, client: own.client, at: own.at, nonce: own.nonce)
        case 4: f.store.record.attempt = LiveAttempt(session: own.session, helper: own.helper, client: own.client, at: 130, nonce: own.nonce)
        default:
            let foreign = LivePeer(role: .helper, uid: 501, pid: 20, started: 1, codeHash: "helper", signingID: LiveTestDeployment.helperID)
            f.store.record.attempt = LiveAttempt(session: own.session, helper: foreign, client: own.client, at: own.at, nonce: own.nonce)
        }
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.backend.calls == [.activate])
    }
    @Test func originalYesNeverCreatesOwnReservation() {
        let f = Rig(); f.backend.sample.power = .disabled
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(f.store.record.attempt == nil && !f.store.record.consumed && f.backend.calls.isEmpty)
    }
    @Test func missingSingleWriterAgreementCannotIssueTestAuthority() {
        let f = Rig()
        let b = LiveBinding(authorization: UUID(), boot: f.binding.boot, session: UUID(), uid: 501, exclusiveControl: false, clientHash: "client", helperHash: "helper", recoveryHash: "watcher")
        f.store.record = LiveRecord(version: 2, binding: b, session: b.session)
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(f.backend.calls.isEmpty && !f.store.record.consumed)
    }
    @Test func activeSharedCooldownOrForeignObligationBlocksBeforeGrant() {
        for owner in [nil, UUID()] as [UUID?] {
            let f = Rig()
            f.backend.sample.recoveryAdmission = LiveRecoveryAdmission(boot: f.binding.boot, owner: owner, notBefore: 310)
            #expect(throws: (any Error).self) { try f.arm() }
            #expect(!f.store.record.consumed && f.backend.calls.isEmpty)
        }
    }
    @Test func newSessionIdentityDoesNotBypassSharedRecoveryDomain() {
        let f = Rig()
        f.backend.sample.recoveryAdmission = LiveRecoveryAdmission(boot: f.binding.boot, owner: UUID(), notBefore: 0)
        #expect(throws: (any Error).self) { try f.arm() }
        let b = LiveBinding(authorization: UUID(), boot: f.binding.boot, session: UUID(), uid: 501, exclusiveControl: true, clientHash: "client", helperHash: "helper", recoveryHash: "watcher")
        f.store.record = LiveRecord(version: 2, binding: b, session: b.session)
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(f.backend.calls.isEmpty)
    }
    @Test func firstFailurePersistsFailedAndManualNeedsFreshSessionScopedAuthority() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130; f.backend.applies = false
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.failedAttempts == 1 && f.store.record.lastFailure == 130)
        #expect(try !f.recovery.canRemove())
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        f.backend.manualAllowed = true; f.backend.manualSession = UUID(); f.backend.applies = true
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        f.backend.manualSession = f.binding.session
        let foreign = LivePeer(role: .client, uid: 502, pid: 99, started: 2, codeHash: "client", signingID: LiveTestDeployment.clientID)
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: foreign) }
        #expect(f.backend.calls.count == 2)
        let replacementGUI = LivePeer(role: .client, uid: 501, pid: 99, started: 2, codeHash: "client", signingID: LiveTestDeployment.clientID)
        try f.recovery.manualRecover(client: replacementGUI)
        #expect(f.store.record.owner == f.client)
        #expect(f.store.record.phase == .completed && f.store.record.failedAttempts == 1)
        #expect(try f.recovery.canRemove())
        try f.recovery.poll(); #expect(f.backend.calls.count == 3)
    }
    @Test func detectedInterferenceLatchesStopEvenWhenItLaterDisappears() throws {
        let f = Rig(); try f.arm(); f.backend.sample.continuous = 130
        f.backend.sample.foreignInterference = true
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        f.backend.sample.foreignInterference = false; f.backend.manualAllowed = true; f.backend.manualSession = f.binding.session
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(f.store.record.interferenceDetected && f.backend.calls == [.activate])
    }
    @Test func foreignYesBeforeOwnSyscallCannotBeClaimedUsingAttemptMarker() throws {
        let f = Rig(); var reads = 0
        f.backend.onRead = { reads += 1; if reads == 3 { f.backend.sample.power = .disabled } }
        #expect(throws: (any Error).self) { try f.arm() }
        f.backend.onRead = nil; f.backend.sample.continuous = 130
        #expect(throws: (any Error).self) { try f.recovery.poll() }
        #expect(f.store.record.interferenceDetected && f.backend.calls.isEmpty)
    }
    @Test func unknownSensorsPermitOnlyRecoveryOfOwnPendingAttempt() throws {
        let f = Rig(); f.backend.onExecute = { f.backend.sample.power = .disabled; throw LiveError.state }
        #expect(throws: (any Error).self) { try f.arm() }
        f.backend.onExecute = nil; f.backend.sample.safety = PowerSafetySnapshot()
        try f.recovery.poll()
        #expect(f.store.record.retired && f.store.record.phase == .completed)
    }
    @Test func missingRecoveryViewOrInterferenceKnowledgeStops() {
        for missing in [true, false] {
            let f = Rig()
            if missing { f.backend.sample.recoveryAdmission = nil } else { f.backend.sample.foreignInterference = nil }
            #expect(throws: (any Error).self) { try f.arm() }
            #expect(f.backend.calls.isEmpty)
        }
    }
    @Test func watchdogCanPersistExpiryWhileActivationSetterIsStillBusy() throws {
        let f = Rig()
        f.backend.onExecute = {
            f.backend.sample.power = .disabled; f.backend.sample.continuous = 130
            #expect(throws: (any Error).self) { try f.recovery.poll() } // Setter lock remains held.
            #expect(f.store.record.initiated == 130 && f.store.record.retired)
            #expect(f.store.record.retry == nil)
        }
        #expect(throws: (any Error).self) { try f.arm() } // Expiry cannot be promoted to active.
        f.backend.onExecute = nil
        try f.recovery.poll()
        #expect(f.store.record.phase == .completed)
    }
}
