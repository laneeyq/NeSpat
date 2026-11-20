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
    fn custom_input_preserves_supported_durations_and_rejects_malformed_values() {
        let parse = |text: &str| unsafe { nespat_parse_minutes(text.as_ptr(), text.len()) };
        for minutes in [1, 15, 35, 90, 165, 480, 481, 500, 1440, 10000] {
            let seconds = parse(&minutes.to_string());
            assert_eq!(seconds, minutes * 60);
            assert_eq!(nespat_deadline(50., seconds as f64), 50. + seconds as f64);
        }
        for text in [
            "",
            "0",
            "-1",
            "1.5",
            "hi",
            " 1",
            "+1",
            "9223372036854775807",
            "153722867280912931",
            &"9".repeat(10000),
        ] {
            assert_eq!(parse(text), 0);
        }
        assert!(nespat_deadline(f64::INFINITY, 60.).is_nan());
    }
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

#[no_mangle]
pub unsafe extern "C" fn nespat_parse_minutes(bytes: *const u8, len: usize) -> i64 {
    if bytes.is_null() || len == 0 || len > 19 {
        return 0;
    }
    let digits = std::slice::from_raw_parts(bytes, len);
    if !digits.iter().all(u8::is_ascii_digit) {
        return 0;
    }
    let minutes = digits.iter().try_fold(0i64, |acc, d| {
        acc.checked_mul(10)?.checked_add(i64::from(*d - b'0'))
    });
    match minutes {
        Some(value) => nespat_minutes_to_seconds(value),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn nespat_deadline(start: f64, seconds: f64) -> f64 {
    let limit = (1u64 << 53) as f64;
    let end = start + seconds;
    if !seconds.is_finite()
        || seconds <= 0.0
        || seconds > limit
        || !start.is_finite()
        || !end.is_finite()
        || end.abs() > limit
        || end <= start
    {
        return f64::NAN;
    }
    let ulp = |v: f64| v.abs().next_up() - v.abs();
    if ((end - start) - seconds).abs() > ulp(start).max(ulp(end)) {
        return f64::NAN;
    }
    end
}

#[cfg(test)]
mod regression {
    use super::*;
    #[test]
    fn exact_thresholds_and_invalid_readings_are_not_based_on_display_rounding() {
        for start in [true, false] {
            for ac in [0, 1] {
                for (temp, expected) in [
                    (0., Assessment::Unknown),
                    (94.999, Assessment::Clear),
                    (95., Assessment::Hot),
                    (149.99, Assessment::Hot),
                    (150., Assessment::Unknown),
                    (f64::NAN, Assessment::Unknown),
                ] {
                    assert_eq!(classify(90., ac, temp, 0, start), expected);
                }
                for n in [f64::NAN, -0.01, 100.01, f64::INFINITY] {
                    assert_eq!(classify(n, ac, 30., 0, start), Assessment::Unknown);
                }
            }
        }
        for (b, expected_start, expected_active) in [
            (10., Assessment::LowAtStart, Assessment::LowDuringSession),
            (10.01, Assessment::LowAtStart, Assessment::Clear),
            (14.99, Assessment::LowAtStart, Assessment::Clear),
            (15., Assessment::Clear, Assessment::Clear),
        ] {
            assert_eq!(classify(b, 0, 35., 0, true), expected_start);
            assert_eq!(classify(b, 0, 35., 0, false), expected_active);
            assert_eq!(classify(b, 1, 35., 0, false), Assessment::Clear);
        }
        assert_eq!(classify(5., -1, 35., 0, false), Assessment::Unknown);
        assert_eq!(classify(99., 1, 35., -1, false), Assessment::Unknown);
    }
}
