// Serial client used on the application's background worker. XPC callbacks never
// wait for the worker and no timeout can reuse the failed connection.
use crate::{
    profile::Profile,
    request::{nespat_encode_request, Request},
    signing::nespat_matches_code,
    wire::{self, Correlation, Hello},
    xpc::{nespat_xpc_exchange, nespat_xpc_open},
};
use block2::RcBlock;
use core_foundation::{base::TCFType, data::CFData, string::CFString, url::CFURL};
use objc2::rc::Retained;
use objc2_foundation::{NSBundle, NSData, NSString, NSXPCConnection};
use std::{
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::{Duration, Instant},
};

pub(crate) fn new_id() -> [u8; 16] {
    let mut id = [0u8; 16];
    unsafe { libc::arc4random_buf(id.as_mut_ptr().cast(), id.len()) };
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    id
}
pub struct Client {
    conn: Retained<NSXPCConnection>,
    broken: Arc<AtomicBool>,
    epoch: [u8; 16],
    state: crate::transport::Transport,
}
impl Drop for Client {
    fn drop(&mut self) {
        self.conn.invalidate();
    }
}
impl Client {
    pub fn connect() -> Option<Self> {
        let (gui, helper) = Profile::load()?.client_requirements()?;
        let app = CFURL::from_path(NSBundle::mainBundle().bundlePath().to_string(), true)?;
        if !nespat_matches_code(
            app.as_concrete_TypeRef(),
            CFString::new(&gui).as_concrete_TypeRef(),
            true,
        ) {
            return None;
        }
        let conn = unsafe {
            Retained::from_raw(nespat_xpc_open(&NSString::from_str(&helper), ptr::null()))?
        };
        let broken = Arc::new(AtomicBool::new(false));
        let flag = broken.clone();
        let stop = RcBlock::new(move || flag.store(true, Ordering::Release));
        conn.setInterruptionHandler(Some(&stop));
        conn.setInvalidationHandler(Some(&stop));
        conn.activate();
        let hello = Hello {
            epoch: new_id(),
            nonce: new_id(),
        };
        let bytes = unsafe { CFData::wrap_under_create_rule(wire::nespat_hello(&hello, false)) };
        let mut client = Self {
            conn,
            broken,
            epoch: hello.epoch,
            state: Default::default(),
        };
        if !crate::transport::nespat_transport_start(&mut client.state) {
            return None;
        }
        let (response, pid) = client.exchange(bytes.bytes(), true)?;
        let checked = wire::read_hello(&response, true)?;
        if checked.epoch != hello.epoch || checked.nonce != hello.nonce {
            return None;
        }
        if !crate::transport::nespat_transport_verify(&mut client.state, pid, 0) {
            return None;
        }
        Some(client)
    }
    fn exchange(&self, bytes: &[u8], hello: bool) -> Option<(Vec<u8>, i32)> {
        if self.broken.load(Ordering::Acquire) {
            return None;
        }
        let (tx, rx) = mpsc::sync_channel(1);
        let broken = self.broken.clone();
        let deadline = Instant::now() + Duration::from_secs(10);
        let received = AtomicBool::new(false);
        let completion = RcBlock::new(move |data: *const NSData, pid: i32, uid: u32, error: u8| {
            if received.swap(true, Ordering::AcqRel) {
                broken.store(true, Ordering::Release);
                return;
            }
            let reply = unsafe { data.as_ref() }
                .filter(|d| error == 0 && uid == 0 && pid > 0 && d.length() <= 8192)
                .map(|d| (d.to_vec(), pid));
            let _ = tx.try_send(reply);
        });
        unsafe {
            nespat_xpc_exchange(&self.conn, &NSData::with_bytes(bytes), hello, &completion);
        }
        let reply = rx
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .ok()??;
        (Instant::now() < deadline
            && !self.broken.load(Ordering::Acquire)
            && (hello || crate::transport::nespat_transport_peer(&self.state, reply.1, 0)))
        .then_some(reply)
    }
    pub(crate) fn request(&mut self, r: &Request) -> Option<Vec<u8>> {
        let result = self.send(r);
        if result.is_none() {
            self.broken.store(true, Ordering::Release);
            self.conn.invalidate();
        }
        result
    }
    fn send(&mut self, r: &Request) -> Option<Vec<u8>> {
        if !crate::transport::nespat_transport_reserve(
            &mut self.state,
            &r.id,
            r.has_sequence,
            r.sequence,
        ) {
            return None;
        }
        let raw = nespat_encode_request(r);
        if raw.is_null() {
            return None;
        }
        let bytes = unsafe { CFData::wrap_under_create_rule(raw) };
        let wrapped = unsafe {
            CFData::wrap_under_create_rule(wire::operation(bytes.bytes(), &self.epoch, false)?)
        };
        let (reply, _) = self.exchange(wrapped.bytes(), false)?;
        let key = Correlation {
            epoch: self.epoch,
            id: r.id,
        };
        let payload = unsafe { CFData::wrap_under_create_rule(wire::reply(&reply, &key, true)?) };
        Some(payload.bytes().to_vec())
    }
}
#[no_mangle]
pub extern "C" fn nespat_verify_service() -> bool {
    Client::connect().is_some()
}
