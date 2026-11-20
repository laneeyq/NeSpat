import Foundation
import NeSpatNative

struct BatteryDetails {
    var cycles: Int?
    var design: Int?
    var full: Int?
    var remaining: Int?
    var health: Int? {
        guard let full, let design, design > 0 else { return nil }
        return Int((Double(full) / Double(design) * 100).rounded())
    }

    static func read() -> Self {
        let sample = nespat_battery_details()
        func value(_ raw: Int64) -> Int? { raw >= 0 ? Int(exactly: raw) : nil }
        return Self(cycles: value(sample.cycles), design: value(sample.design),
                    full: value(sample.full), remaining: value(sample.remaining))
    }
}
