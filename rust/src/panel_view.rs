use crate::{
    duration_control::*, panel_meter::NeSpatMeter, panel_readings::Readings, panel_worker::Report,
};
use objc2::{
    define_class, rc::Retained, runtime::AnyObject, sel, MainThreadMarker, MainThreadOnly,
};
use objc2_app_kit::*;
use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
use std::cell::Cell;

define_class!(
    #[unsafe(super = NSView)]
    #[thread_kind = MainThreadOnly]
    struct NeSpatPanelContent;
    impl NeSpatPanelContent { #[unsafe(method(isFlipped))] fn flipped(&self)->bool{true} }
);

pub(crate) struct Form {
    pub controller: Retained<NSViewController>,
    root: Retained<NSView>,
    heading: Retained<NSTextField>,
    pub toggle: Retained<NSSwitch>,
    summary: Retained<NSTextField>,
    error: Retained<NSTextField>,
    pub recover: Retained<NSButton>,
    rules: [Retained<NSBox>; 3],
    duration: Retained<NSTextField>,
    pub presets: Retained<NSSegmentedControl>,
    custom: Retained<NSTextField>,
    pub input: Retained<NSTextField>,
    apply: Retained<NSButton>,
    hint: Retained<NSTextField>,
    labels: [Retained<NSTextField>; 4],
    values: [Retained<NSTextField>; 4],
    meters: [Retained<NeSpatMeter>; 4],
    details_button: Retained<NSButton>,
    details: Retained<NSGridView>,
    battery_note: Retained<NSTextField>,
    pub automatic: Retained<NSButton>,
    pub login: Retained<NSButton>,
    quit: Retained<NSButton>,
    pub updates: Retained<NSButton>,
    pub check: Retained<NSButton>,
    message: Retained<NSTextField>,
    pub expanded: Cell<bool>,
}
fn ns(s: &str) -> Retained<NSString> {
    NSString::from_str(s)
}
fn place(view: &NSView, x: f64, y: f64, w: f64, h: f64) {
    let r = NSRect::new(NSPoint::new(x, y), NSSize::new(w, h));
    if view.frame() != r {
        view.setFrame(r);
    }
}
fn label(
    m: MainThreadMarker,
    s: &str,
    size: f64,
    weight: f64,
    secondary: bool,
) -> Retained<NSTextField> {
    let f = NSTextField::labelWithString(&ns(s), m);
    f.setFont(Some(&NSFont::systemFontOfSize_weight(size, weight)));
    if secondary {
        f.setTextColor(Some(&NSColor::secondaryLabelColor()));
    }
    f
}
fn set(f: &NSTextField, s: &str) {
    let value = ns(s);
    if f.stringValue() != value {
        f.setStringValue(&value);
    }
}
pub(crate) fn busy(report: &Report) -> bool {
    report.desired
        || matches!(
            report.status.phase,
            crate::driver::Phase::Prepared
                | crate::driver::Phase::Closed
                | crate::driver::Phase::Recovering
        )
}
impl Form {
    pub(crate) fn build(m: MainThreadMarker, target: &AnyObject, draft: &str) -> Self {
        unsafe {
            let root: Retained<NeSpatPanelContent> =
                objc2::msg_send![NeSpatPanelContent::alloc(m),initWithFrame:NSRect::ZERO];
            let controller = NSViewController::new(m);
            controller.setView(&root);
            let btn = |title: &str, tag: isize, checkbox: bool, border: bool| {
                let b = if checkbox {
                    NSButton::checkboxWithTitle_target_action(
                        &ns(title),
                        Some(target),
                        Some(sel!(action:)),
                        m,
                    )
                } else {
                    NSButton::buttonWithTitle_target_action(
                        &ns(title),
                        Some(target),
                        Some(sel!(action:)),
                        m,
                    )
                };
                b.setTag(tag);
                b.setControlSize(NSControlSize::Small);
                if !border && !checkbox {
                    b.setBordered(false);
                }
                root.addSubview(&b);
                b
            };
            let text = |title: &str, size: f64, weight: f64, secondary: bool| {
                let f = label(m, title, size, weight, secondary);
                root.addSubview(&f);
                f
            };
            let heading = text("Не спать", 13., 0.3, false);
            let toggle = NSSwitch::new(m);
            toggle.setControlSize(NSControlSize::Small);
            toggle.setTag(1);
            toggle.setTarget(Some(target));
            toggle.setAction(Some(sel!(action:)));
            root.addSubview(&toggle);
            let summary = text("", 11., 0., true);
            let error = text("", 11., 0., false);
            error.setTextColor(Some(&NSColor::systemRedColor()));
            error.setMaximumNumberOfLines(0);
            error.setUsesSingleLineMode(false);
            let recover = btn("", 2, false, false);
            let rules = std::array::from_fn(|_| {
                let b = NSBox::new(m);
                b.setBoxType(NSBoxType::Separator);
                root.addSubview(&b);
                b
            });
            let duration = text("Длительность", 11., 0., true);
            let presets: Retained<NSSegmentedControl> =
                Retained::from_raw(nespat_presets_create(target).cast()).unwrap();
            root.addSubview(&presets);
            let custom = text("Своя длительность, мин", 11., 0., true);
            let input = NSTextField::new(m);
            input.setStringValue(&ns(draft));
            input.setControlSize(NSControlSize::Small);
            input.setTag(3);
            input.setTarget(Some(target));
            input.setAction(Some(sel!(action:)));
            root.addSubview(&input);
            let apply = btn("Применить", 3, false, true);
            let hint = text("", 11., 0., true);
            let labels =
                ["Температура", "Процессор", "Память", "Батарея ⌄"].map(|s| text(s, 13., 0., true));
            let values = std::array::from_fn(|_| {
                let f = text("", 13., 0.23, false);
                f.setAlignment(NSTextAlignment::Right);
                f
            });
            let meters = std::array::from_fn(|i| {
                let meter = NeSpatMeter::build(m, i == 3);
                root.addSubview(&meter);
                meter
            });
            let details_button = btn("", 4, false, false);
            details_button.setTransparent(true);
            details_button.setToolTip(Some(&ns("Показать циклы и ёмкость аккумулятора")));
            let details: Retained<NSGridView> = Retained::from_raw(
                crate::battery_panel::nespat_battery_grid_create(crate::BatteryDetails {
                    cycles: -1,
                    design: -1,
                    full: -1,
                    remaining: -1,
                })
                .cast(),
            )
            .unwrap();
            root.addSubview(&details);
            let battery_note = text("", 11., 0., true);
            let automatic = btn("Автоматический режим", 6, true, false);
            let login = btn("Запускать при входе", 7, true, false);
            let quit = btn("Выход", 8, false, false);
            quit.setKeyEquivalent(&ns("q"));
            let updates = btn("Автообновления", 9, true, false);
            let check = btn("Проверить", 10, false, true);
            let message = text("", 11., 0., true);
            message.setMaximumNumberOfLines(0);
            message.setUsesSingleLineMode(false);
            Self {
                root: root.into_super(),
                controller,
                heading,
                toggle,
                summary,
                error,
                recover,
                rules,
                duration,
                presets,
                custom,
                input,
                apply,
                hint,
                labels,
                values,
                meters,
                details_button,
                details,
                battery_note,
                automatic,
                login,
                quit,
                updates,
                check,
                message,
                expanded: Cell::new(false),
            }
        }
    }
    pub(crate) fn render(
        &self,
        r: &Readings,
        report: &Report,
        minutes: i64,
        hint: &str,
        message: &str,
        now: f64,
    ) {
        let active = r.active(&report.status);
        let busy = busy(report);
        self.toggle.setState(active as isize);
        self.toggle
            .setEnabled(active || (!busy && r.power == 0 && r.permitted && r.helper && r.watchdog));
        set(
            &self.summary,
            &r.summary(&report.status, report.desired, now),
        );
        let color = if active {
            NSColor::systemGreenColor()
        } else {
            NSColor::secondaryLabelColor()
        };
        self.summary.setTextColor(Some(&color));
        let header_y = 6.;
        place(&self.heading, 12., header_y, 210., 19.);
        place(&self.toggle, 246., header_y - 1., 36., 19.);
        place(&self.summary, 12., header_y + 22., 276., 17.);
        let mut y = header_y + 38.;
        let extra = |f: &NSTextField, s: &str, y: &mut f64| {
            f.setHidden(s.is_empty());
            if s.is_empty() {
                return;
            }
            set(f, s);
            let h = if let Some(cell) = f.cell() {
                unsafe {
                    cell.cellSizeForBounds(NSRect::new(NSPoint::ZERO, NSSize::new(272., 1000.)))
                        .height
                        .ceil()
                        .max(16.)
                }
            } else {
                16.
            };
            place(f, 12., *y, 276., h);
            *y += h + 3.;
        };
        extra(
            &self.error,
            report.status.error.as_deref().unwrap_or(""),
            &mut y,
        );
        self.recover.setHidden(r.power != 1 && (!busy || active));
        if !self.recover.isHidden() {
            self.recover.setTitle(&ns(if r.power == 1 {
                "Аварийное восстановление…"
            } else {
                "Отменить подготовку"
            }));
            place(&self.recover, 12., y, 276., 20.);
            y += 22.;
        }
        let rule = |index: usize, y: &mut f64| {
            place(&self.rules[index], 14., *y, 272., 6.);
            *y += 12.;
        };
        rule(0, &mut y);
        place(&self.duration, 12., y, 276., 16.);
        y += 18.;
        place(&self.presets, 13., y, 274., 24.);
        y += 29.;
        unsafe {
            nespat_presets_update(&*self.presets, minutes, !busy);
        }
        place(&self.custom, 12., y, 276., 17.);
        y += 19.;
        place(&self.input, 14., y, 179., 22.);
        place(&self.apply, 199., y - 1., 88., 24.);
        self.input.setEnabled(!busy);
        self.apply.setEnabled(!busy);
        y += 26.;
        extra(&self.hint, hint, &mut y);
        rule(1, &mut y);
        set(
            &self.labels[3],
            if self.expanded.get() {
                "Батарея ⌃"
            } else {
                "Батарея ⌄"
            },
        );
        for i in 0..4 {
            set(&self.values[i], &r.values[i]);
            place(&self.labels[i], 12., y, 110., 18.);
            place(&self.values[i], 104., y, 184., 18.);
            place(&self.meters[i], 14., y + 20., 272., 5.);
            self.meters[i].update(r.fractions[i]);
            if i == 3 {
                place(&self.details_button, 14., y, 272., 26.);
            }
            y += if i == 3 { 29. } else { 34. };
        }
        self.details.setHidden(!self.expanded.get());
        if self.expanded.get() {
            let height = self.details.fittingSize().height.max(70.);
            place(&self.details, 14., y, 272., height);
            y += height + 5.;
        }
        extra(&self.battery_note, &r.note, &mut y);
        rule(2, &mut y);
        place(&self.automatic, 12., y, 210., 18.);
        y += 22.;
        place(&self.login, 12., y, 192., 18.);
        place(&self.quit, 235., y, 52., 18.);
        y += 24.;
        place(&self.updates, 12., y, 175., 18.);
        place(&self.check, 203., y - 2., 85., 22.);
        y += 23.;
        extra(&self.message, message, &mut y);
        let size = NSSize::new(300., y + 3.);
        if self.controller.preferredContentSize() != size {
            self.root.setFrameSize(size);
            self.controller.setPreferredContentSize(size);
        }
    }
    #[cfg(debug_assertions)]
    pub(crate) fn battery_screen_y(&self) -> Option<f64> {
        let window = self.root.window()?;
        Some(
            window
                .convertRectToScreen(self.root.convertRect_toView(self.labels[3].frame(), None))
                .origin
                .y,
        )
    }
    pub(crate) fn with_anchored_resize(
        &self,
        item: *const std::ffi::c_void,
        render: impl FnOnce(),
    ) {
        let before = self.controller.preferredContentSize();
        render();
        let after = self.controller.preferredContentSize();
        if before != after {
            unsafe {
                crate::status_item::resize(item, after);
            }
        }
    }
    pub(crate) fn refresh_details(&self) {
        unsafe {
            crate::battery_panel::nespat_battery_grid_update(
                &*self.details,
                crate::nespat_battery_details(),
            );
        }
    }
}
