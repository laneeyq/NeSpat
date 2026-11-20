fn main() {
    let args: Vec<_> = std::env::args().collect();
    let status =
        objc2::rc::autoreleasepool(|_| nespat_core::service_host::run(&args)).unwrap_or(78);
    if status == 78 {
        eprintln!("Local helper preflight failed; no service started.");
    }
    std::process::exit(status);
}
