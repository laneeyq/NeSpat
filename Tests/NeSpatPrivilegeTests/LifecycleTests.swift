import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct LifecycleRegressionTests {
    @Test func revokeFailureMustRetainOnlyRecovery() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.state = .unknown
        f.journal.record?.deadline = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
        #expect(f.journal.record?.id == id)
        f.state = .disabled
        do { _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        catch { Issue.record("Owned recovery was lost after revoke: \(error)") }
        #expect(f.state == .enabled)
    }
    @Test func sameVerifiedOwnerMustRecoverAfterDisconnectFailure() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.state = .unknown
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.disconnect(f.peer) }
        let next = Peer(connection: UUID(), uid: f.peer.uid, auditSession: f.peer.auditSession, codeIdentity: f.peer.codeIdentity)
        try f.admit(next); f.state = .disabled
        do { _ = try f.engine.handle(Request(operation: .recover, session: id), from: next) }
        catch { Issue.record("Verified owner reconnect lost recovery: \(error)") }
        #expect(f.state == .enabled)
    }
    @Test func enrollmentMustNotRunInConnectionDelegate() throws {
        // The deployment guard makes the issue dormant. Source invariant covers unreachable
        // future delegate path, without enabling it to create a false runtime proof.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NeSpatPrivilegeCore/SigningAndXPC.swift"), encoding: .utf8)
        let begin = try #require(source.range(of: "public func listener("))
        let end = try #require(source.range(of: "final class PrivilegeEndpoint"))
        let delegate = String(source[begin.lowerBound..<end.lowerBound])
        #expect(!delegate.contains("enrollment(peer.uid"), "Privileged enrollment must be deferred to authenticated RPC")
    }
    func nextPeer(_ f: PrivilegeFixture, uid: UInt32? = nil, audit: UInt32? = nil, identity: String? = nil) -> Peer {
        Peer(connection: UUID(), uid: uid ?? f.peer.uid, auditSession: audit ?? f.peer.auditSession,
             codeIdentity: identity ?? f.peer.codeIdentity)
    }

    @Test(arguments: Array(0..<8))
    func revokeFaultMatrixKeepsBoundedRecovery(_ fault: Int) throws {
        let f = PrivilegeFixture(); let id = try f.begin(); let before = f.journal.record
        switch fault {
        case 1: f.state = .unknown
        case 2: f.failSetter = true
        case 3: f.apply = false
        case 4: f.journal.record?.deadline = Date(timeIntervalSinceReferenceDate: .infinity)
        case 5: f.journal.failWrite = f.journal.writes + 1
        case 6: f.journal.busy = true
        case 7: f.journal.corrupt = true
        default: break
        }
        if fault == 0 || fault == 4 {
            _ = try f.engine.handle(Request(operation: .revoke), from: f.peer)
        } else {
            #expect(throws: (any Error).self) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
            #expect(f.journal.record == before)
            f.journal.busy = false; f.journal.corrupt = false; f.journal.failWrite = nil
            #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
            #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .changeDeadline, session: id, minutes: 500), from: f.peer) }
            #expect(throws: PrivilegeError.denied) { try f.admit() }
            f.failSetter = false; f.apply = true
            if fault != 5 { f.state = .disabled }
            _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer)
        }
        #expect(f.state == .enabled && f.journal.record == nil)
        #expect(throws: PrivilegeError.denied) { try f.admit(nextPeer(f)) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
    }

    @Test(arguments: [0, 1, 2, 3])
    func reconnectRejectsChangedPrincipalOrStolenUUID(_ variant: Int) throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.state = .unknown
        #expect(throws: (any Error).self) { try f.engine.disconnect(f.peer) }
        let other = nextPeer(f, uid: variant == 0 ? 502 : nil, audit: variant == 1 ? 999 : nil,
                             identity: variant == 2 ? "other-publisher/app" : (variant == 3 ? "" : nil))
        f.state = .disabled
        if variant == 3 { #expect(throws: PrivilegeError.denied) { try f.admit(other) } }
        else { #expect(throws: PrivilegeError.ownership) { try f.admit(other) } }
        #expect(throws: (any Error).self) { try f.engine.handle(Request(operation: .recover, session: id), from: other) }
        #expect(f.changes == [true] && f.journal.record?.id == id)
    }

    @Test func reconnectNeverInheritsFullOrAllowsLiveOwnerDisplacement() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); let next = nextPeer(f)
        #expect(throws: PrivilegeError.ownership) { try f.admit(next) }
        f.state = .unknown
        #expect(throws: (any Error).self) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
        #expect(throws: PrivilegeError.ownership) { try f.admit(next) }
        #expect(throws: (any Error).self) { try f.engine.disconnect(f.peer) }
        try f.admit(next)
        let third = nextPeer(f)
        #expect(throws: PrivilegeError.ownership) { try f.admit(third) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: next) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .changeDeadline, session: id, minutes: 35), from: next) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .end, session: id), from: next) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        f.state = .disabled
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: next)
        #expect(f.state == .enabled && f.journal.record == nil)
        #expect(throws: PrivilegeError.denied) { try f.admit(next) }
    }

    @Test func replayBetweenConnectionsIsRejected() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.state = .unknown
        let request = Request(operation: .recover, session: id)
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.handle(request, from: f.peer) }
        #expect(throws: PrivilegeError.unknownPower) { try f.engine.disconnect(f.peer) }
        let next = nextPeer(f); try f.admit(next); f.state = .disabled
        #expect(throws: PrivilegeError.replay) { try f.engine.handle(request, from: next) }
        #expect(f.changes == [true])
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: next)
        #expect(f.changes == [true, false])
    }

    @Test func engineRestartCannotResurrectGrantAndBootChangeBlocksReconnect() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        let restarted = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime }, observe: { f.state }, setDisabled: { f.changes.append($0); f.state = .enabled })
        #expect(throws: PrivilegeError.denied) { try restarted.handle(Request(operation: .recover, session: id), from: f.peer) }
        let next = nextPeer(f)
        #expect(throws: PrivilegeError.ownership) { try restarted.admit(next, expires: 1000) }
        let provenInactive = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime }, observe: { f.state }, setDisabled: { f.changes.append($0); f.state = .enabled }, ownerLiveness: { _ in .inactive })
        try provenInactive.admit(next, expires: 1000)
        #expect(throws: PrivilegeError.denied) { try provenInactive.handle(Request(operation: .begin), from: next) }
        _ = try provenInactive.handle(Request(operation: .recover, session: id), from: next)
        #expect(f.state == .enabled)
        let g = PrivilegeFixture(); _ = try g.begin()
        let rebooted = PrivilegeEngine(journal: g.journal, boot: UUID(), now: { g.wall }, monotonic: { g.uptime }, observe: { g.state }, setDisabled: { g.changes.append($0) })
        #expect(throws: PrivilegeError.ownership) { try rebooted.admit(nextPeer(g), expires: 1000) }
        #expect(g.changes == [true])
    }

    @Test func legacyOwnerWithoutSignerDoesNotAuthorizeRecovery() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        f.journal.record?.owner = Peer(connection: f.peer.connection, uid: f.peer.uid, auditSession: f.peer.auditSession)
        #expect(throws: PrivilegeError.ownership) { try f.engine.tick() }
        #expect(throws: PrivilegeError.ownership) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        let bytes = try JSONEncoder().encode(f.journal.record)
        let decoded = try JSONDecoder().decode(PrivilegedRecord.self, from: bytes)
        #expect(decoded.owner.codeIdentity == nil)
        #expect(f.changes == [true])
    }

    @Test func expiryDowngradesRatherThanErasesRecovery() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.uptime = 1001
        f.journal.record?.deadline = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer)
        #expect(f.state == .enabled)
    }

    @Test func connectionTombstonesAndRequestBudgetAreBounded() throws {
        let f = PrivilegeFixture()
        for offset in 0..<4096 { let peer = nextPeer(f, uid: UInt32(1000 + offset)); try f.admit(peer); try f.engine.disconnect(peer) }
        #expect(throws: PrivilegeError.denied) { try f.admit(nextPeer(f)) }
        let g = PrivilegeFixture(); let id = try g.begin()
        for _ in 0..<4095 { _ = try g.engine.handle(Request(operation: .status), from: g.peer) }
        #expect(throws: PrivilegeError.denied) { try g.engine.handle(Request(operation: .status), from: g.peer) }
        _ = try g.engine.handle(Request(operation: .revoke), from: g.peer)
        #expect(g.state == .enabled && g.journal.record == nil)
        #expect(throws: PrivilegeError.denied) { try g.engine.handle(Request(operation: .recover, session: id), from: g.peer) }
    }

    @Test func revokeDisconnectRecoverTickAreSerialized() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                switch index % 4 {
                case 0: _ = try f.engine.handle(Request(operation: .revoke), from: f.peer)
                case 1: try f.engine.disconnect(f.peer)
                case 2: _ = try f.engine.handle(Request(operation: .recover, session: id), from: f.peer)
                default: try f.engine.tick()
                }
            } catch PrivilegeError.denied { }
            catch PrivilegeError.ownership { } // Another serialized lifecycle operation already ended the record.
            catch { Issue.record("Unexpected race outcome: \(error)") }
        }
        #expect(f.changes == [true, false])
        #expect(f.journal.record == nil)
    }

    @Test func authorityLossCannotBeReplacedByKnowledgeOfUUID() throws {
        let f = PrivilegeFixture(); let id = try f.begin(); f.journal.record = nil
        #expect(throws: PrivilegeError.ownership) { try f.engine.handle(Request(operation: .revoke), from: f.peer) }
        #expect(throws: PrivilegeError.ownership) { try f.engine.handle(Request(operation: .recover, session: id), from: f.peer) }
        #expect(throws: PrivilegeError.denied) { try f.engine.handle(Request(operation: .begin), from: f.peer) }
        #expect(f.changes == [true])
    }
    @Test func independentLiveOwnerProofOverridesLostConnectionMemory() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        let observer = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime }, observe: { f.state }, setDisabled: { f.changes.append($0) }, ownerLiveness: { _ in .active })
        let peer = nextPeer(f)
        #expect(throws: PrivilegeError.ownership) { try observer.admit(peer, expires: 1000) }
        #expect(throws: PrivilegeError.denied) { try observer.handle(Request(operation: .recover, session: id), from: peer) }
        #expect(f.changes == [true])
    }
    @Test func livenessIsRecheckedAtRecoveryNotOnlyAdmission() throws {
        let f = PrivilegeFixture(); let id = try f.begin()
        var liveness = OwnerLiveness.inactive
        let engine = PrivilegeEngine(journal: f.journal, boot: f.boot, now: { f.wall }, monotonic: { f.uptime }, observe: { f.state }, setDisabled: { f.changes.append($0); f.state = .enabled }, ownerLiveness: { _ in liveness })
        let peer = nextPeer(f); try engine.admit(peer, expires: 1000)
        liveness = .active
        #expect(throws: PrivilegeError.ownership) { try engine.handle(Request(operation: .recover, session: id), from: peer) }
        #expect(throws: PrivilegeError.ownership) { try engine.handle(Request(operation: .revoke), from: peer) }
        #expect(throws: PrivilegeError.ownership) { try engine.tick() }
        #expect(f.changes == [true])
        liveness = .inactive
        _ = try engine.handle(Request(operation: .recover, session: id), from: peer)
        #expect(f.changes == [true,false])
    }
}
