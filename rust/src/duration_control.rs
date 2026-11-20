use objc2::{rc::Retained, runtime::AnyObject, sel, MainThreadMarker};
use objc2_app_kit::{
    NSControlSize, NSFont, NSFontAttributeName, NSLayoutConstraintOrientation,
    NSLayoutPriorityDefaultLow, NSSegmentDistribution, NSSegmentSwitchTracking, NSSegmentedControl,
    NSStringDrawing,
};
use objc2_foundation::{NSArray, NSDictionary, NSString};
use std::{ffi::c_void, ptr};

const PRESETS: [(&str, i64); 4] = [("Без лимита", 0), ("1 ч", 60), ("3 ч", 180), ("8 ч", 480)];
// AppKit keeps the target weak. The SwiftUI host retains its coordinator for
// the control's lifetime and takes ownership of the returned +1 control.
#[no_mangle]
pub unsafe extern "C" fn nespat_presets_create(target: *const AnyObject) -> *mut c_void {
    let (Some(mtm), Some(target)) = (MainThreadMarker::new(), target.as_ref()) else {
        return ptr::null_mut();
    };
    let labels = PRESETS.map(|(name, _)| NSString::from_str(name));
    let control = NSSegmentedControl::segmentedControlWithLabels_trackingMode_target_action(
        &NSArray::from_retained_slice(&labels),
        NSSegmentSwitchTracking::SelectOne,
        Some(target),
        Some(sel!(pick:)),
        mtm,
    );
    control.setControlSize(NSControlSize::Small);
    let font = NSFont::systemFontOfSize(NSFont::smallSystemFontSize());
    control.setFont(Some(&font));
    control.setSegmentDistribution(NSSegmentDistribution::Fill);
    let attrs = NSDictionary::from_slices(&[NSFontAttributeName], &[font.as_ref() as &AnyObject]);
    let width = labels[0].sizeWithAttributes(Some(&attrs)).width.ceil() + 12.0;
    control.setWidth_forSegment(width, 0);
    control.setContentHuggingPriority_forOrientation(
        NSLayoutPriorityDefaultLow,
        NSLayoutConstraintOrientation::Horizontal,
    );
    Retained::into_raw(control).cast()
}
#[no_mangle]
pub unsafe extern "C" fn nespat_presets_update(
    control: *const NSSegmentedControl,
    minutes: i64,
    enabled: bool,
) {
    if let Some(control) = control.as_ref() {
        control.setSelectedSegment(
            PRESETS
                .iter()
                .position(|(_, n)| *n == minutes)
                .map_or(-1, |i| i as isize),
        );
        control.setEnabled(enabled);
    }
}
#[no_mangle]
pub extern "C" fn nespat_preset_minutes(index: isize) -> i64 {
    usize::try_from(index)
        .ok()
        .and_then(|i| PRESETS.get(i))
        .map_or(-1, |(_, value)| *value)
}
