import Testing
@testable import NeSpatPrivilegeCore

@Suite struct SensorAssessmentTests {
    @Test(arguments:Array(0..<4)) func missingReadingsAreUnknownWithoutInventedDanger(_ variant:Int) {
        let s=PowerSafetySnapshot(batteryPercent:variant == 0 ? nil : 80,
            externalPowerConnected:variant == 1 ? nil : false,
            temperatureC:variant == 2 ? nil : 40,thermalSerious:variant == 3 ? nil : false)
        #expect(s.activationAssessment == .unknown && s.emergencyAssessment == .unknown)
        #expect(s.activationRefusalReason == nil && s.emergencyReason == nil)
    }
    @Test func confirmedDangerWinsOverMissingReadings() {
        let s=PowerSafetySnapshot(temperatureC:95,thermalSerious:nil)
        #expect(s.activationAssessment == .confirmedDanger && s.emergencyAssessment == .confirmedDanger)
    }
    @Test func activationAndEmergencyRemainDifferent() {
        let s=PowerSafetySnapshot(batteryPercent:14,externalPowerConnected:false,temperatureC:40,thermalSerious:false)
        #expect(s.activationAssessment == .confirmedDanger && s.emergencyAssessment == .noDangerDetected)
        #expect(s.activationRefusalReason != nil && s.emergencyReason == nil)
    }
    @Test func lossDuringSessionIsClassificationNotAnAutomaticSleepRequest() {
        let known=PowerSafetySnapshot(batteryPercent:80,externalPowerConnected:false,temperatureC:40,thermalSerious:false)
        let lost=PowerSafetySnapshot(batteryPercent:80,externalPowerConnected:nil,thermalSerious:nil)
        #expect(known.emergencyAssessment == .noDangerDetected && lost.emergencyAssessment == .unknown)
        #expect(lost.emergencyReason == nil)
    }
}

@Suite struct StrictServerSensorPolicyTests {
    @Test func strictServerDeniesUnknownAndRecoversLoss() throws {
        let f=PrivilegeFixture();var sample=fixtureSafetySnapshot
        let e=PrivilegeEngine(journal:f.journal,boot:f.boot,now:{f.wall},monotonic:{f.uptime},observe:{f.state},
            setDisabled:{f.changes.append($0);f.state = $0 ? .disabled : .enabled},fullGrantPolicy:fixtureFullGrantPolicy,
            safetySnapshot:{sample},requireCompleteSafety:true)
        let c=try e.enrollmentChallenge(for:f.peer)
        try e.admit(f.peer,authorization:.fresh(FreshAuthorization(trustedConsentFor:c,confirmedAt:10,expires:100)))
        sample = .init()
        #expect(throws:PrivilegeError.denied) {try e.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty)
        sample=fixtureSafetySnapshot;_=try e.handle(Request(operation:.begin),from:f.peer)
        sample = .init();try e.tick()
        #expect(f.changes == [true,false] && f.journal.record == nil)
        #expect(throws:PrivilegeError.denied) {try e.handle(Request(operation:.begin),from:f.peer)}
    }
}
