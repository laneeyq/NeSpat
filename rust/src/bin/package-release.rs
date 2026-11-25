//! Assemble the signed launcher and its pinned service payload with macOS release tools.
use sha2::{Digest, Sha256};
use std::{env, error::Error, fs, path::Path, process::Command};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn run(command: &mut Command) -> Result<String> {
    let output = command.output()?;
    if !output.status.success() {
        return Err(format!(
            "{command:?}: {}\n{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn sign(path: &Path, id: Option<&str>) -> Result<()> {
    let mut command = Command::new("codesign");
    command.args(["-fs", "-", "--options", "runtime"]);
    if let Some(id) = id {
        command.args(["--identifier", id]);
    }
    run(command.arg(path))?;
    Ok(())
}

fn pin(path: &Path) -> Result<String> {
    let result = Command::new("codesign")
        .args(["-dv", "--verbose=4"])
        .arg(path)
        .output()?;
    let info = String::from_utf8(result.stderr)?;
    let hash = info
        .lines()
        .find_map(|s| s.strip_prefix("CDHash="))
        .filter(|s| s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit()));
    if !result.status.success() {
        return Err(info.into());
    }
    Ok(hash.ok_or("missing code directory hash")?.to_owned())
}

fn checked_executable(file: &Path) -> Result<()> {
    if run(Command::new("lipo").arg("-archs").arg(file))? != "arm64"
        || run(Command::new("otool").arg("-L").arg(file))?.contains("libswift")
    {
        return Err(format!(
            "unexpected binary architecture or dependency: {}",
            file.display()
        )
        .into());
    }
    Ok(())
}

fn package(output: &Path) -> Result<()> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) || !output.is_absolute() {
        return Err("expected Apple Silicon and an absolute output directory".into());
    }
    fs::create_dir_all(output)?;
    for name in ["NeSpat.dmg", "NeSpat-Update.pkg", "SHA256.txt"] {
        if output.join(name).try_exists()? {
            return Err(format!("{name} already exists").into());
        }
    }
    let root = env::current_dir()?;
    let stage = tempfile::Builder::new()
        .prefix("nespat-release.")
        .tempdir_in("/private/tmp")?;
    let stage = stage.path();
    let scripts = stage.join("scripts");
    let pkg = stage.join("pkg");
    let app = stage.join("NeSpat.app");
    let contents = app.join("Contents");
    let helper = contents.join("Library/Helpers/NeSpatPrivilegeHelper");
    let checker = contents.join("Library/Helpers/check-update");
    let panel = contents.join("MacOS/NeSpat");
    let setup = scripts.join("setup");
    let image = stage.join("image/NeSpat.app");
    let outer = image.join("Contents");
    let launcher = outer.join("MacOS/NeSpat");
    let resources = stage.join("resources");
    for dir in [
        &scripts,
        &pkg,
        &resources,
        &contents.join("MacOS"),
        &contents.join("Library/Helpers"),
        &contents.join("Resources"),
        &outer.join("MacOS"),
        &outer.join("Resources"),
    ] {
        fs::create_dir_all(dir)?;
    }
    let home = env::var("HOME")?;
    let cache = env::var("CARGO_HOME").unwrap_or_else(|_| format!("{home}/.cargo"));
    let flags = format!("{} --remap-path-prefix={}=NeSpat --remap-path-prefix={cache}=cargo --remap-path-prefix={home}=home",
        env::var("RUSTFLAGS").unwrap_or_default(),root.display());
    let target = root.join("rust/target");
    let binaries = target.join("release");
    let cargo_build = || {
        let mut cargo = Command::new(env::var_os("CARGO").unwrap_or_else(|| "cargo".into()));
        cargo
            .env("RUSTFLAGS", &flags)
            .env("CARGO_TARGET_DIR", &target)
            .env("MACOSX_DEPLOYMENT_TARGET", "14.0")
            .args([
                "build",
                "--locked",
                "--release",
                "--manifest-path",
                "rust/Cargo.toml",
            ]);
        cargo
    };
    let mut cargo = cargo_build();
    for name in ["panel", "helper", "setup", "check-update"] {
        cargo.args(["--bin", name]);
    }
    run(&mut cargo)?;
    for (name, to) in [
        ("panel", &panel),
        ("helper", &helper),
        ("setup", &setup),
        ("check-update", &checker),
    ] {
        fs::copy(binaries.join(name), to)?;
    }
    for dir in [&contents, &outer] {
        fs::copy("Resources/AppIcon.icns", dir.join("Resources/AppIcon.icns"))?;
        fs::copy("Resources/Info.plist", dir.join("Info.plist"))?;
    }
    fs::copy("LICENSE", contents.join("Resources/LICENSE"))?;
    let plist = contents.join("Info.plist");
    let version = run(Command::new("plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw"])
        .arg(&plist))?;
    run(Command::new("plutil")
        .args(["-insert", "NeSpatExclusive", "-bool", "YES"])
        .arg(&plist))?;
    for (key, value) in [
        ("CFBundleIdentifier", "local.nespat.launcher"),
        ("CFBundleDisplayName", "NeSpat"),
    ] {
        run(Command::new("plutil")
            .args(["-replace", key, "-string", value])
            .arg(outer.join("Info.plist")))?;
    }
    run(Command::new("strip")
        .args(["-S", "-x"])
        .arg(&helper)
        .arg(&panel)
        .arg(&setup))?;
    sign(&checker, None)?;
    sign(&helper, Some("local.nespat.privilege-helper"))?;
    sign(&app, Some("local.nespat.app"))?;
    let pins = serde_json::json!({"guiHash":pin(&app)?,"helperHash":pin(&helper)?});
    fs::write(scripts.join("pins.json"), serde_json::to_vec(&pins)?)?;
    fs::copy(scripts.join("pins.json"), stage.join("profile.json"))?;
    run(Command::new(&panel).arg("--verify-local-build"))?;
    sign(&setup, None)?;
    run(Command::new(&setup).arg("--verify").arg(&app))?;
    run(Command::new("/usr/bin/zip").current_dir(stage).args([
        "-qrX",
        "scripts/app.zip",
        "NeSpat.app",
    ]))?;
    fs::copy("scripts/release/postinstall", scripts.join("postinstall"))?;
    run(Command::new("pkgbuild")
        .env("COPYFILE_DISABLE", "1")
        .args(["--nopayload", "--scripts"])
        .arg(&scripts)
        .args([
            "--identifier",
            "local.nespat.public.install",
            "--version",
            &version,
        ])
        .arg(pkg.join("component.pkg")))?;
    fs::copy(
        "scripts/release/welcome.html",
        resources.join("welcome.html"),
    )?;
    let services = outer.join("Resources/Services.pkg");
    run(Command::new("productbuild")
        .args([
            "--distribution",
            "scripts/release/distribution.xml",
            "--resources",
        ])
        .arg(&resources)
        .arg("--package-path")
        .arg(&pkg)
        .arg(&services))?;
    let digest = format!("{:x}", Sha256::digest(fs::read(&services)?));
    run(cargo_build()
        .env("NESPAT_SERVICES_SHA256", digest)
        .args(["--bin", "launcher"]))?;
    fs::copy(binaries.join("launcher"), &launcher)?;
    sign(&image, None)?;
    for exe in [&launcher, &panel, &helper, &checker, &setup] {
        checked_executable(exe)?;
    }
    run(Command::new("codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(&image))?;
    let artifacts = tempfile::Builder::new()
        .prefix(".nespat-")
        .tempdir_in(output)?;
    let dmg = artifacts.path().join("NeSpat.dmg");
    let mut cmd = Command::new("dmgbuild");
    cmd.args(["-s", "scripts/release/layout.py", "-D"])
        .arg(format!("app={}", image.display()))
        .arg("-D")
        .arg(format!(
            "background={}",
            root.join("Resources/Backdrop.tiff").display()
        ))
        .arg("NeSpat")
        .arg(&dmg);
    run(&mut cmd)?;
    run(Command::new("hdiutil").arg("verify").arg(&dmg))?;
    fs::copy(services, artifacts.path().join("NeSpat-Update.pkg"))?;
    let mut hashes = String::new();
    for name in ["NeSpat.dmg", "NeSpat-Update.pkg"] {
        hashes.push_str(&format!(
            "{:x}  {name}\n",
            Sha256::digest(fs::read(artifacts.path().join(name))?)
        ));
    }
    fs::write(artifacts.path().join("SHA256.txt"), hashes)?;
    let mut linked = Vec::new();
    for name in ["NeSpat.dmg", "NeSpat-Update.pkg", "SHA256.txt"] {
        let destination = output.join(name);
        if let Err(e) = fs::hard_link(artifacts.path().join(name), &destination) {
            for path in linked {
                fs::remove_file(path)?;
            }
            return Err(e.into());
        }
        linked.push(destination);
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let [out] = args.as_slice() else {
        return Err("expected release output directory".into());
    };
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    env::set_current_dir(root)?;
    package(Path::new(out))
}

#[cfg(test)]
mod tests {
    #[test]
    fn panel_declares_why_it_requests_bluetooth_access() {
        let info =
            plist::Value::from_reader_xml(&include_bytes!("../../../Resources/Info.plist")[..])
                .unwrap();
        assert!(
            info.as_dictionary()
                .and_then(|d| d.get("NSBluetoothAlwaysUsageDescription"))
                .and_then(plist::Value::as_string)
                .is_some_and(|s| !s.trim().is_empty()),
            "missing Bluetooth purpose string"
        );
    }
}
