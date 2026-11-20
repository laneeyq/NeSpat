use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};

fn text(s: String) -> CFStringRef {
    std::mem::ManuallyDrop::new(CFString::new(&s)).as_concrete_TypeRef()
}
#[no_mangle]
pub extern "C" fn nespat_format_percent(v: f64) -> CFStringRef {
    text(if v.is_finite() {
        format!("{}%", v.round() as i64)
    } else {
        "—".into()
    })
}
#[no_mangle]
pub extern "C" fn nespat_format_memory(bytes: u64) -> CFStringRef {
    let gib = bytes as f64 / 1_073_741_824.0;
    text(if gib < 10.0 {
        format!("{gib:.1} ГБ")
    } else {
        format!("{gib:.0} ГБ")
    })
}
pub(crate) fn duration(seconds: f64) -> String {
    if !seconds.is_finite() || seconds > (1u64 << 53) as f64 {
        return "—".into();
    }
    let total = seconds.max(0.0).ceil() as u64;
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60);
    if h > 0 {
        format!("{h} ч {m:02} мин {s:02} с")
    } else if m > 0 {
        format!("{m} мин {s:02} с")
    } else {
        format!("{s} с")
    }
}
#[no_mangle]
pub extern "C" fn nespat_format_duration(seconds: f64) -> CFStringRef {
    text(duration(seconds))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn countdown_crosses_minute_and_hour_at_display_boundaries() {
        assert_eq!(duration(0.01), "1 с");
        assert_eq!(duration(59.01), "1 мин 00 с");
        assert_eq!(duration(3599.8), "1 ч 00 мин 00 с");
        assert_eq!(duration(-1.0), "0 с");
        assert_eq!(duration(f64::NAN), "—");
    }
}
