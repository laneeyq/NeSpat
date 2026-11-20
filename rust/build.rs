use std::{env, path::PathBuf, process::Command};

fn main() {
    let source = "bridge/ServiceProtocol.m";
    println!("cargo:rerun-if-changed={source}");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let object = out.join("ServiceProtocol.o");
    let archive = out.join("libnespat_schema.a");
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        _ => panic!("Unsupported macOS architecture"),
    };
    assert!(Command::new("xcrun")
        .args([
            "--sdk",
            "macosx",
            "clang",
            "-arch",
            arch,
            "-mmacosx-version-min=14.0",
            "-fblocks",
            "-Werror",
            "-c",
            source,
            "-o"
        ])
        .arg(&object)
        .status()
        .unwrap()
        .success());
    assert!(Command::new("xcrun")
        .args(["libtool", "-static", "-o"])
        .arg(archive)
        .arg(object)
        .status()
        .unwrap()
        .success());
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=nespat_schema");
}
