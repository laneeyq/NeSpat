import Foundation

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
    // Classification only: does not silently change activation/recovery policy.
    public var activationAssessment: Assessment {
        if activationRefusalReason != nil { return .confirmedDanger }
        return incomplete ? .unknown : .noDangerDetected
    }
    public var emergencyAssessment: Assessment {
        if emergencyReason != nil { return .confirmedDanger }
        return incomplete ? .unknown : .noDangerDetected
    }
    private var incomplete: Bool {
        batteryPercent == nil || externalPowerConnected == nil || temperatureC == nil || thermalObservation == nil
    }
    public var activationRefusalReason: String? {
        if let p = batteryPercent, externalPowerConnected == false, p < 15 { return "заряд \(Int(p.rounded()))%" }
        return emergencyReason
    }
    public var emergencyReason: String? {
        if thermalSerious { return "перегрев (thermal state)" }
        if let t = temperatureC, t >= 95 { return "температура \(Int(t.rounded()))°" }
        if let p = batteryPercent, externalPowerConnected == false, p <= 10 { return "заряд \(Int(p.rounded()))% без внешнего питания" }
        return nil
    }
}
