// All calls from the application delegate are isolated to the AppKit main thread.
use objc2::{
    define_class, msg_send, rc::Retained, sel, DefinedClass, MainThreadMarker, MainThreadOnly,
};
use objc2_app_kit::{
    NSFont, NSPopover, NSPopoverBehavior, NSStatusBar, NSStatusBarButton, NSStatusItem,
    NSVariableStatusItemLength, NSViewController,
};
use objc2_foundation::{NSObject, NSRectEdge, NSString};
use std::{
    ffi::{c_char, c_void, CStr},
    ptr,
};

struct Panel {
    item: Retained<NSStatusItem>,
    popover: std::cell::RefCell<Retained<NSPopover>>,
    #[cfg(debug_assertions)]
    fixture_anchor: std::cell::OnceCell<Retained<objc2_app_kit::NSView>>,
}

define_class!(
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[ivars = Panel]
    struct NeSpatStatusTarget;

    impl NeSpatStatusTarget {
        #[unsafe(method(toggleNeSpatPanel:))]
        fn toggle(&self, button: &NSStatusBarButton) {
            let panel = self.ivars();
            let popover = panel.popover.borrow();
            if popover.isShown() {
                unsafe { popover.performClose(None); }
            } else {
                popover.showRelativeToRect_ofView_preferredEdge(button.bounds(), button, NSRectEdge::MinY);
                if let Some(window) = popover.contentViewController().and_then(|vc| vc.view().window()) {
                    window.makeKeyWindow();
                }
            }
        }
    }
);

#[no_mangle]
pub unsafe extern "C" fn nespat_status_create(controller: *const NSViewController) -> *mut c_void {
    let (Some(mtm), Some(controller)) = (MainThreadMarker::new(), controller.as_ref()) else {
        return ptr::null_mut();
    };
    let bar = NSStatusBar::systemStatusBar();
    let item = bar.statusItemWithLength(NSVariableStatusItemLength);
    item.setAutosaveName(Some(&NSString::from_str("local.nespat.statusItem.v2")));
    let Some(button) = item.button(mtm) else {
        bar.removeStatusItem(&item);
        return ptr::null_mut();
    };
    let popover = NSPopover::new(mtm);
    popover.setContentViewController(Some(controller));
    popover.setBehavior(NSPopoverBehavior::Transient);
    popover.setAnimates(false);
    let target = NeSpatStatusTarget::alloc(mtm).set_ivars(Panel {
        item,
        popover: popover.into(),
        #[cfg(debug_assertions)]
        fixture_anchor: Default::default(),
    });
    let target: Retained<NeSpatStatusTarget> = msg_send![super(target), init];
    button.setTarget(Some(&target));
    button.setAction(Some(sel!(toggleNeSpatPanel:)));
    button.setFont(Some(&NSFont::monospacedDigitSystemFontOfSize_weight(
        13.0, 0.0,
    )));
    button.setToolTip(Some(&NSString::from_str("NeSpat")));
    Retained::into_raw(target).cast()
}

#[cfg(debug_assertions)]
pub(crate) unsafe fn preview_open(
    target: *const c_void,
    anchor: &objc2_app_kit::NSView,
) -> Option<()> {
    let target = target.cast::<NeSpatStatusTarget>().as_ref()?;
    target
        .ivars()
        .fixture_anchor
        .set(Retained::retain(anchor as *const _ as *mut _)?)
        .ok()?;
    target
        .ivars()
        .popover
        .borrow()
        .showRelativeToRect_ofView_preferredEdge(anchor.bounds(), anchor, NSRectEdge::MinY);
    target.ivars().popover.borrow().isShown().then_some(())
}

pub(crate) unsafe fn resize(target: *const c_void, size: objc2_foundation::NSSize) {
    if let Some(target) = target.cast::<NeSpatStatusTarget>().as_ref() {
        let panel = target.ivars();
        let mut current = panel.popover.borrow_mut();
        if !current.isShown() {
            current.setContentSize(size);
            return;
        }
        let Some(controller) = current.contentViewController() else {
            return;
        };
        let Some(button) = panel.item.button(target.mtm()) else {
            return;
        };
        let anchor: &objc2_app_kit::NSView = &button;
        #[cfg(debug_assertions)]
        let anchor = panel.fixture_anchor.get().map_or(anchor, |v| &**v);
        // AppKit can reuse a stale window frame when a visible popover changes size.
        // Reuse the controls and controller, and present at the original status-item anchor.
        let popover = NSPopover::new(target.mtm());
        popover.setBehavior(current.behavior());
        popover.setAnimates(false);
        current.close();
        current.setContentViewController(None);
        controller.view().setFrameSize(size);
        popover.setContentViewController(Some(&controller));
        popover.setContentSize(size);
        popover.showRelativeToRect_ofView_preferredEdge(anchor.bounds(), anchor, NSRectEdge::MinY);
        if let Some(window) = controller.view().window() {
            window.makeKeyWindow();
        }
        *current = popover;
    }
}

#[no_mangle]
pub unsafe extern "C" fn nespat_status_title(target: *const c_void, title: *const c_char) {
    if title.is_null() {
        return;
    }
    let (Some(mtm), Some(target)) = (
        MainThreadMarker::new(),
        target.cast::<NeSpatStatusTarget>().as_ref(),
    ) else {
        return;
    };
    if let (Some(button), Ok(text)) = (
        target.ivars().item.button(mtm),
        CStr::from_ptr(title).to_str(),
    ) {
        button.setTitle(&NSString::from_str(text));
    }
}

#[no_mangle]
pub unsafe extern "C" fn nespat_status_destroy(target: *mut c_void) {
    if MainThreadMarker::new().is_none() {
        return;
    }
    if let Some(owner) = Retained::from_raw(target.cast::<NeSpatStatusTarget>()) {
        NSStatusBar::systemStatusBar().removeStatusItem(&owner.ivars().item);
    }
}
