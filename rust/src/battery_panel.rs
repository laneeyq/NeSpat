use crate::BatteryDetails;
use objc2::{rc::Retained, MainThreadMarker};
use objc2_app_kit::{
    NSColor, NSFont, NSGridCellPlacement, NSGridRowAlignment, NSGridView, NSTextField, NSView,
};
use objc2_foundation::{NSArray, NSString};
use std::{ffi::c_void, ptr};

const LABELS: [&str; 5] = [
    "Циклы",
    "Текущий заряд",
    "Полная ёмкость",
    "Проектная ёмкость",
    "От проектной",
];

fn values(details: &BatteryDetails) -> [String; 5] {
    let format = |n: i64, unit: &str| {
        if n < 0 {
            "—".into()
        } else {
            format!("{n}{unit}")
        }
    };
    let health = if details.design > 0 && details.full >= 0 {
        let percent = (details.full as f64 / details.design as f64 * 100.0).round();
        format!("{percent:.0}%")
    } else {
        "—".into()
    };
    [
        format(details.cycles, ""),
        format(details.remaining, " мА·ч"),
        format(details.full, " мА·ч"),
        format(details.design, " мА·ч"),
        health,
    ]
}

#[no_mangle]
pub extern "C" fn nespat_battery_grid_create(details: BatteryDetails) -> *mut c_void {
    let Some(mtm) = MainThreadMarker::new() else {
        return ptr::null_mut();
    };
    let label_font = NSFont::systemFontOfSize(10.0);
    let value_font = NSFont::monospacedDigitSystemFontOfSize_weight(10.0, 0.0);
    let rows: Vec<_> = LABELS
        .iter()
        .zip(values(&details))
        .map(|(label, value)| {
            let field = |text: &str, font: &NSFont| {
                let field = NSTextField::labelWithString(&NSString::from_str(text), mtm);
                field.setFont(Some(font));
                field.setTextColor(Some(&NSColor::secondaryLabelColor()));
                field.into_super().into_super()
            };
            NSArray::<NSView>::from_retained_slice(&[
                field(label, &label_font),
                field(&value, &value_font),
            ])
        })
        .collect();
    let grid = NSGridView::gridViewWithViews(&NSArray::from_retained_slice(&rows), mtm);
    grid.setColumnSpacing(12.0);
    grid.setRowSpacing(3.0);
    grid.setRowAlignment(NSGridRowAlignment::FirstBaseline);
    grid.setXPlacement(NSGridCellPlacement::Leading);
    Retained::into_raw(grid).cast()
}

#[no_mangle]
pub unsafe extern "C" fn nespat_battery_grid_update(
    grid: *const NSGridView,
    details: BatteryDetails,
) {
    let Some(grid) = grid.as_ref() else {
        return;
    };
    for (row, text) in values(&details).iter().enumerate() {
        if let Some(field) = grid
            .cellAtColumnIndex_rowIndex(1, row as isize)
            .contentView()
            .and_then(|v| v.downcast::<NSTextField>().ok())
        {
            let value = NSString::from_str(text);
            if field.stringValue() != value {
                field.setStringValue(&value);
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cycle_count_and_capacity_keep_distinct_units() {
        let d = BatteryDetails {
            cycles: 0,
            design: 4000,
            full: 3800,
            remaining: 1500,
        };
        assert_eq!(
            values(&d),
            ["0", "1500 мА·ч", "3800 мА·ч", "4000 мА·ч", "95%"]
        );
        let unknown = BatteryDetails {
            cycles: -1,
            design: -1,
            full: -1,
            remaining: -1,
        };
        assert_eq!(values(&unknown), ["—"; 5]);
    }
}
