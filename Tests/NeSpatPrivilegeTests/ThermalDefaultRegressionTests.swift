import Testing
@testable import NeSpatPrivilegeCore
@Suite struct ThermalDefaultRegressionTests {
    @Test func omittedThermalIsNotKnownFalse() {
        let s=PowerSafetySnapshot(batteryPercent:80,externalPowerConnected:true,temperatureC:40)
        #expect(s.thermalObservation == nil)
        #expect(s.activationAssessment == .unknown && s.emergencyAssessment == .unknown)
    }
}
