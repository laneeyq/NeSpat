use objc2::{
    define_class, msg_send, rc::Retained, AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly,
};
use objc2_app_kit::{NSBezierPath, NSColor, NSGradient, NSGraphicsContext, NSView};
use objc2_foundation::{NSArray, NSRect};
use std::cell::Cell;

pub(crate) struct MeterStyle {
    fraction: Cell<f64>,
    battery: bool,
    gradient: Retained<NSGradient>,
    gloss: Retained<NSGradient>,
}
define_class!(
    #[unsafe(super = NSView)]
    #[thread_kind = MainThreadOnly]
    #[ivars = MeterStyle]
    pub(crate) struct NeSpatMeter;
    impl NeSpatMeter {
        #[unsafe(method(drawRect:))]
        fn draw(&self,_dirty:NSRect){
            let rect=self.bounds(); let style=self.ivars();
            let f=style.fraction.get(); if !f.is_finite() { return; }
            let track=NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(rect,2.5,2.5);
            NSColor::secondaryLabelColor().colorWithAlphaComponent(0.22).setFill();
            track.fill();
            let mut fill=rect;fill.size.width*=f.clamp(0.,1.); if fill.size.width<=0. {return;}
            let cap=NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(fill,2.5,2.5);
            NSGraphicsContext::saveGraphicsState_class();
            cap.addClip();
            if style.battery {
                let color= if f<0.15 {NSColor::systemRedColor()}else if f<0.3 {NSColor::systemYellowColor()}else{NSColor::systemGreenColor()};
                color.setFill();cap.fill();
            }else{style.gradient.drawInRect_angle(rect,0.);}
            style.gloss.drawInRect_angle(fill,90.);
            NSGraphicsContext::restoreGraphicsState_class();
        }
    }
);
impl NeSpatMeter {
    pub(crate) fn build(mtm: MainThreadMarker, battery: bool) -> Retained<Self> {
        let colors = NSArray::from_retained_slice(&[
            NSColor::systemGreenColor(),
            NSColor::systemYellowColor(),
            NSColor::systemRedColor(),
        ]);
        let gradient = NSGradient::initWithColors(NSGradient::alloc(), &colors).unwrap();
        let white = NSColor::whiteColor();
        let gloss = NSGradient::initWithStartingColor_endingColor(
            NSGradient::alloc(),
            &white.colorWithAlphaComponent(0.02),
            &white.colorWithAlphaComponent(0.32),
        )
        .unwrap();
        let obj = Self::alloc(mtm).set_ivars(MeterStyle {
            fraction: Cell::new(f64::NAN),
            battery,
            gradient,
            gloss,
        });
        unsafe { msg_send![super(obj),initWithFrame:NSRect::ZERO] }
    }
    pub(crate) fn update(&self, fraction: f64) {
        if self.ivars().fraction.replace(fraction).to_bits() != fraction.to_bits() {
            self.setNeedsDisplay(true);
        }
    }
}
