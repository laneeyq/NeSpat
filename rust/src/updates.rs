use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    error::Error,
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::NamedTempFile;

pub const REPOSITORY: &str = "laneeyq/NeSpat";
const PACKAGE: &str = "NeSpat-Update.pkg";
const LIMIT: u64 = 50_000_000;
type Result<T> = std::result::Result<T, Box<dyn Error>>;
fn numbers(s: &str) -> Option<[u32; 3]> {
    let mut out = [0; 3];
    let mut parts = s.split('.');
    for n in &mut out {
        let p = parts.next()?;
        if p.is_empty() || p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        *n = p.parse().ok()?;
    }
    parts.next().is_none().then_some(out)
}
struct Asset {
    version: String,
    bytes: u64,
    digest: String,
}
fn candidate(release: &Value, installed: &str) -> Result<Option<Asset>> {
    if release["draft"].as_bool() != Some(false) || release["prerelease"].as_bool() != Some(false) {
        return Err("Нестабильный выпуск".into());
    }
    let version = release["tag_name"]
        .as_str()
        .and_then(|s| s.strip_prefix('v'))
        .ok_or("Нет тега")?;
    let remote = numbers(version).ok_or("Неверный номер версии")?;
    let local = numbers(installed).ok_or("Неизвестна версия панели")?;
    if remote <= local {
        return Ok(None);
    }
    let asset = release["assets"]
        .as_array()
        .and_then(|a| a.iter().find(|v| v["name"] == PACKAGE))
        .ok_or("В выпуске нет пакета")?;
    let bytes = asset["size"]
        .as_u64()
        .filter(|n| (1..=LIMIT).contains(n))
        .ok_or("Неподдерживаемый размер")?;
    let digest = asset["digest"]
        .as_str()
        .and_then(|s| s.strip_prefix("sha256:"))
        .filter(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or("В выпуске нет SHA-256")?;
    Ok(Some(Asset {
        version: version.into(),
        bytes,
        digest: digest.into(),
    }))
}
fn download(url: &str, dest: &Path, max: u64) -> Result<()> {
    // No shell or curlrc. HTTPS-only redirects are required for GitHub's asset CDN.
    let status = Command::new("/usr/bin/curl")
        .args([
            "-q",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--max-time",
            "120",
            "--max-filesize",
            &max.to_string(),
            "--output",
        ])
        .arg(dest)
        .arg(url)
        .status()?;
    if !status.success() || fs::metadata(dest)?.len() > max {
        return Err("Ошибка загрузки обновления".into());
    }
    Ok(())
}
pub fn check(installed: &str, folder: &Path) -> Result<Option<(String, PathBuf)>> {
    let manifest = NamedTempFile::new()?;
    download(
        &format!("https://api.github.com/repos/{REPOSITORY}/releases/latest"),
        manifest.path(),
        1_000_000,
    )?;
    let release: Value = serde_json::from_reader(manifest.as_file())?;
    let Some(asset) = candidate(&release, installed)? else {
        return Ok(None);
    };
    fs::create_dir_all(folder)?;
    let mut file = NamedTempFile::new_in(folder)?;
    download(
        &format!(
            "https://github.com/{REPOSITORY}/releases/download/v{}/{PACKAGE}",
            asset.version
        ),
        file.path(),
        asset.bytes,
    )?;
    if file.as_file().metadata()?.len() != asset.bytes {
        return Err("Неверный размер обновления".into());
    }
    file.seek(SeekFrom::Start(0))?;
    let mut digest = Sha256::new();
    let mut block = [0; 32768];
    loop {
        let n = file.read(&mut block)?;
        if n == 0 {
            break;
        }
        digest.update(&block[..n]);
    }
    if format!("{:x}", digest.finalize()) != asset.digest {
        return Err("SHA-256 обновления не совпадает".into());
    }
    let target = folder.join(format!("NeSpat-{}.pkg", asset.version));
    file.persist(&target)?;
    Ok(Some((asset.version, target)))
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn compare_numeric_and_reject_untrusted_feed_fields() {
        let mut release = json!({"tag_name":"v1.10.0","draft":false,"prerelease":false,"assets":[{"name":PACKAGE,"size":20,"digest":format!("sha256:{}", "a".repeat(64))}]});
        assert!(candidate(&release, "1.2.0").unwrap().is_some());
        assert!(candidate(&release, "1.10.1").unwrap().is_none());
        release["assets"][0]["size"] = json!(LIMIT + 1);
        assert!(candidate(&release, "1.1.0").is_err());
        release["tag_name"] = json!("v1/../2.0");
        assert!(candidate(&release, "1.1.0").is_err());
    }
}
