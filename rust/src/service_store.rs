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
    fn read(&self) -> Option<(Vec<u8>, Envelope)> {
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
        let dir = self.directory.as_raw_fd();
        if unsafe { libc::flock(lock, libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return None;
        }
        let _guard = Lock(lock);
        if !nespat_journal_check(dir, true, self.uid)
            || !nespat_journal_check(lock, false, self.uid)
        {
            return None;
        }
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
