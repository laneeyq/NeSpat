import Foundation
import Testing
@testable import NeSpatPrivilegeCore

final class ServerSafetyFixture: @unchecked Sendable {
    let f=PrivilegeFixture()
    var sample=fixtureSafetySnapshot
    var samples=0
    var onSample:((Int)->Void)?
    lazy var engine=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{self.f.wall},monotonic:{self.f.uptime},observe:{self.f.state},
        setDisabled:{self.f.changes.append($0);self.f.onSet?();if self.f.apply {self.f.state = $0 ? .disabled : .enabled}},
        fullGrantPolicy:fixtureFullGrantPolicy,safetySnapshot:{self.samples += 1;self.onSample?(self.samples);return self.sample},requireCompleteSafety:false)
    func admit() throws {
        let c=try engine.enrollmentChallenge(for:f.peer)
        try engine.admit(f.peer,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:10,expires:100)))
    }
    func begin() throws ->UUID {try admit();return try #require(engine.handle(Request(operation:.begin,minutes:60),from:f.peer).session)}
}
@Suite struct ServerSafetyTests {
    @Test func criticalRecoveryFailureCannotLeaveFullAuthorityAlive() throws {
        let h=ServerSafetyFixture(),id=try h.begin(),f=h.f
        h.sample = .init(thermalSerious:true);f.apply=false
        #expect(throws:PrivilegeError.unconfirmed) {try h.engine.tick()}
        h.sample=fixtureSafetySnapshot
        #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.changeDeadline,session:id,minutes:1),from:f.peer)}
        f.apply=true;_=try h.engine.handle(Request(operation:.recover,session:id),from:f.peer)
        #expect(f.changes == [true,false,false] && f.journal.record == nil)
    }
    @Test(arguments:[false,true]) func journalLossOrSubstitutionDuringSafetySampleNeverRestores(_ substitute:Bool) throws {
        let h=ServerSafetyFixture();_=try h.begin();let f=h.f
        h.onSample={_ in
            h.sample = .init(thermalSerious:true)
            if substitute {f.journal.record?.owner=Peer(connection:UUID(),uid:502,auditSession:123,codeIdentity:"other owner")}
            else {f.journal.record=nil}
        }
        #expect(throws:PrivilegeError.ownership) {try h.engine.tick()}
        #expect(f.changes == [true])
    }
    @Test(arguments:Array(0..<8)) func serverActivationThresholdsAndIndependentReadings(_ variant:Int) throws {
        let h=ServerSafetyFixture(),f=h.f
        let readings:[PowerSafetySnapshot]=[
            .init(batteryPercent:14,externalPowerConnected:false),.init(batteryPercent:15,externalPowerConnected:false),
            .init(batteryPercent:10,externalPowerConnected:true),.init(temperatureC:95),.init(temperatureC:94.9),
            .init(thermalSerious:true),.init(batteryPercent:14.999,externalPowerConnected:false),.init(batteryPercent:10,externalPowerConnected:nil)]
        h.sample=readings[variant];try h.admit()
        if [0,3,5,6].contains(variant) {
            #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.begin),from:f.peer)}
            #expect(f.changes.isEmpty && f.journal.writes == 0)
        } else {
            _=try h.engine.handle(Request(operation:.begin),from:f.peer);#expect(f.changes == [true])
        }
    }
    @Test(arguments:Array(0..<4)) func criticalServerReadingsRestoreWithoutForcingSleep(_ variant:Int) throws {
        let h=ServerSafetyFixture();_=try h.begin();let f=h.f
        let readings:[PowerSafetySnapshot]=[.init(batteryPercent:10,externalPowerConnected:false),.init(temperatureC:95),.init(thermalSerious:true),.init(batteryPercent:14,externalPowerConnected:false)]
        h.sample=readings[variant];try h.engine.tick()
        #expect(f.changes == (variant == 3 ? [true] : [true,false]))
        if variant < 3 {
            h.sample=fixtureSafetySnapshot
            #expect(throws:PrivilegeError.denied) {try h.engine.handle(Request(operation:.begin),from:f.peer)}
        }
    }
    @Test(arguments:Array(0..<5)) func finalSamplingRevalidatesIntentPowerAndLifetimeBeforeSetter(_ variant:Int) throws {
        let h=ServerSafetyFixture(),f=h.f;try h.admit()
        h.onSample={n in
            guard n == 2 else {return}
            switch variant {
            case 0:h.sample = .init(thermalSerious:true)
            case 1:f.journal.record?.id=UUID()
            case 2:f.state = .unknown
            case 3:f.state = .disabled // A new external writer, never our change.
            default:f.uptime=100
            }
        }
        #expect(throws:(any Error).self) {try h.engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty)
        if variant == 0 || variant == 4 {#expect(f.journal.record == nil && f.state == .enabled)}
        else {#expect(f.journal.record != nil)}
    }
    @Test func invalidSensorValuesStayUnknownAndNeverInventCriticalConditions() {
        for value in [Double.nan,.infinity,-.infinity,-1,150] {
            let s=PowerSafetySnapshot(batteryPercent:value,externalPowerConnected:false,temperatureC:value)
            #expect(s.batteryPercent == nil && s.temperatureC == nil && s.emergencyReason == nil)
        }
    }
}
