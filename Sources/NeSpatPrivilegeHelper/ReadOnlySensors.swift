import NeSpatNative

struct StatsSampler: Sendable {
    struct Sample {
        let batteryLevel: Double?
        let externalPowerConnected: Bool?
        let temperatureC: Double?
    }

    func sample() -> Sample {
        let battery = nespat_current_battery()
        let temperature = nespat_chip_temperature()
        return Sample(batteryLevel: battery.percent.isFinite ? battery.percent : nil,
                      externalPowerConnected: battery.external < 0 ? nil : battery.external == 1,
                      temperatureC: temperature.isFinite ? temperature : nil)
    }
}
