use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    env,
    error::Error,
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::{
        fd::AsRawFd,
        unix::{
            ffi::OsStrExt,
            fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        },
    },
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::{Builder, NamedTempFile};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const PARENT: &str = "/Library/Application Support";
const BASE: &str = "/Library/Application Support/NeSpatPrivileged";
const DAEMONS: &str = "/Library/LaunchDaemons";
const APP: &str = "/Library/Application Support/NeSpatPrivileged/NeSpat.app";
const HELPER_REL: &str = "Contents/Library/Helpers/NeSpatPrivilegeHelper";
const LABELS: [&str; 2] = ["local.nespat.recovery", "local.nespat.privilege-helper"];
const PROFILE: &str = "LocalTrust/profile.json";
const MARKER: &str = "public-install-v1";

fn command(cmd: &str, args: &[&str]) -> Result<String> {
    let r = Command::new(cmd)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LC_ALL", "C")
        .output()?;
    if !r.status.success() {
        return Err(format!("{cmd}: {} {}", r.status, String::from_utf8_lossy(&r.stderr)).into());
    }
    Ok(String::from_utf8(r.stdout)?.trim().into())
}
fn path(p: &Path) -> Result<&str> {
    p.to_str().ok_or_else(|| "Некорректный путь".into())
}
fn check_dir(p: &Path) -> Result<()> {
    let m = fs::symlink_metadata(p)?;
    if !m.is_dir() || m.uid() != 0 || m.mode() & 0o022 != 0 {
        return Err(format!("Незащищённый каталог {}", p.display()).into());
    }
    unsafe extern "C" {
        fn acl_get_file(p: *const libc::c_char, t: libc::c_int) -> *mut libc::c_void;
        fn acl_free(acl: *mut libc::c_void) -> libc::c_int;
    }
    let c = CString::new(p.as_os_str().as_bytes())?;
    // Darwin ACL_TYPE_EXTENDED. Absence is reported as ENOENT.
    let acl = unsafe { acl_get_file(c.as_ptr(), 0x100) };
    if !acl.is_null() {
        unsafe { acl_free(acl) };
        return Err("Обнаружен ACL каталога установки".into());
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() != Some(libc::ENOENT) {
        return Err(e.into());
    }
    Ok(())
}
fn lock() -> Result<File> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(PARENT)?;
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("Другая установка уже выполняется".into());
    }
    Ok(f)
}
fn write(p: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut f = NamedTempFile::new_in(p.parent().ok_or("Нет каталога")?)?;
    f.as_file()
        .set_permissions(fs::Permissions::from_mode(mode))?;
    f.write_all(bytes)?;
    f.as_file().sync_all()?;
    f.persist(p)?;
    Ok(())
}
fn publish(from: &Path, to: &Path) -> Result<()> {
    let a = CString::new(from.as_os_str().as_bytes())?;
    let b = CString::new(to.as_os_str().as_bytes())?;
    if unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_EXCL) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(())
}
fn read_json(p: &Path) -> Result<Value> {
    Ok(serde_json::from_slice(&fs::read(p)?)?)
}
fn hash(v: &Value, key: &str) -> Result<String> {
    let h = v[key].as_str().ok_or("Отсутствует подпись")?;
    if h.len() != 40 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("Неверная подпись".into());
    }
    Ok(h.to_owned())
}
fn verify(bundle: &Path, resources: &Path) -> Result<()> {
    let pins = read_json(&resources.join("pins.json"))?;
    for (key, id, p) in [
        ("guiHash", "local.nespat.app", bundle.to_owned()),
        ("helperHash", LABELS[1], bundle.join(HELPER_REL)),
    ] {
        let requirement = format!(
            "-R=cdhash H\"{}\" and identifier \"{id}\"",
            hash(&pins, key)?
        );
        command(
            "/usr/bin/codesign",
            &["--verify", "--strict", "--deep", &requirement, path(&p)?],
        )?;
    }
    Ok(())
}
fn spec(label: &str) -> Result<plist::Value> {
    let mut d = plist::Dictionary::new();
    let watch = label == LABELS[0];
    d.insert("Label".into(), label.into());
    d.insert(
        "ProgramArguments".into(),
        plist::Value::Array(vec![
            format!("{APP}/{HELPER_REL}").into(),
            (if watch {
                "--watch-exclusive"
            } else {
                "--serve-local"
            })
            .into(),
        ]),
    );
    for key in ["RunAtLoad", "KeepAlive"] {
        d.insert(key.into(), true.into());
    }
    d.insert("ThrottleInterval".into(), 2i64.into());
    if !watch {
        let mut s = plist::Dictionary::new();
        s.insert(label.into(), true.into());
        d.insert("MachServices".into(), s.into());
    }
    Ok(d.into())
}
fn daemon(label: &str) -> PathBuf {
    Path::new(DAEMONS).join(format!("{label}.plist"))
}
fn loaded(label: &str) -> bool {
    command("/bin/launchctl", &["print", &format!("system/{label}")]).is_ok()
}
fn check_helper(flag: &str) -> Result<()> {
    command(&format!("{APP}/{HELPER_REL}"), &[flag])?;
    Ok(())
}
fn as_user(uid: u32, cmd: &str, args: &[&str]) -> Result<()> {
    let id = uid.to_string();
    let user = format!("#{uid}");
    let mut a = vec!["asuser", &id, "/usr/bin/sudo", "-H", "-u", &user, cmd];
    a.extend_from_slice(args);
    command("/bin/launchctl", &a)?;
    Ok(())
}
fn uninstaller() -> PathBuf {
    Path::new(BASE).join("Uninstall")
}
fn stop_for_removal(
    mut confirm: impl FnMut() -> Result<()>,
    mut stop: impl FnMut(&str) -> Result<()>,
) -> Result<()> {
    for label in LABELS.iter().rev() {
        confirm()?;
        stop(label)?;
    }
    confirm()
}
fn uninstall(resources: &Path) -> Result<()> {
    let _lock = lock()?;
    let base = Path::new(BASE);
    check_dir(base)?;
    verify(Path::new(APP), resources)?;
    for label in LABELS {
        let p = daemon(label);
        if p.try_exists()? && plist::Value::from_file(&p)? != spec(label)? {
            return Err("Содержимое службы изменилось".into());
        }
    }
    let p = base.join(PROFILE);
    let mut profile = read_json(&p)?;
    if !profile.is_object() {
        return Err("Повреждён профиль службы".into());
    }
    profile["enabled"] = false.into();
    write(&p, &serde_json::to_vec(&profile)?, 0o644)?;
    stop_for_removal(
        || check_helper("--check-removable"),
        |label| {
            if loaded(label) {
                command("/bin/launchctl", &["bootout", &format!("system/{label}")])?;
            }
            Ok(())
        },
    )?;
    for label in LABELS {
        let p = daemon(label);
        if p.try_exists()? {
            fs::remove_file(p)?;
        }
    }
    if fs::read_link("/Applications/NeSpat.app").ok().as_deref() == Some(Path::new(APP)) {
        fs::remove_file("/Applications/NeSpat.app")?;
    }
    fs::remove_dir_all(base)?;
    Ok(())
}
fn install(resources: &Path) -> Result<()> {
    let base = Path::new(BASE);
    let stage = Builder::new()
        .prefix(".NeSpat-install-")
        .tempdir_in(PARENT)?;
    let payload = stage.path().join("payload");
    for (dir, mode) in [
        ("", 0o755),
        ("LocalTrust", 0o755),
        ("Runtime", 0o755),
        ("State", 0o700),
    ] {
        fs::DirBuilder::new().mode(mode).create(payload.join(dir))?;
    }
    let staged_app = payload.join("NeSpat.app");
    command(
        "/usr/bin/ditto",
        &[
            "-x",
            "-k",
            path(&resources.join("app.zip"))?,
            path(&payload)?,
        ],
    )?;
    command(
        "/usr/sbin/chown",
        &["-R", "-P", "root:wheel", path(&staged_app)?],
    )?;
    command("/bin/chmod", &["-RN", path(&staged_app)?])?;
    command("/bin/chmod", &["-R", "go-w", path(&staged_app)?])?;
    verify(&staged_app, resources)?;
    // /dev/console is maintained by loginwindow; uid zero means no GUI login.
    let uid = fs::metadata("/dev/console")?.uid();
    if uid < 501 {
        return Err("Войдите в обычную учётную запись Mac".into());
    }
    if base.try_exists()? {
        check_dir(base)?;
        if !base.join(MARKER).is_file() {
            return Err("Установлена другая версия NeSpat".into());
        }
        let version = |bundle: &Path| -> Result<Vec<u32>> {
            let p = plist::Value::from_file(bundle.join("Contents/Info.plist"))?;
            let s = p
                .as_dictionary()
                .and_then(|d| d.get("CFBundleShortVersionString"))
                .and_then(|v| v.as_string())
                .ok_or("Версия приложения неизвестна")?;
            Ok(s.split('.')
                .map(str::parse)
                .collect::<std::result::Result<_, _>>()?)
        };
        if version(Path::new(APP))? < version(&staged_app)? {
            if !command("/usr/bin/pmset", &["-g"])?
                .lines()
                .any(|l| l.split_whitespace().eq(["SleepDisabled", "0"]))
                || command("/bin/ps", &["-axo", "comm="])?
                    .lines()
                    .any(|l| l.trim() == format!("{APP}/Contents/MacOS/NeSpat"))
            {
                return Err("Завершите сессию и выберите «Выход» в панели NeSpat".into());
            }
            let tool = uninstaller();
            let m = fs::symlink_metadata(&tool)?;
            if !m.is_file() || m.uid() != 0 || m.mode() & 0o022 != 0 {
                return Err("Небезопасный деинсталлятор".into());
            }
            command(path(&tool)?, &["--uninstall"])?;
        }
    }
    let _lock = lock()?;
    let pins = read_json(&resources.join("pins.json"))?;
    let mut profile = json!({"guiHash":hash(&pins,"guiHash")?,"helperHash":hash(&pins,"helperHash")?,
        "version":1,"allowedUID":uid,"setup":command("/usr/bin/uuidgen",&[])?,"enabled":false,"exclusiveControl":true,
        "selectedLifetime":true,"trialOnly":false,"trialOnBattery":false,"hostModel":command("/usr/sbin/sysctl",&["-n","hw.model"])?,
        "osBuild":command("/usr/bin/sw_vers",&["-buildVersion"])?});
    if base.try_exists()? {
        check_dir(base)?;
        verify(Path::new(APP), resources)?;
        let saved = read_json(&base.join(PROFILE))?;
        for key in [
            "allowedUID",
            "hostModel",
            "osBuild",
            "guiHash",
            "helperHash",
        ] {
            if saved[key] != profile[key] {
                return Err("Профиль установленной версии изменился".into());
            }
        }
        profile = saved;
    } else {
        for p in LABELS.map(daemon).into_iter().chain(std::iter::once(
            "/Library/LaunchAgents/local.nespat.gui.plist".into(),
        )) {
            if fs::symlink_metadata(&p).is_ok() || p.try_exists()? {
                return Err(format!("Конфликт установки {}", p.display()).into());
            }
        }
        if LABELS.iter().any(|l| loaded(l)) {
            return Err("Служба уже загружена".into());
        }
        write(
            &payload.join(PROFILE),
            &serde_json::to_vec(&profile)?,
            0o644,
        )?;
        let empty = br#"{"generation":1,"version":2}"#;
        write(
            &payload.join("State/authority.json"),
            &serde_json::to_vec(
                &json!({"payload":STANDARD.encode(empty),"sha256":format!("{:x}",Sha256::digest(empty))}),
            )?,
            0o600,
        )?;
        for name in ["State/lock", "State/setter.lock"] {
            write(&payload.join(name), &[], 0o600)?;
        }
        write(&payload.join(MARKER), &[], 0o644)?;
        for (from, to) in [("setup", "Uninstall"), ("pins.json", "pins.json")] {
            fs::copy(resources.join(from), payload.join(to))?;
        }
        publish(&payload, base)?;
    }
    if profile["enabled"] != true {
        check_helper("--check-removable")?;
        check_helper("--check-local")?;
    }
    for label in LABELS {
        let p = daemon(label);
        let expected = spec(label)?;
        if p.try_exists()? {
            if plist::Value::from_file(&p)? != expected {
                return Err(format!("Конфликт службы {label}").into());
            }
        } else {
            let temp = stage.path().join(label);
            let mut xml = Vec::new();
            expected.to_writer_xml(&mut xml)?;
            write(&temp, &xml, 0o644)?;
            publish(&temp, &p)?;
        }
        if !loaded(label) {
            command("/bin/launchctl", &["bootstrap", "system", path(&p)?])?;
        }
    }
    as_user(
        uid,
        &format!("{APP}/Contents/MacOS/NeSpat"),
        &["--verify-local-service"],
    )?;
    profile["enabled"] = true.into();
    write(&base.join(PROFILE), &serde_json::to_vec(&profile)?, 0o644)?;
    let _ = std::os::unix::fs::symlink(APP, "/Applications/NeSpat.app");
    as_user(uid, "/usr/bin/open", &[APP])
}
fn run() -> Result<()> {
    let exe = env::current_exe()?;
    let resources = exe.parent().ok_or("Нет каталога установки")?;
    let args: Vec<_> = env::args().skip(1).collect();
    if let [flag, app] = args.as_slice() {
        if flag == "--verify" {
            return verify(Path::new(app), resources);
        }
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err("Требуются права администратора".into());
    }
    for p in ["/", "/Library", PARENT, DAEMONS] {
        check_dir(Path::new(p))?;
    }
    if args == ["/"] {
        install(resources)
    } else if args == ["--uninstall"] && exe == uninstaller() {
        uninstall(resources)
    } else {
        Err("Некорректный режим установки".into())
    }
}
fn main() {
    if let Err(e) = run() {
        eprintln!("NeSpat: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn removal_rechecks_before_each_service_stop_and_before_deletion() {
        use std::cell::RefCell;
        let steps = ["confirm", LABELS[1], "confirm", LABELS[0], "confirm"];
        for fail_at in 0..=steps.len() {
            let calls = RefCell::new(Vec::new());
            let record = |action: &str| -> Result<()> {
                let mut calls = calls.borrow_mut();
                calls.push(action.to_owned());
                if calls.len() == fail_at + 1 {
                    Err("simulated failure".into())
                } else {
                    Ok(())
                }
            };
            assert_eq!(
                stop_for_removal(|| record("confirm"), record).is_ok(),
                fail_at == steps.len()
            );
            assert_eq!(calls.into_inner(), steps[..(fail_at + 1).min(steps.len())]);
        }
    }
    #[test]
    fn launchd_has_one_fixed_command_per_role_and_only_helper_accepts_xpc() {
        for label in LABELS {
            let d = spec(label).unwrap();
            let d = d.as_dictionary().unwrap();
            assert_eq!(d["Label"].as_string(), Some(label));
            for key in ["KeepAlive", "RunAtLoad"] {
                assert_eq!(d[key].as_boolean(), Some(true));
            }
            let args = d["ProgramArguments"].as_array().unwrap();
            assert_eq!(args.len(), 2);
            assert_eq!(
                args[0].as_string(),
                Some(format!("{APP}/{HELPER_REL}").as_str())
            );
            if label == LABELS[0] {
                assert_eq!(args[1].as_string(), Some("--watch-exclusive"));
                assert!(!d.contains_key("MachServices"));
            } else {
                assert_eq!(args[1].as_string(), Some("--serve-local"));
                assert_eq!(
                    d["MachServices"].as_dictionary().unwrap()[label].as_boolean(),
                    Some(true)
                );
            }
        }
    }
    #[test]
    fn invalid_pins_or_unsigned_payload_do_not_pass_verification() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let info = root.join("pins.json");
        for value in [
            Value::Null,
            serde_json::json!({}),
            serde_json::json!({"guiHash":"invalid"}),
            serde_json::json!({"guiHash":"0".repeat(40),"helperHash":"1".repeat(40)}),
        ] {
            fs::write(&info, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(verify(root, root).is_err());
        }
    }
    #[test]
    fn exclusive_publication_preserves_other_files_and_atomic_write_uses_requested_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("new");
        let b = tmp.path().join("existing");
        write(&a, b"new", 0o600).unwrap();
        write(&b, b"keep", 0o600).unwrap();
        assert!(publish(&a, &b).is_err());
        assert_eq!(fs::read(&b).unwrap(), b"keep");
        let c = tmp.path().join("destination");
        publish(&a, &c).unwrap();
        assert_eq!(fs::read(&c).unwrap(), b"new");
        assert_eq!(fs::metadata(&c).unwrap().mode() & 0o777, 0o600);
    }
}
