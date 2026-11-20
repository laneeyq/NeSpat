// Values cross the ABI as numbers; the reason text stays in the presentation layer.
#[derive(Clone, Copy, PartialEq, Debug)]
#[repr(u8)]
pub enum Assessment {
    Clear,
    Unknown,
    Thermal,
    Hot,
    LowAtStart,
    LowDuringSession,
}
fn classify(battery: f64, ac: i8, temp: f64, thermal: i8, starting: bool) -> Assessment {
    let battery_valid = (0.0..=100.0).contains(&battery);
    let temp_valid = temp > 0.0 && temp < 150.0;
    if starting && ac == 0 && battery_valid && battery < 15.0 {
        return Assessment::LowAtStart;
    }
    if thermal == 1 {
        return Assessment::Thermal;
    }
    if temp_valid && temp >= 95.0 {
        return Assessment::Hot;
    }
    if ac == 0 && battery_valid && battery <= 10.0 {
        return Assessment::LowDuringSession;
    }
    if !battery_valid || !temp_valid || !(0..=1).contains(&ac) || !(0..=1).contains(&thermal) {
        return Assessment::Unknown;
    }
    Assessment::Clear
}
#[no_mangle]
pub extern "C" fn nespat_assess(
    battery: f64,
    ac: i8,
    temp: f64,
    thermal: i8,
    starting: bool,
) -> u8 {
    classify(battery, ac, temp, thermal, starting) as u8
}
#[no_mangle]
pub extern "C" fn nespat_minutes_to_seconds(minutes: i64) -> i64 {
    minutes
        .checked_mul(60)
        .filter(|v| *v > 0 && *v <= 1i64 << 53)
        .unwrap_or(0)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn different_start_and_emergency_thresholds() {
        assert_eq!(classify(14.9, 0, 40.0, 0, true), Assessment::LowAtStart);
        assert_eq!(classify(14.9, 0, 40.0, 0, false), Assessment::Clear);
        assert_eq!(
            classify(10.0, 0, 40.0, 0, false),
            Assessment::LowDuringSession
        );
        assert_eq!(classify(8.0, 1, 40.0, 0, false), Assessment::Clear);
    }
    #[test]
    fn incomplete_readings_do_not_override_confirmed_danger() {
        assert_eq!(classify(f64::NAN, -1, 95.0, -1, false), Assessment::Hot);
        assert_eq!(
            classify(99.0, 1, f64::INFINITY, 0, false),
            Assessment::Unknown
        );
        assert_eq!(classify(-1.0, -1, -1.0, 1, false), Assessment::Thermal);
    }
    #[test]
    fn duration_cannot_overflow_or_lose_precision() {
        for m in [0, -1, i64::MAX, (1i64 << 53) / 60 + 1] {
            assert_eq!(nespat_minutes_to_seconds(m), 0);
        }
        assert_eq!(nespat_minutes_to_seconds(100_000), 6_000_000);
    }
}
