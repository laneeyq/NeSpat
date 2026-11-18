import Foundation
import Testing
@testable import NeSpatLiveTestCore

@Suite struct ManualRequestTests {
    @Test func cancelledApprovalCannotReplayEvenAgainstIdenticalRecord() throws {
        let f = Rig(); try f.arm(); let original = f.store.record
        var cached: LiveManualApproval?
        f.backend.onAuthorize = { request in
            #expect(!f.store.busy && !f.backend.busy)
            if cached == nil { cached = LiveManualApproval(request: request); throw LiveError.denied }
            return cached!
        }
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(f.store.record == original && f.backend.calls == [.activate])
        #expect(f.backend.authorizationRequests.count == 2 && Set(f.backend.authorizationRequests).count == 2)
        f.backend.onAuthorize = nil; f.backend.manualAllowed = true; f.backend.manualSession = f.binding.session
        try f.recovery.manualRecover(client: f.client)
        #expect(f.store.record.phase == .completed && f.backend.calls == [.activate, .restore])
        #expect(throws: (any Error).self) { try f.arm() }
        #expect(throws: (any Error).self) { try f.control.extend(client: f.client, duration: 120) }
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5]) func alteredApprovalScopeNeverStartsSetter(_ variant: Int) throws {
        let f = Rig(); try f.arm()
        f.backend.onAuthorize = { request in
            var record = request.record; var client = request.client; var id = request.id
            switch variant {
            case 0: id = UUID()
            case 1: record.generation += 1
            case 2: record.expires = 129
            case 3: record.phase = .completed
            case 4: record.interferenceDetected = true
            default: client = LivePeer(role: .client, uid: 502, pid: 99, started: 1, codeHash: "client", signingID: LiveTestDeployment.clientID)
            }
            return LiveManualApproval(request: LiveManualRequest(id: id, client: client, record: record))
        }
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(f.backend.calls == [.activate] && !f.store.record.retired)
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5]) func journalChangesDuringConsentInvalidateApproval(_ variant: Int) throws {
        let f = Rig(); try f.arm()
        f.backend.onAuthorize = { request in
            #expect(!f.store.busy && !f.backend.busy)
            switch variant {
            case 0: f.store.record.generation += 1
            case 1: f.store.record.expires = 129
            case 2: f.store.record.phase = .completed
            case 3: f.store.record.interferenceDetected = true
            case 4:
                let binding = LiveBinding(authorization: UUID(), boot: f.binding.boot, session: UUID(), uid: 501, exclusiveControl: true, clientHash: "client", helperHash: "helper", recoveryHash: "watcher")
                f.store.record = LiveRecord(version: 2, binding: binding, session: binding.session)
            default:
                f.store.record.owner = LivePeer(role: .client, uid: 501, pid: 99, started: 2, codeHash: "client", signingID: LiveTestDeployment.clientID)
            }
            return LiveManualApproval(request: request)
        }
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(f.backend.calls == [.activate])
    }
    @Test(arguments: [false, true]) func consentDelayOrCancellationDoesNotStopAutonomousRecovery(_ cancel: Bool) throws {
        let f = Rig(); try f.arm()
        f.backend.onAuthorize = { request in
            #expect(!f.store.busy && !f.backend.busy)
            f.backend.sample.continuous = 130; try f.recovery.poll()
            if cancel { throw LiveError.denied }
            return LiveManualApproval(request: request)
        }
        #expect(throws: (any Error).self) { try f.recovery.manualRecover(client: f.client) }
        #expect(f.store.record.phase == .completed && f.store.record.retired)
        #expect(f.backend.calls == [.activate, .restore])
    }
}
