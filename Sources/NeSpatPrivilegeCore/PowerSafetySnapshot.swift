import Foundation
import NeSpatNative

/// Independent server readings, never decoded from RPC or supplied as client claims.
/// Unknown sensors stay unknown; thresholds are shared with the existing GUI policy.
public struct PowerSafetySnapshot: Sendable {
    public let batteryPercent: Double?
    public let externalPowerConnected: Bool?
    public let temperatureC: Double?
    public let thermalObservation: Bool?
    public var thermalSerious: Bool { thermalObservation == true }
    public init(batteryPercent: Double? = nil, externalPowerConnected: Bool? = nil,
                temperatureC: Double? = nil, thermalSerious: Bool? = nil) {
        self.batteryPercent = batteryPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.externalPowerConnected = externalPowerConnected
        self.temperatureC = temperatureC.flatMap { $0.isFinite && $0 > 0 && $0 < 150 ? $0 : nil }
        self.thermalObservation = thermalSerious
    }
    public enum Assessment: Equatable, Sendable { case confirmedDanger, noDangerDetected, unknown }
    private func decision(starting: Bool) -> UInt8 {
        nespat_assess(batteryPercent ?? .nan, externalPowerConnected.map { $0 ? 1 : 0 } ?? -1,
                      temperatureC ?? .nan, thermalObservation.map { $0 ? 1 : 0 } ?? -1, starting)
    }
    private func assessment(starting: Bool) -> Assessment {
        switch decision(starting: starting) {
        case 0: return .noDangerDetected
        case 2...5: return .confirmedDanger
        default: return .unknown
        }
    }
    public var activationAssessment: Assessment { assessment(starting: true) }
    public var emergencyAssessment: Assessment { assessment(starting: false) }
    public var activationRefusalReason: String? { reason(starting: true) }
    public var emergencyReason: String? { reason(starting: false) }
    private func reason(starting: Bool) -> String? {
        switch decision(starting: starting) {
        case 2: return "перегрев (thermal state)"
        case 3: return temperatureC.map { "температура \(Int($0.rounded()))°" }
        case 4: return batteryPercent.map { "заряд \(Int($0.rounded()))%" }
        case 5: return batteryPercent.map { "заряд \(Int($0.rounded()))% без внешнего питания" }
        default: return nil
        }
    }
}
