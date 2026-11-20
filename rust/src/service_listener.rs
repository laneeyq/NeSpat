use crate::{
    client::new_id,
    host::{nespat_snapshot, ProcessStamp},
    pulse,
    service_engine::Server,
    service_record::{Peer, Stamp},
    wire, xpc,
};
use block2::{Block, RcBlock};
use core_foundation::{
    base::TCFType,
    data::{CFData, CFDataRef},
};
use objc2::{
    define_class, msg_send, rc::Retained, runtime::ProtocolObject, AnyThread, DefinedClass,
};
use objc2_foundation::{
    NSData, NSObject, NSObjectProtocol, NSString, NSXPCConnection, NSXPCListener,
    NSXPCListenerDelegate,
};
use std::{
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};
type Shared = Arc<Mutex<Server>>;
type Reply = Block<dyn Fn(*const NSData)>;
struct ListenerState {
    server: Shared,
    #[cfg(test)]
    allow_test_executable: bool,
}
struct Dispatch {
    closed: bool,
    peer: Option<Peer>,
    epoch: Option<[u8; 16]>,
}
struct Endpoint {
    connection: usize,
    #[cfg(test)]
    allow_test_executable: bool,
    server: Shared,
    uid: u32,
    pin: String,
    boot: [u8; 16],
    id: [u8; 16],
    gate: Mutex<Dispatch>,
}
fn bytes(data: CFDataRef) -> Option<Vec<u8>> {
    (!data.is_null()).then(|| {
        unsafe { CFData::wrap_under_create_rule(data) }
            .bytes()
            .to_vec()
    })
}
fn denied_or_reply(out: Option<Vec<u8>>, callback: &Reply) {
    let data = NSData::with_bytes(
        out.as_deref()
            .unwrap_or(br#"{"error":"denied-or-unconfirmed"}"#),
    );
    callback.call((&*data,));
}
impl Endpoint {
    fn peer(&self) -> Option<Peer> {
        let c = NSXPCConnection::currentConnection()?;
        let path_uid = self.uid;
        // The anonymous XPC test runs its signed peer from Cargo's test directory.
        #[cfg(test)]
        let path_uid = if self.allow_test_executable {
            0
        } else {
            path_uid
        };
        if Retained::as_ptr(&c) as usize != self.connection
            || !xpc::nespat_xpc_current_client(&c, path_uid)
        {
            return None;
        }
        let pid = c.processIdentifier();
        let mut stamp = ProcessStamp::default();
        let audit: i32 = unsafe { msg_send![&*c, auditSessionIdentifier] };
        if audit <= 0 || nespat_snapshot(pid, &mut stamp) != 1 || stamp.uid != self.uid {
            return None;
        }
        Some(Peer {
            connection: self.id,
            uid: self.uid,
            audit: audit as u32,
            code: Some(self.pin.clone()),
            process: Some(Stamp {
                pid,
                uid: stamp.uid,
                seconds: stamp.seconds,
                micros: stamp.micros,
                boot: self.boot,
            }),
        })
    }
    fn hello(&self, data: &NSData) -> Option<Vec<u8>> {
        if data.length() > 512 {
            return None;
        }
        let mut g = self.gate.lock().ok()?;
        if g.closed || g.epoch.is_some() {
            return None;
        }
        let p = self.peer()?;
        let h = wire::read_hello(unsafe { data.as_bytes_unchecked() }, false)?;
        g.peer = Some(p);
        g.epoch = Some(h.epoch);
        bytes(wire::nespat_hello(&h, true))
    }
    fn dispatch(&self, data: &NSData) -> Option<Vec<u8>> {
        if data.length() > 8192 {
            return None;
        }
        let g = self.gate.lock().ok()?;
        let current = self.peer()?;
        if g.closed || g.peer.as_ref() != Some(&current) {
            return None;
        }
        let epoch = g.epoch?;
        let raw = bytes(wire::operation(
            unsafe { data.as_bytes_unchecked() },
            &epoch,
            true,
        )?)?;
        let request = crate::request::decode(&raw)?;
        let v = self.server.lock().ok()?.request(&current, &request)?;
        let payload = serde_json::to_vec(&v).ok()?;
        bytes(wire::reply(
            &payload,
            &wire::Correlation {
                epoch,
                id: request.id,
            },
            false,
        )?)
    }
    fn close(&self) {
        if let Ok(mut gate) = self.gate.lock() {
            if gate.closed {
                return;
            }
            gate.closed = true;
            gate.epoch = None;
            if let Some(peer) = gate.peer.take() {
                if let Ok(mut service) = self.server.lock() {
                    service.close(&peer);
                }
            }
        }
    }
}
define_class!(
    #[unsafe(super=NSObject)]
    #[ivars=Arc<Endpoint>]
    struct NeSpatServiceHandler;
    unsafe impl NSObjectProtocol for NeSpatServiceHandler {}
    impl NeSpatServiceHandler{
        #[unsafe(method(handshake:reply:))]
        fn hello(&self,data:&NSData,callback:&Reply){let e=self.ivars();let r=e.hello(data);if r.is_none(){e.close();}denied_or_reply(r,callback);}
        #[unsafe(method(request:reply:))]
        fn request(&self,data:&NSData,callback:&Reply){let e=self.ivars();let r=e.dispatch(data);if r.is_none(){e.close();}denied_or_reply(r,callback);}
    }
);
define_class!(
    #[unsafe(super=NSObject)]
    #[ivars=ListenerState]
    struct NeSpatServiceListener;
    unsafe impl NSObjectProtocol for NeSpatServiceListener {}
    unsafe impl NSXPCListenerDelegate for NeSpatServiceListener {
        #[unsafe(method(listener:shouldAcceptNewConnection:))]
        fn listener_shouldAcceptNewConnection(
            &self,
            _: &NSXPCListener,
            c: &NSXPCConnection,
        ) -> bool {
            accept(self.ivars(), c)
        }
    }
);
fn accept(state: &ListenerState, c: &NSXPCConnection) -> bool {
    let shared = &state.server;
    let Ok(s) = shared.lock() else {
        return false;
    };
    let uid = s.host.profile.uid();
    let boot = s.host.boot;
    let pin = s.host.client.clone();
    drop(s);
    let audit: i32 = unsafe { msg_send![c, auditSessionIdentifier] };
    if uid == 0 || c.effectiveUserIdentifier() != uid || audit <= 0 {
        return false;
    }
    let endpoint = Arc::new(Endpoint {
        #[cfg(test)]
        allow_test_executable: state.allow_test_executable,
        connection: c as *const _ as usize,
        server: shared.clone(),
        uid,
        pin: pin.clone(),
        boot,
        id: new_id(),
        gate: Mutex::new(Dispatch {
            closed: false,
            peer: None,
            epoch: None,
        }),
    });
    let obj = NeSpatServiceHandler::alloc().set_ivars(endpoint.clone());
    let obj: Retained<NeSpatServiceHandler> = unsafe { msg_send![super(obj), init] };
    unsafe {
        xpc::nespat_xpc_export(c, &obj, &NSString::from_str(&pin));
    }
    let close = RcBlock::new(move || endpoint.close());
    c.setInvalidationHandler(Some(&close));
    c.setInterruptionHandler(Some(&close));
    c.activate();
    true
}
pub(crate) fn run(server: Server) -> Option<i32> {
    let boot = server.host.boot;
    let setup = server.host.profile.setup;
    let epoch = server.host.epoch;
    let pin = NSString::from_str(&server.host.client);
    let server = Arc::new(Mutex::new(server));
    let target = NeSpatServiceListener::alloc().set_ivars(ListenerState {
        server: server.clone(),
        #[cfg(test)]
        allow_test_executable: false,
    });
    let target: Retained<NeSpatServiceListener> = unsafe { msg_send![super(target), init] };
    let listener = NSXPCListener::initWithMachServiceName(
        NSXPCListener::alloc(),
        &NSString::from_str("local.nespat.privilege-helper"),
    );
    listener.setConnectionCodeSigningRequirement(&pin);
    listener.setDelegate(Some(ProtocolObject::from_ref(&*target)));
    listener.activate();
    if !pulse::heartbeat(boot, setup, epoch, false) {
        listener.invalidate();
        return None;
    }
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(1));
        pulse::heartbeat(boot, setup, epoch, false);
    });
    thread::spawn(move || loop {
        objc2::rc::autoreleasepool(|_| {
            if let Ok(mut s) = server.lock() {
                s.tick();
            }
        });
        thread::sleep(Duration::from_secs(5));
    });
    extern "C" {
        fn dispatch_main() -> !;
    }
    unsafe { dispatch_main() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        profile::Profile,
        request::{nespat_encode_request, Request},
        service_recovery::Host,
        service_store::Store,
    };
    use objc2_foundation::NSError;
    use std::{ffi::CStr, ptr::NonNull, sync::mpsc};
    struct Encoding;
    unsafe impl block2::ManualBlockEncoding for Encoding {
        type Arguments = (*mut NSData,);
        type Return = ();
        const ENCODING_CSTR: &'static CStr = c"v16@?0@8";
    }
    fn exchange(conn: &NSXPCConnection, data: Vec<u8>, hello: bool) -> Option<Vec<u8>> {
        let (tx, rx) = mpsc::channel();
        let err = tx.clone();
        let obj =
            conn.remoteObjectProxyWithErrorHandler(&RcBlock::new(move |_: NonNull<NSError>| {
                let _ = err.send(None);
            }));
        let reply = RcBlock::with_encoding::<_, _, _, Encoding>(move |p: *mut NSData| {
            let v = unsafe { p.as_ref().map(|d| d.to_vec()) };
            let _ = tx.send(v);
        });
        let data = NSData::with_bytes(&data);
        unsafe {
            if hello {
                let _: () = msg_send![&*obj,handshake:&*data,reply:&*reply];
            } else {
                let _: () = msg_send![&*obj,request:&*data,reply:&*reply];
            }
        }
        rx.recv_timeout(Duration::from_secs(4))
            .expect("XPC must return a reply or a transport error")
    }
    fn channel(
        client_matches: bool,
        server_matches: bool,
        allow_test_executable: bool,
    ) -> (
        tempfile::TempDir,
        Retained<NeSpatServiceListener>,
        Retained<NSXPCListener>,
        Retained<NSXPCConnection>,
    ) {
        let path = std::env::current_exe().unwrap();
        let output = std::process::Command::new("/usr/bin/codesign")
            .args(["-dv", "--verbose=4"])
            .arg(path)
            .output()
            .unwrap();
        let notes = String::from_utf8(output.stderr).unwrap();
        let hash = notes
            .lines()
            .find_map(|s| s.strip_prefix("CDHash="))
            .unwrap();
        assert_eq!(hash.len(), 40);
        let id = notes
            .lines()
            .find_map(|s| s.strip_prefix("Identifier="))
            .unwrap();
        let requirement = |matches| {
            crate::signing::pin(
                if matches {
                    hash
                } else {
                    "0000000000000000000000000000000000000000"
                },
                id,
            )
            .unwrap()
        };
        let pin = NSString::from_str(&requirement(client_matches));
        let folder = tempfile::tempdir().unwrap();
        let uid = unsafe { libc::getuid() };
        let host = Host {
            profile: Profile::fixture(uid),
            client: requirement(client_matches),
            boot: crate::host::boot().unwrap(),
            epoch: new_id(),
            watchdog: false,
        };
        let state = Arc::new(Mutex::new(Server::new(host, Store::fixture(folder.path()))));
        let target = NeSpatServiceListener::alloc().set_ivars(ListenerState {
            server: state,
            allow_test_executable,
        });
        let target: Retained<NeSpatServiceListener> = unsafe { msg_send![super(target), init] };
        let listener = NSXPCListener::anonymousListener();
        listener.setConnectionCodeSigningRequirement(&pin);
        listener.setDelegate(Some(ProtocolObject::from_ref(&*target)));
        listener.activate();
        let endpoint = listener.endpoint();
        let conn = unsafe {
            Retained::from_raw(xpc::nespat_xpc_open(
                &NSString::from_str(&requirement(server_matches)),
                &*endpoint,
            ))
        }
        .unwrap();
        conn.activate();
        (folder, target, listener, conn)
    }
    #[test]
    fn native_xpc_rejects_each_mismatched_pin_before_any_application_reply() {
        for (client, server) in [(false, true), (true, false)] {
            let (_folder, _target, listener, conn) = channel(client, server, true);
            let hello = wire::Hello {
                epoch: new_id(),
                nonce: new_id(),
            };
            assert_eq!(
                exchange(
                    &conn,
                    bytes(wire::nespat_hello(&hello, false)).unwrap(),
                    true
                ),
                None
            );
            conn.invalidate();
            listener.invalidate();
        }
    }
    #[test]
    fn correctly_signed_copy_outside_the_installed_location_gets_no_handshake() {
        let (_folder, _target, listener, conn) = channel(true, true, false);
        let hello = wire::Hello {
            epoch: new_id(),
            nonce: new_id(),
        };
        let denial = exchange(
            &conn,
            bytes(wire::nespat_hello(&hello, false)).unwrap(),
            true,
        );
        assert_eq!(
            denial.as_deref(),
            Some(br#"{"error":"denied-or-unconfirmed"}"#.as_slice())
        );
        conn.invalidate();
        listener.invalidate();
    }
    #[test]
    fn operations_before_hello_duplicate_hello_and_wrong_epoch_close_the_channel() {
        for invalid in ["before", "duplicate", "epoch"] {
            let (_folder, _target, listener, conn) = channel(true, true, true);
            let h = wire::Hello {
                epoch: new_id(),
                nonce: new_id(),
            };
            let hello = || bytes(wire::nespat_hello(&h, false)).unwrap();
            if invalid != "before" {
                assert!(wire::read_hello(&exchange(&conn, hello(), true).unwrap(), true).is_some());
            }
            let q = Request {
                id: new_id(),
                operation: 0,
                ..Default::default()
            };
            let raw = bytes(nespat_encode_request(&q)).unwrap();
            let epoch = if invalid == "epoch" {
                new_id()
            } else {
                h.epoch
            };
            let denied = if invalid == "duplicate" {
                exchange(&conn, hello(), true)
            } else {
                exchange(
                    &conn,
                    bytes(wire::operation(&raw, &epoch, false).unwrap()).unwrap(),
                    false,
                )
            };
            let expected = Some(br#"{"error":"denied-or-unconfirmed"}"#.as_slice());
            assert_eq!(denied.as_deref(), expected);
            assert_eq!(exchange(&conn, hello(), true).as_deref(), expected);
            conn.invalidate();
            listener.invalidate();
        }
    }
    #[test]
    fn native_listener_serves_correlated_status_on_kernel_authenticated_local_channel() {
        let (_folder, _target, listener, conn) = channel(true, true, true);
        let h = wire::Hello {
            epoch: new_id(),
            nonce: new_id(),
        };
        let hello = exchange(&conn, bytes(wire::nespat_hello(&h, false)).unwrap(), true).unwrap();
        let got = wire::read_hello(&hello, true).expect("authenticated native handshake");
        assert_eq!((got.epoch, got.nonce), (h.epoch, h.nonce));
        let q = Request {
            id: new_id(),
            operation: 0,
            ..Default::default()
        };
        let body = bytes(nespat_encode_request(&q)).unwrap();
        let envelope = bytes(wire::operation(&body, &h.epoch, false).unwrap()).unwrap();
        let reply = exchange(&conn, envelope.clone(), false).unwrap();
        let key = wire::Correlation {
            epoch: h.epoch,
            id: q.id,
        };
        let data =
            bytes(wire::reply(&reply, &key, true).expect("status reply matched epoch and request"))
                .unwrap();
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["state"], "enabled");
        assert_eq!(v["fullAuthority"], true);
        let repeat = exchange(&conn, envelope, false).unwrap();
        assert!(wire::reply(&repeat, &key, true).is_none());
        conn.invalidate();
        listener.invalidate();
    }
}
