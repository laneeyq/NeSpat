import Foundation
import IOKit

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
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard device != 0 else { return Self() }
        defer { IOObjectRelease(device) }
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let data = read("BatteryData") as? [String: Any] ?? [:]
        func number(_ key: String, minimum: Int = 1) -> Int? {
            guard let value = (read(key) ?? data[key]) as? Int, value >= minimum else { return nil }
            return value
        }
        return Self(cycles: number("CycleCount", minimum: 0), design: number("DesignCapacity"),
                    full: number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"),
                    remaining: number("AppleRawCurrentCapacity", minimum: 0))
    }
}
