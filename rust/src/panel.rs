use crate::{
    panel_preferences::*,
    panel_readings::Monitor,
    panel_view::{busy, Form},
    panel_worker::Worker,
};
use objc2::{
    define_class, msg_send, rc::Retained, sel, DefinedClass, MainThreadMarker, MainThreadOnly,
};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSControl, NSSegmentedControl, NSWorkspace,
};
use objc2_foundation::{
    NSBundle, NSFileManager, NSObject, NSSearchPathDirectory, NSSearchPathDomainMask, NSString,
    NSTimer, NSURL,
};
use std::{
    cell::{Cell, OnceCell, RefCell},
    ffi::{c_void, CString},
    path::PathBuf,
    sync::mpsc::{channel, Receiver, TryRecvError},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
type Asset = Option<(String, PathBuf)>;
struct Window {
    form: OnceCell<Form>,
    status_item: Cell<*mut c_void>,
    driver: Worker,
    sensors: Monitor,
    input_error: RefCell<String>,
    notice: RefCell<String>,
    login_error: Cell<bool>,
    update: RefCell<Option<(bool, Receiver<Result<Asset, ()>>)>>,
    package: RefCell<Option<PathBuf>>,
    next: Cell<Instant>,
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(f64::NAN, |v| v.as_secs_f64() - 978307200.)
}
fn package_info() -> Option<(String, PathBuf)> {
    let version = NSBundle::mainBundle()
        .objectForInfoDictionaryKey(&ns("CFBundleShortVersionString"))?
        .downcast::<NSString>()
        .ok()?
        .to_string();
    let folder = NSFileManager::defaultManager()
        .URLsForDirectory_inDomains(
            NSSearchPathDirectory::CachesDirectory,
            NSSearchPathDomainMask::UserDomainMask,
        )
        .firstObject()?
        .path()?
        .to_string();
    Some((
        version,
        PathBuf::from(folder).join("local.nespat.app/Updates"),
    ))
}
fn open(path: &std::path::Path) -> bool {
    NSWorkspace::sharedWorkspace().openURL(&NSURL::fileURLWithPath(&ns(&path.to_string_lossy())))
}
impl Window {
    fn check(&self, manual: bool) {
        if self.package.borrow().is_some() || self.update.borrow().is_some() {
            return;
        }
        let info = package_info();
        if manual {
            *self.notice.borrow_mut() = "Проверяем обновления…".into();
        }
        let (tx, rx) = channel();
        *self.update.borrow_mut() = Some((manual, rx));
        std::thread::spawn(move || {
            let result = info.ok_or(()).and_then(|(version, folder)| {
                crate::updates::check(&version, &folder).map_err(|_| ())
            });
            let _ = tx.send(result);
        });
    }
    fn refresh(&self, m: MainThreadMarker) {
        let Some(form) = self.form.get() else {
            return;
        };
        let r = self.sensors.read();
        let report = self.driver.report();
        if report.quit {
            NSApplication::sharedApplication(m).terminate(None);
            return;
        }
        if Instant::now() >= self.next.get() {
            self.next.set(Instant::now() + Duration::from_secs(86400));
            if flag(UPDATES, true) {
                self.check(false);
            }
        }
        let answer = self
            .update
            .borrow()
            .as_ref()
            .and_then(|(manual, rx)| match rx.try_recv() {
                Ok(v) => Some((*manual, v)),
                Err(TryRecvError::Disconnected) => Some((*manual, Err(()))),
                _ => None,
            });
        if let Some((manual, result)) = answer {
            self.update.borrow_mut().take();
            match result {
                Ok(Some((version, path))) => {
                    *self.package.borrow_mut() = Some(path);
                    *self.notice.borrow_mut() = format!("Готово обновление {version}");
                }
                Ok(None) if manual => {
                    *self.notice.borrow_mut() = "Установлена актуальная версия".into()
                }
                Err(()) if manual => {
                    *self.notice.borrow_mut() =
                        "Не удалось проверить выпуск на GitHub. Повторите позже.".into()
                }
                _ => {}
            }
        }
        let has_update = self.package.borrow().is_some();
        form.check.setTitle(&ns(if has_update {
            "Установить"
        } else {
            "Проверить"
        }));
        form.check
            .setEnabled(!has_update || (!busy(&report) && r.power == 0));
        form.automatic.setState(flag(AUTO, false) as isize);
        form.updates.setState(flag(UPDATES, true) as isize);
        let minutes = choice();
        let hint = if !self.input_error.borrow().is_empty() {
            self.input_error.borrow().clone()
        } else if minutes == -1 {
            format!("Выбрано: {} мин", custom())
        } else {
            String::new()
        };
        let mut message = self.notice.borrow().clone();
        if self.login_error.get() {
            if !message.is_empty() {
                message.push('\n');
            }
            message.push_str("Проверьте объекты входа в системных настройках.");
        }
        form.with_anchored_resize(self.status_item.get(), || {
            form.render(&r, &report, minutes, &hint, &message, now());
        });
        if let Ok(title) = CString::new(r.title(&report.status)) {
            unsafe {
                crate::status_item::nespat_status_title(self.status_item.get(), title.as_ptr());
            }
        }
    }
}
define_class!(
    #[unsafe(super=NSObject)]
    #[thread_kind=MainThreadOnly]
    #[ivars=Window]
    struct NeSpatPanelActions;
    impl NeSpatPanelActions {
        #[unsafe(method(tick:))]
        fn tick(&self,_timer:&NSTimer){self.ivars().refresh(self.mtm());}
        #[unsafe(method(pick:))]
        fn pick(&self,s:&NSSegmentedControl){let w=self.ivars();if busy(&w.driver.report()){return;}let n=crate::duration_control::nespat_preset_minutes(s.selectedSegment());if n>=0{set_choice(n);w.input_error.borrow_mut().clear();}w.refresh(self.mtm());}
        #[unsafe(method(action:))]
        fn action(&self,s:&NSControl){
            let w=self.ivars();let Some(f)=w.form.get()else{return;};let r=w.sensors.read();let report=w.driver.report();
            match s.tag(){
                1=>{let on=f.toggle.state()!=0;if !on{set_flag(AUTO,false);} w.driver.intent(on);}
                2=>{set_flag(AUTO,false);if r.power==1{w.driver.recover();}else{w.driver.intent(false);}}
                3 if !busy(&report)=>{let d=f.input.stringValue().to_string();let seconds=unsafe{crate::policy::nespat_parse_minutes(d.as_ptr(),d.len())};if crate::policy::nespat_deadline(now(),seconds as f64).is_finite(){set_custom(seconds/60);f.input.setStringValue(&ns(&custom()));w.input_error.borrow_mut().clear();}else{*w.input_error.borrow_mut()="Введите положительное целое число минут, представимое без переполнения и потери точности срока.".into();}}
                4=>{f.expanded.set(!f.expanded.get());if f.expanded.get(){f.refresh_details();}}
                6=>{let on=f.automatic.state()!=0;set_flag(AUTO,on);w.driver.intent(on);}
                7=>{let (local,installed)=login_context();let ok=crate::login::nespat_login_set(f.login.state()!=0,local,installed);w.login_error.set(!ok);f.login.setState(crate::login::nespat_login_enabled(local,installed) as isize);}
                8=>w.driver.quit(),
                9=>set_flag(UPDATES,f.updates.state()!=0),
                10=>{if let Some(path)=w.package.borrow().as_ref(){if !busy(&report)&&crate::observation::nespat_sleep_disabled()==0&&open(path){NSApplication::sharedApplication(self.mtm()).terminate(None);}}else{w.check(true);}}
                _=>{}
            }
            w.refresh(self.mtm());
        }
    }
);
pub fn run(m: MainThreadMarker) {
    let app = NSApplication::sharedApplication(m);
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    migrate();
    let w = Window {
        form: OnceCell::new(),
        status_item: Cell::new(std::ptr::null_mut()),
        driver: Worker::start(flag(AUTO, false)),
        sensors: Monitor::new(),
        input_error: Default::default(),
        notice: Default::default(),
        login_error: Cell::new(false),
        update: Default::default(),
        package: Default::default(),
        next: Cell::new(Instant::now()),
    };
    let target = NeSpatPanelActions::alloc(m).set_ivars(w);
    let target: Retained<NeSpatPanelActions> = unsafe { msg_send![super(target), init] };
    let form = Form::build(m, &target, &custom());
    let (local, installed) = login_context();
    form.login
        .setState(crate::login::nespat_login_enabled(local, installed) as isize);
    let w = target.ivars();
    w.status_item
        .set(unsafe { crate::status_item::nespat_status_create(&*form.controller) });
    let _ = w.form.set(form);
    w.refresh(m);
    let timer = unsafe {
        NSTimer::scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
            1.,
            &target,
            sel!(tick:),
            None,
            true,
        )
    };
    app.run();
    timer.invalidate();
    unsafe {
        crate::status_item::nespat_status_destroy(w.status_item.replace(std::ptr::null_mut()));
    }
}

#[cfg(debug_assertions)]
pub fn preview(m: MainThreadMarker, path: &std::path::Path) -> Option<()> {
    use crate::{panel_readings::Readings, panel_worker::Report};
    use objc2_app_kit::{
        NSAppearance, NSAppearanceCustomization, NSBackingStoreType, NSBitmapImageFileType,
        NSWindow, NSWindowStyleMask,
    };
    use objc2_foundation::{NSDictionary, NSPoint, NSRect, NSSize};
    let app = NSApplication::sharedApplication(m);
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    app.finishLaunching();
    let target = NSObject::new();
    let form = Form::build(m, &target, "30");
    let r = Readings {
        helper: true,
        watchdog: true,
        permitted: true,
        power: 0,
        values: ["32 °C", "13%", "7.5 ГБ из 15 ГБ", "80% · внешнее питание"].map(str::to_owned),
        fractions: [0.12, 0.13, 0.5, 0.8],
        ..Default::default()
    };
    let mut report = Report::default();
    form.render(&r, &report, 60, "", "", 0.);
    let expected = form.controller.preferredContentSize();
    // Exercise the actual popover under a menu-bar item after AppKit lays it out.
    unsafe {
        let item = crate::status_item::nespat_status_create(&*form.controller);
        let visible = objc2_app_kit::NSScreen::mainScreen(m)?.visibleFrame();
        let anchor = NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(m),
            NSRect::new(
                NSPoint::new(
                    visible.origin.x + visible.size.width / 2.,
                    visible.origin.y + visible.size.height - 30.,
                ),
                NSSize::new(42., 20.),
            ),
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        );
        anchor.orderFrontRegardless();
        crate::status_item::preview_open(item, &*anchor.contentView()?)?;
        let settle = || {
            objc2_foundation::NSRunLoop::mainRunLoop()
                .runUntilDate(&objc2_foundation::NSDate::dateWithTimeIntervalSinceNow(0.5));
        };
        settle();
        let window = form.controller.view().window()?;
        let before = window.frame();
        let header_gap = || -> Option<f64> {
            let view = form.controller.view();
            let window = view.window()?;
            let header =
                window.convertRectToScreen(view.convertRect_toView(form.toggle.frame(), None));
            Some(
                window.frame().origin.y + window.frame().size.height
                    - header.origin.y
                    - header.size.height,
            )
        };
        let initial_gap = header_gap()?;
        println!("Popover window top to switch: {initial_gap:.1} pt");
        if !(5.0..=20.0).contains(&initial_gap) {
            return None;
        }
        let battery_before = form.battery_screen_y()?;
        for expanded in [true, false] {
            form.expanded.set(expanded);
            form.with_anchored_resize(item, || form.render(&r, &report, 60, "", "", 0.));
            settle();
            let rect = form.controller.view().window()?.frame();
            let top_delta = rect.origin.y + rect.size.height - before.origin.y - before.size.height;
            let growth = rect.size.height - before.size.height;
            println!("Battery expanded={expanded}: top offset {top_delta:.1} pt, height change {growth:.1} pt");
            if (header_gap()? - initial_gap).abs() > 1.
                || (form.battery_screen_y()? - battery_before).abs() > 1.
                || top_delta.abs() > 1.
                || (expanded && growth < 65.)
                || (!expanded && growth.abs() > 1.)
            {
                return None;
            }
        }
        for message in [
            "Восстановление не подтверждено. Проверяем состояние сна.",
            "",
        ] {
            form.with_anchored_resize(item, || form.render(&r, &report, 60, "", message, 0.));
            settle();
            if (header_gap()? - initial_gap).abs() > 1. {
                return None;
            }
        }
        crate::status_item::nespat_status_destroy(item);
    }
    form.expanded.set(true);
    report.status.error =
        Some("Восстановление не подтверждено. Фоновая служба проверяет состояние сна.".into());
    form.render(&r, &report, 60, "", "", 0.);
    if form.controller.preferredContentSize().height <= expected.height + 65. {
        return None;
    }
    form.expanded.set(false);
    report.status.error = None;
    form.render(&r, &report, 60, "", "", 0.);
    if form.controller.preferredContentSize() != expected || expected.width != 300. {
        return None;
    }
    let view = form.controller.view();
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(m),
            NSRect::new(NSPoint::ZERO, NSSize::new(expected.width, expected.height)),
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    window.setAppearance(NSAppearance::appearanceNamed(&ns("NSAppearanceNameDarkAqua")).as_deref());
    window.setContentView(Some(&view));
    view.layoutSubtreeIfNeeded();
    let rep = view.bitmapImageRepForCachingDisplayInRect(view.bounds())?;
    view.cacheDisplayInRect_toBitmapImageRep(view.bounds(), &rep);
    let png = unsafe {
        rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())?
    };
    std::fs::write(path, unsafe { png.as_bytes_unchecked() }).ok()?;
    println!(
        "Native panel {:.0} × {:.0} pt, transient content resized correctly",
        expected.width, expected.height
    );
    Some(())
}
