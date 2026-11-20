use crate::{
    journal::{self, nespat_journal_check, nespat_journal_read, nespat_journal_write},
    service_record::{Envelope, Record, Retry},
};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
const STATE: &str = "/Library/Application Support/NeSpatPrivileged/State";
pub(crate) struct Store {
    uid: u32,
    directory: OwnedFd,
    lock: OwnedFd,
}
pub(crate) struct Transaction<'s> {
    store: &'s Store,
    envelope: Envelope,
    payload: Vec<u8>,
}
impl Store {
    pub(crate) fn open() -> Option<Self> {
        let f = journal::open_journal(STATE, 0)?;
        Some(unsafe {
            Self {
                uid: 0,
                directory: OwnedFd::from_raw_fd(f.directory),
                lock: OwnedFd::from_raw_fd(f.lock),
            }
        })
    }
    #[cfg(test)]
    pub fn fixture(path: &std::path::Path) -> Self {
        use std::{fs::File, os::unix::fs::PermissionsExt};
        let uid = unsafe { libc::geteuid() };
        let authority = path.join("authority.json");
        if !authority.exists() {
            std::fs::write(
                &authority,
                journal::integrity(br#"{"generation":1,"version":2}"#),
            )
            .unwrap();
            std::fs::set_permissions(&authority, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let mut out = journal::JournalFiles {
            directory: -1,
            lock: -1,
        };
        let dir = File::open(path).unwrap();
        assert!(journal::nespat_open_pinned_journal(
            dir.as_raw_fd(),
            uid,
            &mut out
        ));
        unsafe {
            Self {
                uid,
                directory: OwnedFd::from_raw_fd(out.directory),
                lock: OwnedFd::from_raw_fd(out.lock),
            }
        }
    }
    fn lock_is_current(&self) -> bool {
        let dir = self.directory.as_raw_fd();
        let lock = self.lock.as_raw_fd();
        if !nespat_journal_check(dir, true, self.uid)
            || !nespat_journal_check(lock, false, self.uid)
        {
            return false;
        }
        let mut named = std::mem::MaybeUninit::uninit();
        let mut held = std::mem::MaybeUninit::uninit();
        unsafe {
            if libc::fstatat(
                dir,
                c"lock".as_ptr(),
                named.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            ) != 0
                || libc::fstat(lock, held.as_mut_ptr()) != 0
            {
                return false;
            }
            let (named, held) = (named.assume_init(), held.assume_init());
            named.st_dev == held.st_dev && named.st_ino == held.st_ino
        }
    }
    fn read(&self) -> Option<(Vec<u8>, Envelope)> {
        if !self.lock_is_current() {
            return None;
        }
        let mut b = [0u8; 8193];
        let n = unsafe {
            nespat_journal_read(
                self.directory.as_raw_fd(),
                self.uid,
                b.as_mut_ptr(),
                b.len(),
            )
        };
        let data = journal::unwrap_integrity(b.get(..usize::try_from(n).ok()?)?)?;
        let envelope = Envelope::decode(&data)?;
        Some((data, envelope))
    }
    // Exclusive borrow also prevents recursive acquisition through the same file descriptor.
    pub(crate) fn transaction<T>(
        &mut self,
        body: impl FnOnce(&mut Transaction<'_>) -> Option<T>,
    ) -> Option<T> {
        struct Lock(i32);
        impl Drop for Lock {
            fn drop(&mut self) {
                unsafe {
                    libc::flock(self.0, libc::LOCK_UN);
                }
            }
        }
        let lock = self.lock.as_raw_fd();
        if unsafe { libc::flock(lock, libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return None;
        }
        let _guard = Lock(lock);
        let (payload, envelope) = self.read()?;
        body(&mut Transaction {
            store: self,
            envelope,
            payload,
        })
    }
}
impl Transaction<'_> {
    pub fn state(&self) -> &Envelope {
        &self.envelope
    }
    pub fn ticket(&self) -> String {
        journal::digest(&self.payload)
    }
    pub fn intact(&self) -> bool {
        self.store.read().is_some_and(|(p, _)| p == self.payload)
    }
    fn save(&mut self, next: Envelope) -> Option<()> {
        if !self.intact() {
            return None;
        }
        let payload = next.encode()?;
        let data = journal::integrity(&payload);
        if !unsafe {
            nespat_journal_write(
                self.store.directory.as_raw_fd(),
                self.store.uid,
                data.as_ptr(),
                data.len(),
            )
        } {
            return None;
        }
        self.payload = payload;
        self.envelope = next;
        Some(())
    }
    pub fn replace(&mut self, record: Option<Record>) -> Option<()> {
        let mut next = self.envelope.clone();
        next.replace(record)?;
        self.save(next)
    }
    pub fn retry(&mut self, retry: Retry) -> Option<()> {
        let mut next = self.envelope.clone();
        if next.record.as_ref() != Some(&retry.record) || next.generation != retry.generation {
            return None;
        }
        next.retry = Some(retry);
        self.save(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{symlink, PermissionsExt},
    };
    #[test]
    fn malformed_missing_or_unsafe_journal_cannot_enter_a_transaction() {
        for invalid in [
            "missing",
            "empty",
            "corrupt",
            "wrong_version",
            "oversized",
            "mode",
            "hardlink",
            "symlink",
            "fifo",
            "acl",
        ] {
            let folder = tempfile::tempdir().unwrap();
            let mut store = Store::fixture(folder.path());
            let file = folder.path().join("authority.json");
            match invalid {
                "missing" => fs::remove_file(&file).unwrap(),
                "empty" => fs::write(&file, b"").unwrap(),
                "corrupt" => fs::write(&file, b"{}").unwrap(),
                "wrong_version" => fs::write(
                    &file,
                    journal::integrity(br#"{"generation":1,"version":99}"#),
                )
                .unwrap(),
                "oversized" => fs::write(&file, vec![0; 8193]).unwrap(),
                "mode" => fs::set_permissions(&file, PermissionsExt::from_mode(0o644)).unwrap(),
                "hardlink" => fs::hard_link(&file, folder.path().join("other")).unwrap(),
                "symlink" => {
                    let other = folder.path().join("actual");
                    fs::rename(&file, &other).unwrap();
                    symlink(other, &file).unwrap();
                }
                "fifo" => {
                    fs::remove_file(&file).unwrap();
                    assert!(std::process::Command::new("/usr/bin/mkfifo")
                        .arg(&file)
                        .status()
                        .unwrap()
                        .success());
                }
                "acl" => assert!(std::process::Command::new("/bin/chmod")
                    .args(["+a", "everyone allow read"])
                    .arg(&file)
                    .status()
                    .unwrap()
                    .success()),
                _ => unreachable!(),
            }
            assert!(store
                .transaction::<()>(|_| panic!("accepted {invalid}"))
                .is_none());
        }
    }
    #[test]
    fn store_rejects_changed_directory_and_lock_permissions() {
        for item in ["lock", "."] {
            let folder = tempfile::tempdir().unwrap();
            let mut store = Store::fixture(folder.path());
            fs::set_permissions(folder.path().join(item), PermissionsExt::from_mode(0o777))
                .unwrap();
            assert!(store
                .transaction::<()>(|_| panic!("writable {item}"))
                .is_none());
        }
    }
    #[test]
    fn lock_contention_and_uncommitted_changes_do_not_overwrite_state() {
        let folder = tempfile::tempdir().unwrap();
        let mut a = Store::fixture(folder.path());
        let mut b = Store::fixture(folder.path());
        let file = folder.path().join("authority.json");
        a.transaction(|t| {
            assert!(b
                .transaction::<()>(|_| panic!("parallel transaction"))
                .is_none());
            fs::write(&file, b"changed").unwrap();
            assert!(!t.intact());
            assert!(t.replace(None).is_none());
            Some(())
        })
        .unwrap();
        assert_eq!(fs::read(file).unwrap(), b"changed");
    }
    #[test]
    fn lock_must_still_be_the_named_lock_before_and_during_transaction() {
        for before in [true, false] {
            let folder = tempfile::tempdir().unwrap();
            let mut store = Store::fixture(folder.path());
            let lock = folder.path().join("lock");
            let replace = || {
                fs::rename(&lock, folder.path().join("previous")).unwrap();
                fs::write(&lock, b"").unwrap();
                fs::set_permissions(&lock, PermissionsExt::from_mode(0o600)).unwrap();
            };
            if before {
                replace();
                assert!(store.transaction::<()>(|_| panic!("stale lock")).is_none());
            } else {
                store
                    .transaction(|t| {
                        replace();
                        assert!(!t.intact());
                        assert!(t.replace(None).is_none());
                        Some(())
                    })
                    .unwrap();
            }
        }
    }
}
