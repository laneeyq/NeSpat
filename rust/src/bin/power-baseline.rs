//! Capture and compare both macOS power profiles without changing power settings.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, env, error::Error, fs, process::Command};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
type Profiles = BTreeMap<String, BTreeMap<String, String>>;

fn profiles(raw: &str) -> Result<Profiles> {
    let mut result = Profiles::new();
    let mut current = None;
    for line in raw.lines().filter(|l| !l.trim().is_empty()) {
        if !line.starts_with(char::is_whitespace) {
            let name = line.strip_suffix(':').ok_or("invalid section")?;
            if !matches!(name, "Battery Power" | "AC Power") || result.contains_key(name) {
                return Err("unexpected or duplicate profile".into());
            }
            result.insert(name.into(), BTreeMap::new());
            current = result.get_mut(name);
        } else {
            let fields = current.as_deref_mut().ok_or("missing section")?;
            let (key, value) = line
                .trim()
                .rsplit_once(char::is_whitespace)
                .ok_or("missing value")?;
            let key = key.trim_end();
            if key.is_empty() || fields.insert(key.into(), value.into()).is_some() {
                return Err("invalid or duplicate setting".into());
            }
        }
    }
    if result.len() != 2 || result.values().any(BTreeMap::is_empty) {
        return Err("incomplete power profiles".into());
    }
    Ok(result)
}
fn command(cmd: &str, args: &[&str]) -> Result<String> {
    // A failed sensor command must never be interpreted as an ordinary power state.
    let dir = tempfile::tempdir()?;
    let stdout = dir.path().join("out");
    let stderr = dir.path().join("err");
    let mut child = Command::new(cmd)
        .args(args)
        .stdout(fs::File::create(&stdout)?)
        .stderr(fs::File::create(&stderr)?)
        .spawn()?;
    let start = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if start.elapsed().as_secs() >= 15 {
            let _ = child.kill();
            child.wait()?;
            return Err(format!("{cmd} timed out").into());
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    };
    if !status.success() || !fs::read_to_string(stderr)?.trim().is_empty() {
        return Err(format!("{cmd} failed").into());
    }
    Ok(fs::read_to_string(stdout)?)
}
fn records(class: &str) -> Result<Vec<plist::Value>> {
    let text = command("/usr/sbin/ioreg", &["-a", "-r", "-c", class])?;
    Ok(plist::from_bytes(text.as_bytes())?)
}
fn capture() -> Result<Value> {
    let uid = unsafe { libc::getuid() };
    if uid == 0 || uid != unsafe { libc::geteuid() } {
        return Err("ordinary user required".into());
    }
    let raw = command("/usr/bin/pmset", &["-g", "custom"])?;
    let fields = profiles(&raw)?;
    let domain = records("IOPMrootDomain")?;
    let disabled: Vec<_> = domain
        .iter()
        .filter_map(|v| v.as_dictionary()?.get("SleepDisabled"))
        .collect();
    if records("AppleSmartBattery")?.len() != 1
        || disabled.len() != 1
        || disabled[0].as_boolean() != Some(false)
    {
        return Err("battery or ordinary sleep unconfirmed".into());
    }
    Ok(
        json!({"version":1,"timestamp_UTC":command("/bin/date",&["-u","+%Y-%m-%dT%H:%M:%SZ"])?.trim(),
        "context":{"uid":uid,"boot":command("/usr/sbin/sysctl",&["-n","kern.bootsessionuuid"])?.trim(),
        "os":command("/usr/bin/sw_vers",&["-buildVersion"])?.trim(),"architecture":command("/usr/bin/uname",&["-m"])?.trim(),
        "pmset_sha256":format!("{:x}",Sha256::digest(fs::read("/usr/bin/pmset")?))},
        "profiles":fields,"raw_custom":raw,"SleepDisabled":false}),
    )
}
fn compare(a: &Value, b: &Value) -> Result<()> {
    for record in [a, b] {
        let context = record["context"].as_object().ok_or("missing context")?;
        let valid = context.len() == 5
            && ["uid", "boot", "os", "architecture", "pmset_sha256"]
                .iter()
                .all(|k| context.contains_key(*k));
        if !valid
            || record["version"] != 1
            || record["SleepDisabled"] != false
            || record["profiles"]
                != serde_json::to_value(profiles(
                    record["raw_custom"]
                        .as_str()
                        .ok_or("missing raw profiles")?,
                )?)?
        {
            return Err("invalid baseline".into());
        }
    }
    if a["context"] != b["context"] || a["profiles"] != b["profiles"] {
        return Err("power settings or context changed".into());
    }
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    match args.as_slice() {
        [flag] if flag == "--capture" => println!("{}", serde_json::to_string_pretty(&capture()?)?),
        [flag, a, b] if flag == "--compare" => {
            compare(
                &serde_json::from_slice(&fs::read(a)?)?,
                &serde_json::from_slice(&fs::read(b)?)?,
            )?;
            println!("Both power profiles and context match.");
        }
        _ => return Err("usage: --capture | --compare BEFORE AFTER".into()),
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    const RAW: &str = "Battery Power:\n sleep 0\n Sleep On Power Button 1\nAC Power:\n sleep 0\n";
    fn sample() -> Value {
        json!({"version":1,"SleepDisabled":false,"profiles":profiles(RAW).unwrap(),"raw_custom":RAW,"context":{"uid":501,"boot":"boot","os":"build","architecture":"arm64","pmset_sha256":"hash"}})
    }
    #[test]
    fn incomplete_or_duplicate_settings_fail() {
        for bad in [
            String::new(),
            "AC Power:\n sleep 0".into(),
            format!("{RAW}AC Power:\n sleep 0"),
            format!("{RAW}UPS Power:\n x 0"),
            format!("{RAW} sleep 1"),
            format!("sleep 1\n{RAW}"),
        ] {
            assert!(profiles(&bad).is_err());
        }
    }
    #[test]
    fn both_profiles_and_context_must_match() {
        let a = sample();
        let mut b = a.clone();
        b["timestamp_UTC"] = json!("later");
        assert!(compare(&a, &b).is_ok());
        for (k, v) in [
            ("SleepDisabled", Value::Null),
            ("version", json!(2)),
            ("profiles", json!({})),
            ("context", json!({})),
        ] {
            let mut b = a.clone();
            b[k] = v;
            assert!(compare(&a, &b).is_err());
        }
        b["context"]["boot"] = json!("another");
        assert!(compare(&a, &b).is_err());
        let mut b = a.clone();
        let raw = RAW.replacen("sleep 0", "sleep 1", 1);
        b["raw_custom"] = json!(raw);
        b["profiles"] = json!(profiles(&raw).unwrap());
        assert!(compare(&a, &b).is_err());
    }
}
