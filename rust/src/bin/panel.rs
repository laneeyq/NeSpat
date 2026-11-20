fn main() {
    objc2::rc::autoreleasepool(|_| {
        let m = objc2::MainThreadMarker::new().expect("AppKit main thread");
        let args: Vec<_> = std::env::args().skip(1).collect();
        #[cfg(debug_assertions)]
        if args.len() == 2 && args[0] == "--render-fixture" {
            std::process::exit(
                if nespat_core::panel::preview(m, std::path::Path::new(&args[1])).is_some() {
                    0
                } else {
                    1
                },
            );
        }
        if args.is_empty() || args == ["--auto-agent"] {
            nespat_core::panel::run(m);
        } else if args.len() == 1 {
            std::process::exit(nespat_core::panel_cli::run(&args[0]));
        } else {
            std::process::exit(64);
        }
    });
}
