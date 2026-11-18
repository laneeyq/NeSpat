import Foundation
import Testing
@testable import NeSpatPrivilegeCore

final class HeartbeatFixture: @unchecked Sendable {
    let f = PrivilegeFixture()
    let engine: PrivilegeEngine
    init(timeout: Double? = 10, maximum: Double = 100) throws {
        let f=self.f
        engine=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{ f.changes.append($0);f.onSet?();if f.failSetter {throw PrivilegeError.unconfirmed};if f.apply {f.state = $0 ? .disabled : .enabled}},
            fullGrantPolicy:try FullGrantLifetimePolicy(maximumLifetime:maximum),
            heartbeatPolicy:try timeout.map {try HeartbeatPolicy(timeout:$0)}, safetySnapshot: { fixtureSafetySnapshot }, retryClock: { f.uptime })
    }
    func begin(expires:Double = 100) throws -> UUID {
        let c=try engine.enrollmentChallenge(for:f.peer)
        try engine.admit(f.peer,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:f.uptime,expires:expires)))
        return try #require(engine.handle(Request(operation:.begin,minutes:10000),from:f.peer).session)
    }
}
@Suite struct HeartbeatTests {
    @Test(arguments:[Double(0),-1,.nan,.infinity,-.infinity]) func invalidServerTimeoutIsRejected(_ value:Double) {
        #expect(throws:PrivilegeError.blocked) {try HeartbeatPolicy(timeout:value)}
    }
    @Test func heartbeatRefreshesLivenessWithoutJournalOrPowerWrites() throws {
        let h=try HeartbeatFixture(),id=try h.begin();let f=h.f,writes=f.journal.writes,deadline=f.journal.record?.deadline
        f.uptime=19
        _=try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)
        #expect(f.journal.writes == writes && f.changes == [true] && f.journal.record?.deadline == deadline)
        f.uptime=Double(29).nextDown;try h.engine.tick();#expect(f.state == .disabled)
        f.uptime=29;try h.engine.tick();#expect(f.state == .enabled && f.changes == [true,false])
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.begin),from:f.peer)}
    }
    @Test func repeatedHeartbeatCannotExtendFullGrantExpiry() throws {
        let h=try HeartbeatFixture(maximum:20),id=try h.begin(expires:30),f=h.f
        for time in [19.0,28.0,29.0] {f.uptime=time;_=try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        f.uptime=30
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        #expect(f.changes == [true] && f.journal.record?.id == id)
        try h.engine.tick();#expect(f.changes == [true,false] && f.journal.record == nil)
    }
    @Test func replayDoesNotRefreshHeartbeat() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f,request=Request(operation:.heartbeat,session:id)
        f.uptime=15;_=try h.engine.handle(request,from:f.peer)
        f.uptime=24;#expect(throws:PrivilegeError.replay) {try h.engine.handle(request,from:f.peer)}
        f.uptime=25;try h.engine.tick();#expect(f.changes == [true,false])
    }
    @Test(arguments:Array(0..<5)) func lostOrSubstitutedJournalNeverRenewsOrRestores(_ variant:Int) throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f,writes=f.journal.writes
        switch variant {
        case 0:f.journal.record=nil
        case 1:f.journal.record?.id=UUID()
        case 2:f.journal.record?.owner=Peer(connection:UUID(),uid:502,auditSession:123,codeIdentity:"other")
        case 3:f.journal.record?.phase = .pending
        default:f.journal.corrupt=true
        }
        #expect(throws:(any Error).self) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        f.uptime=30;try? h.engine.tick()
        #expect(f.changes == [true] && f.journal.writes == writes)
    }
    @Test func forgedPeerOrMalformedRequestCannotRefreshLease() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f
        let forged=Peer(connection:f.peer.connection,uid:502,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:forged)}
        for request in [Request(operation:.heartbeat),Request(operation:.heartbeat,session:id,minutes:1)] {
            #expect(throws:PrivilegeError.malformed) {try h.engine.handle(request,from:f.peer)}
        }
        f.uptime=20;try h.engine.tick();#expect(f.changes == [true,false])
    }
    @Test func unavailablePolicyDoesNotInventAHeartbeatContract() throws {
        let h=try HeartbeatFixture(timeout:nil),id=try h.begin(),f=h.f
        #expect(throws:PrivilegeError.blocked) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        f.uptime=21;try h.engine.tick();#expect(f.changes == [true])
        f.uptime=100;try h.engine.tick();#expect(f.changes == [true,false])
    }
    @Test func expiredLeaseDowngradesBeforeFailedRecoveryAndCannotBeRevived() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f;f.apply=false;f.uptime=20
        #expect(throws:PrivilegeError.unconfirmed) {try h.engine.tick()}
        #expect(f.journal.record?.id == id && f.state == .disabled)
        f.uptime=21
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.changeDeadline,session:id,minutes:20),from:f.peer)}
        f.apply=true;_=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.state == .enabled && f.journal.record == nil)
    }
    @Test func unknownPowerDoesNotRenewAndKeepsRecoveryEvidence() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f;f.state = .unknown;f.uptime=15
        #expect(throws:PrivilegeError.unknownPower) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:f.peer)}
        f.uptime=20;#expect(throws:PrivilegeError.unknownPower) {try h.engine.tick()}
        #expect(f.journal.record?.id == id && f.changes == [true])
        f.state = .disabled;_=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.changes == [true,false])
    }
    @Test func reconnectRecoveryOnlyCannotHeartbeatOrReenable() throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f;f.state = .unknown
        #expect(throws:PrivilegeError.unknownPower) {try h.engine.disconnect(f.peer)}
        let next=Peer(connection:UUID(),uid:f.peer.uid,auditSession:f.peer.auditSession,codeIdentity:f.peer.codeIdentity)
        try h.engine.admit(next,expires:90)
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.heartbeat,session:id),from:next)}
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.begin),from:next)}
        f.state = .disabled;_=try h.engine.handle(Request(operation:.recover,session:id),from:next)
        #expect(f.changes == [true,false])
    }
    @Test func autonomousWatchdogReportsUncertaintyAndNeverCallsEmergencySleep() async throws {
        let h=try HeartbeatFixture(),id=try h.begin(),f=h.f;let watchdog=HelperWatchdog(engine:h.engine)
        #expect(await watchdog.outcome == .notChecked)
        #expect(await watchdog.poll() == .checked && f.changes == [true])
        f.uptime=20;f.state = .unknown
        #expect(await watchdog.poll() == .recoveryRequired && f.journal.record?.id == id)
        f.state = .disabled
        #expect(await watchdog.poll() == .checked && f.changes == [true,false])
        #expect(f.journal.record == nil)
    }
    @Test func watchdogLoopIsExplicitBoundedByCancellationAndCannotDuplicate() async throws {
        let h=try HeartbeatFixture(),watchdog=HelperWatchdog(engine:h.engine)
        do {try await watchdog.run(every:.zero);Issue.record("Invalid schedule accepted")} catch {#expect(error as? PrivilegeError == .blocked)}
        let loop=Task {try await watchdog.run(every:.milliseconds(5))}
        while await watchdog.outcome == .notChecked {await Task.yield()}
        do {try await watchdog.run(every:.seconds(1));Issue.record("Duplicate loop accepted")} catch {#expect(error as? PrivilegeError == .blocked)}
        loop.cancel();_=try? await loop.value
        #expect(h.f.changes.isEmpty && h.f.journal.writes == 0)
    }
}
