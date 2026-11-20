import Foundation
import IOKit
import NeSpatNative
import IOKit.ps
import MachO

// MARK: - Метрики: CPU, память, батарея, температура

final class StatsSampler: @unchecked Sendable {
    struct Sample {
        var cpuPercent: Double?
        var memUsedBytes: UInt64 = 0
        var memTotalBytes: UInt64 = 0
        var batteryPercent: Int?
        var isCharging: Bool?
        var isFullyCharged: Bool?
        var batteryMinutes: Int?
        var batteryPercentExact: Double?
        var batteryLevel: Double? {
            if let exact = batteryPercentExact { return exact.isFinite && (0...100).contains(exact) ? exact : nil }
            return batteryPercent.flatMap { (0...100).contains($0) ? Double($0) : nil }
        }
        var externalPowerConnected: Bool?
        // Compatibility for older tests/callers; this never meant "battery is charging".
        var charging: Bool? {
            get { externalPowerConnected }
            set { externalPowerConnected = newValue }
        }
        var temperatureC: Double?
    }

    private let sampler = nespat_sampler_create()
    private let samplerLock = NSLock()
    deinit { nespat_sampler_destroy(sampler) }
    private let totalMemory: UInt64
    private let pageSize: UInt64

    init() {
        var size = MemoryLayout<UInt64>.size
        var mem: UInt64 = 0
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        totalMemory = mem
        var page: UInt64 = 16384
        sysctlbyname("hw.pagesize", &page, &size, nil, 0)
        pageSize = page
    }

    func sample() -> Sample {
        var s = Sample()
        s.cpuPercent = cpuPercent()
        (s.memUsedBytes, s.memTotalBytes) = memory()
        readBattery(into: &s)
        s.temperatureC = TemperatureReader.chipTemperatureC()
        return s
    }

    // MARK: CPU (host_processor_info, разница замеров)

    private func cpuPercent() -> Double? {
        samplerLock.withLock {
            let percent = nespat_sampler_cpu(sampler)
            return percent.isFinite ? percent : nil
        }
    }

    /// Kernel ticks are wrapping unsigned 32-bit counters, despite the integer_t pointer type.
    static func cpuUsage(current: [UInt32], previous: [UInt32]?) -> Double? {
        guard let previous, previous.count == current.count, !current.isEmpty,
              current.count.isMultiple(of: Int(CPU_STATE_MAX)) else { return nil }
        var load: UInt64 = 0
        var idle: UInt64 = 0
        for index in current.indices {
            let delta = UInt64(current[index] &- previous[index])
            if index % Int(CPU_STATE_MAX) == Int(CPU_STATE_IDLE) { idle += delta }
            else { load += delta }
        }
        let total = load + idle
        return total == 0 ? 0 : Double(load) / Double(total) * 100
    }

    // MARK: Память (host_statistics64)

    private func memory() -> (used: UInt64, total: UInt64) {
        (nespat_used_memory(pageSize), totalMemory)
    }

    // MARK: Батарея (IOPowerSources)

    private func readBattery(into sample: inout Sample) {
        let battery = nespat_current_battery()
        sample.batteryPercentExact = battery.percent.isFinite ? battery.percent : nil
        sample.batteryPercent = sample.batteryPercentExact.map { Int($0.rounded()) }
        sample.externalPowerConnected = Self.flag(battery.external)
        sample.isCharging = Self.flag(battery.charging)
        sample.isFullyCharged = Self.flag(battery.charged)
        sample.batteryMinutes = battery.minutes > 0 ? Int(battery.minutes) : nil
    }
    private static func flag(_ value: Int8) -> Bool? {
        value < 0 ? nil : value == 1
    }
    static func powerSourceText(_ external: Bool?) -> String {
        switch external {
        case true: "внешнее питание"
        case false: "от батареи"
        case nil: "источник неизвестен"
        }
    }
    /// Missing/unknown/offline source is not proof of disconnected AC.
    static func parseBattery(_ desc: [String: Any]) -> (percent: Int?, externalPowerConnected: Bool?, exact: Double?) {
        let battery = nespat_parse_battery(desc as CFDictionary)
        let exact = battery.percent.isFinite ? battery.percent : nil
        return (exact.map { Int($0.rounded()) }, flag(battery.external), exact)
    }

}

// MARK: - Температура чипа (IOHID, частный API через dlsym)

enum TemperatureReader {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias ClientSetMatching = @convention(c) (OpaquePointer?, CFDictionary?) -> Int32
    private typealias ClientCopyServices = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias ServiceCopyEvent = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt64) -> OpaquePointer?
    private typealias EventGetFloat = @convention(c) (OpaquePointer?, UInt32) -> Double
    private typealias ServiceCopyProperty = @convention(c) (OpaquePointer?, CFString) -> OpaquePointer?
    private typealias ReleaseFn = @convention(c) (OpaquePointer?) -> Void

    private static let kEventTypeTemperature: UInt32 = 15
    private static let kFieldTemperatureLevel: UInt32 = kEventTypeTemperature << 16

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// Максимум выбранных PMU tdie channels, номинально °C; private mapping/calibration не гарантированы Apple.
    /// nil, если подходящие данные недоступны; это не доказательство безопасной температуры.
    static func chipTemperatureC() -> Double? {
        validCelsius(nespat_chip_temperature())
    }

    static func validCelsius(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 150 else { return nil }
        return value
    }

    // PMU naming is a private firmware convention, not an Apple public calibration contract.
    // Do not mix tcal/tdev/battery/surface readings with the selected tdie channels.
    static func chipTemperatureC(from sensors: [(name: String, value: Double)]) -> Double? {
        sensors.compactMap { sensor -> Double? in
            guard sensor.name.hasPrefix("PMU tdie") else { return nil }
            let suffix = sensor.name.dropFirst("PMU tdie".count)
            guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return validCelsius(sensor.value)
        }.max()
    }

    /// Отладка/приёмка: все температурные HID-датчики с именами и значениями.
    static func debugSensors() -> [(name: String, value: Double)] {
        sensors()
    }

    private static func sensors() -> [(name: String, value: Double)] {
        guard let create: ClientCreate = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching: ClientSetMatching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
              let copyServices: ClientCopyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
              let copyEvent: ServiceCopyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
              let getFloat: EventGetFloat = symbol("IOHIDEventGetFloatValue", as: EventGetFloat.self),
              let copyProperty: ServiceCopyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
              let release: ReleaseFn = symbol("CFRelease", as: ReleaseFn.self)
        else { return [] }

        guard let client = create(kCFAllocatorDefault) else { return [] }
        defer { release(client) }

        let matching = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 5
        ] as CFDictionary
        _ = setMatching(client, matching)

        guard let services = copyServices(client) else { return [] }
        defer { release(services) }
        let servicesArray = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(services)).takeUnretainedValue()

        var result: [(String, Double)] = []
        let count = CFArrayGetCount(servicesArray)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(servicesArray, i) else { continue }
            let service = OpaquePointer(raw)
            guard let nameRef = copyProperty(service, "Product" as CFString) else { continue }
            let nameObject = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(nameRef)).takeUnretainedValue()
            defer { release(nameRef) }
            guard CFGetTypeID(nameObject) == CFStringGetTypeID() else { continue }
            let name = nameObject as! String
            guard let event = copyEvent(service, kEventTypeTemperature, 0, 0) else { continue }
            defer { release(event) }
            let value = Double(getFloat(event, kFieldTemperatureLevel))
            result.append((name, value))
        }
        return result
    }
}
