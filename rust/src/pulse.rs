use crate::{
    host::nespat_continuous_seconds,
    request::{uuid, uuid_text},
};
use serde_json::{json, Value};
use std::{
    fs::{File, Permissions},
    io::{Read, Write},
    os::unix::fs::PermissionsExt,
    path::Path,
};
use tempfile::NamedTempFile;
const RUNTIME: &str = "/Library/Application Support/NeSpatPrivileged/Runtime";
fn role(watch: bool) -> &'static str {
    if watch {
        "watchdog"
    } else {
        "helper"
    }
}
#[repr(C)]
pub struct Pulse {
    epoch: [u8; 16],
    boot: [u8; 16],
    setup: [u8; 16],
    continuous: f64,
    pid: i32,
}
fn path(watch: bool) -> std::path::PathBuf {
    Path::new(RUNTIME).join(format!("{}.json", role(watch)))
}
fn publish(value: &mut Pulse, watch: bool) -> Option<()> {
    if unsafe { libc::geteuid() } != 0 {
        return None;
    }
    value.continuous = nespat_continuous_seconds();
    if !value.continuous.is_finite() {
        return None;
    }
    value.pid = unsafe { libc::getpid() };
    let obj = json!({"epoch":uuid_text(&value.epoch),"boot":uuid_text(&value.boot),"setup":uuid_text(&value.setup),"continuous":value.continuous,"pid":value.pid,"role":role(watch)});
    let mut temp = NamedTempFile::new_in(RUNTIME).ok()?;
    temp.write_all(&serde_json::to_vec(&obj).ok()?).ok()?;
    temp.as_file()
        .set_permissions(Permissions::from_mode(0o644))
        .ok()?;
    temp.persist(path(watch)).ok()?;
    Some(())
}
#[no_mangle]
pub extern "C" fn nespat_publish_pulse(value: &mut Pulse, watch: bool) -> bool {
    publish(value, watch).is_some()
}
fn read(value: &mut Pulse, watch: bool) -> Option<()> {
    let mut bytes = Vec::new();
    File::open(path(watch))
        .ok()?
        .take(1025)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > 1024 {
        return None;
    }
    let obj: Value = serde_json::from_slice(&bytes).ok()?;
    if uuid(obj["boot"].as_str()?)? != value.boot
        || uuid(obj["setup"].as_str()?)? != value.setup
        || obj["role"] != role(watch)
    {
        return None;
    }
    let pid = i32::try_from(obj["pid"].as_i64()?).ok()?;
    let continuous = obj["continuous"].as_f64()?;
    let age = nespat_continuous_seconds() - continuous;
    if pid <= 1 || !(0.0..8.0).contains(&age) {
        return None;
    }
    if unsafe { libc::kill(pid, 0) } != 0
        && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM)
    {
        return None;
    }
    value.epoch = uuid(obj["epoch"].as_str()?)?;
    value.continuous = continuous;
    value.pid = pid;
    Some(())
}
#[no_mangle]
pub extern "C" fn nespat_read_pulse(value: &mut Pulse, watch: bool) -> bool {
    read(value, watch).is_some()
}
