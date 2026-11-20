//! Collect rootless diagnostic evidence in an exclusive directory.
use serde_json::json;
use std::{
    env,
    error::Error,
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::Command,
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
fn create(parent: &Path, prefix: &str) -> Result<PathBuf> {
    if prefix.is_empty()
        || !prefix
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return Err("invalid directory prefix".into());
    }
    Ok(tempfile::Builder::new()
        .prefix(&format!("{prefix}-"))
        .tempdir_in(parent)?
        .keep())
}
fn reserve(dir: &Path, name: &str) -> Result<File> {
    use std::os::fd::AsRawFd;
    use std::os::fd::FromRawFd;
    if name.is_empty() || matches!(name, "." | "..") || name.contains('/') {
        return Err("flat log name required".into());
    }
    let parent = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(dir)?;
    let file = std::ffi::CString::new(name)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            file.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600 as libc::c_int,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn utc() -> String {
    let now = std::time::SystemTime::now();
    plist::Date::from(now).to_xml_format()
}
fn record(dir: &Path, label: &str, cwd: &Path, args: &[OsString]) -> Result<i32> {
    let (program, args_tail) = args.split_first().ok_or("missing command")?;
    let mut file = reserve(dir, &format!("{label}.json"))?;
    let mut entry = json!({"argv":args.iter().map(|a|a.to_string_lossy()).collect::<Vec<_>>(),"cwd":cwd,"started_UTC":utc()});
    let result = Command::new(program)
        .args(args_tail)
        .current_dir(cwd)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output();
    match &result {
        Ok(out) => {
            entry["exit_code"] = json!(out.status.code());
            entry["stdout"] = json!(String::from_utf8_lossy(&out.stdout));
            entry["stderr"] = json!(String::from_utf8_lossy(&out.stderr));
        }
        Err(e) => {
            entry["exit_code"] = serde_json::Value::Null;
            entry["error"] = json!(e.to_string());
        }
    }
    entry["ended_UTC"] = json!(utc());
    serde_json::to_writer_pretty(&mut file, &entry)?;
    file.flush()?;
    file.sync_all()?;
    Ok(result?.status.code().unwrap_or(1))
}
fn main() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    match args.as_slice() {
        [dir, prefix] => println!(
            "{}",
            create(Path::new(dir), prefix.to_str().ok_or("invalid prefix")?)?.display()
        ),
        [flag, dir, label, cwd, command @ ..] if flag == "--run" => std::process::exit(record(
            Path::new(dir),
            label.to_str().ok_or("invalid label")?,
            Path::new(cwd),
            command,
        )?),
        [flag, dir, name, source] if flag == "--write" => {
            let mut log = reserve(Path::new(dir), name.to_str().ok_or("invalid name")?)?;
            std::io::copy(&mut fs::File::open(source)?, &mut log)?;
            log.sync_all()?;
        }
        _ => {
            return Err(
                "expected PARENT PREFIX, --write DIR NAME FILE or --run DIR LABEL CWD COMMAND ..."
                    .into(),
            )
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unique_directories_and_exclusive_logs() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = create(tmp.path(), "audit").unwrap();
        assert_ne!(dir, create(tmp.path(), "audit").unwrap());
        assert!(create(tmp.path(), "../escape").is_err());
        assert!(create(&tmp.path().join("absent"), "audit").is_err());
        reserve(&dir, "run.json")
            .unwrap()
            .write_all(b"old")
            .unwrap();
        assert!(record(
            &dir,
            "run",
            &dir,
            &["/usr/bin/touch".into(), "unexpected".into()]
        )
        .is_err());
        assert!(!dir.join("unexpected").exists());
        assert_eq!(fs::read(dir.join("run.json")).unwrap(), b"old");
        std::os::unix::fs::symlink("/nonexistent", dir.join("link")).unwrap();
        assert!(reserve(&dir, "link").is_err());
        assert!(reserve(&dir, "../escape").is_err());
    }
}
