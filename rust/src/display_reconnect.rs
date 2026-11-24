#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn journal_survives_reopen_and_preserves_another_monitor() {
        let dir = tempfile::tempdir().unwrap();
        let a = "874f30fc-f5e8-4f04-a572-a64880975789";
        let b = "52e1f98c-bc15-4f25-b4f3-40adad9135d8";
        let mut j = Journal::open(dir.path()).unwrap();
        assert!(Journal::open(dir.path()).is_err());
        j.remember(a, 3).unwrap();
        j.remember(b, 5).unwrap();
        drop(j);
        let mut j = Journal::open(dir.path()).unwrap();
        assert_eq!(j.pending.get(a), Some(&3));
        j.forget(a).unwrap();
        drop(j);
        let j = Journal::open(dir.path()).unwrap();
        assert_eq!(j.pending.len(), 1);
        assert_eq!(j.pending.get(b), Some(&5));
    }
    #[test]
    fn malformed_journal_does_not_grant_control() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("displays.json"), b"corrupt").unwrap();
        assert!(Journal::open(dir.path()).is_err());
    }
}

use crate::{
    display_layout::{self as native, Screens, Window},
    observation::nespat_lid_closed,
};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::{fs::OpenOptionsExt, io::AsRawFd},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

struct Journal {
    dir: PathBuf,
    _lock: File,
    pending: BTreeMap<String, u32>,
    boot: [u8; 16],
}
impl Journal {
    fn open(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(dir.join("restore.lock"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let boot = crate::host::boot().ok_or(io::ErrorKind::InvalidData)?;
        let mut pending = BTreeMap::new();
        match File::open(dir.join("displays.json")) {
            Ok(f) => {
                let (saved, entries): ([u8; 16], BTreeMap<String, u32>) =
                    serde_json::from_reader(f)?;
                if entries.len() > 128
                    || entries
                        .iter()
                        .any(|(k, v)| crate::request::uuid(k).is_none() || *v == 0)
                {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                if saved == boot {
                    pending = entries
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e),
        }
        Ok(Self {
            dir: dir.into(),
            _lock: lock,
            pending,
            boot,
        })
    }
    fn save(&mut self, next: BTreeMap<String, u32>) -> io::Result<()> {
        let mut f = tempfile::NamedTempFile::new_in(&self.dir)?;
        serde_json::to_writer(&mut f, &(self.boot, &next))?;
        f.flush()?;
        f.as_file().sync_all()?;
        f.persist(self.dir.join("displays.json"))?;
        self.pending = next;
        File::open(&self.dir)?.sync_all()
    }
    fn remember(&mut self, k: &str, id: u32) -> io::Result<()> {
        let mut n = self.pending.clone();
        n.insert(k.into(), id);
        self.save(n)
    }
    fn forget(&mut self, k: &str) -> io::Result<()> {
        let mut n = self.pending.clone();
        n.remove(k);
        self.save(n)
    }
}

struct Capture {
    screens: Screens,
    windows: Vec<Window>,
    at: Instant,
}
pub(super) struct Layout {
    journal: Journal,
    capture: Option<Capture>,
    restore_windows: BTreeMap<String, Vec<Window>>,
    next_capture: Instant,
    next_enable: Instant,
    stable: Option<(Screens, Instant)>,
    closed_key: Option<(u64, [u8; 16])>,
}
impl Layout {
    pub fn open() -> Option<Self> {
        let base = PathBuf::from(std::env::var_os("HOME")?)
            .join("Library/Application Support/local.nespat.app/DisplayRecovery");
        Some(Self {
            journal: Journal::open(&base).ok()?,
            capture: None,
            restore_windows: BTreeMap::new(),
            next_capture: Instant::now(),
            next_enable: Instant::now(),
            stable: None,
            closed_key: None,
        })
    }
    pub fn pending(&self) -> bool {
        !self.journal.pending.is_empty()
    }
    pub fn sample(&mut self, active: bool, valid: impl Fn() -> bool) {
        if !active || !native::trusted() || !native::supported() {
            self.capture = None;
            return;
        }
        if Instant::now() < self.next_capture {
            return;
        }
        self.next_capture = Instant::now() + Duration::from_secs(1);
        let Some(screens) = native::screens() else {
            return;
        };
        if screens.values().all(|s| s.builtin) {
            return;
        }
        let Some(windows) = native::snapshot(&screens) else {
            return;
        };
        if valid() && nespat_lid_closed() == 0 && native::screens().as_ref() == Some(&screens) {
            self.capture = Some(Capture {
                screens,
                windows,
                at: Instant::now(),
            });
        }
    }
    pub fn disconnect(&mut self, key: (u64, [u8; 16]), valid: impl Fn() -> bool) {
        if self.closed_key == Some(key) {
            return;
        }
        self.closed_key = Some(key);
        let Some(c) = self.capture.as_ref() else {
            return;
        };
        if c.at.elapsed() > Duration::from_secs(8) || !native::trusted() {
            return;
        }
        let Some(current) = native::screens() else {
            return;
        };
        let mut attempted = std::collections::BTreeSet::new();
        for (uuid, s) in &c.screens {
            if s.builtin
                || self.journal.pending.contains_key(uuid)
                || !current.contains_key(uuid)
                || !valid()
            {
                continue;
            }
            if self.journal.remember(uuid, s.id).is_err() {
                break;
            }
            if !valid() {
                let _ = self.journal.forget(uuid);
                break;
            }
            attempted.insert(uuid.clone());
            if !native::switch(uuid, s.id, false) {
                // If the transaction failed and the screen is still present it needs no recovery.
                if native::screens().is_some_and(|m| m.contains_key(uuid)) {
                    let _ = self.journal.forget(uuid);
                }
            }
        }
        if let Some(snapshot) = self.capture.take() {
            for w in snapshot.windows {
                if attempted.contains(&w.screen) && self.journal.pending.contains_key(&w.screen) {
                    self.restore_windows
                        .entry(w.screen.clone())
                        .or_default()
                        .push(w);
                }
            }
        }
        self.next_enable = Instant::now();
        self.stable = None;
    }
    pub fn restore(&mut self) {
        if self.closed_key.take().is_some() && !self.pending() {
            self.capture = None
        }
        if !self.pending() {
            return;
        }
        // An enable request can succeed before WindowServer has finished relayout.
        let now = Instant::now();
        let current = native::screens().unwrap_or_default();
        if now >= self.next_enable {
            for (uuid, id) in &self.journal.pending {
                if !current.contains_key(uuid) {
                    native::switch(uuid, *id, true);
                }
            }
            self.next_enable = now + Duration::from_secs(2);
        }
        match &self.stable {
            Some((saved, since))
                if *saved == current && since.elapsed() >= Duration::from_millis(800) =>
            {
                ()
            }
            Some((saved, _)) if *saved == current => return,
            _ => {
                self.stable = Some((current, now));
                return;
            }
        }
        for uuid in self.journal.pending.keys().cloned().collect::<Vec<_>>() {
            if !current.contains_key(&uuid) {
                continue;
            }
            if let Some(windows) = self.restore_windows.remove(&uuid) {
                for w in windows {
                    w.restore(&current);
                }
            }
            let _ = self.journal.forget(&uuid);
        }
        if !self.pending() {
            self.stable = None;
        }
    }
}
