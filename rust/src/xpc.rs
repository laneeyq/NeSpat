use objc2::{msg_send, rc::Retained};
use objc2_foundation::{NSString, NSXPCConnection, NSXPCListener};
use std::{ffi::CStr, ptr};

// Both arguments are live Foundation objects retained by the calling host.
// Signing requirements are built and parsed before a connection is configured.
#[no_mangle]
pub unsafe extern "C" fn nespat_xpc_pin(connection: &NSXPCConnection, requirement: &NSString) {
    connection.setCodeSigningRequirement(requirement);
}
#[no_mangle]
pub unsafe extern "C" fn nespat_xpc_listener_pin(listener: &NSXPCListener, requirement: &NSString) {
    listener.setConnectionCodeSigningRequirement(requirement);
}
#[no_mangle]
pub extern "C" fn nespat_xpc_root_reply(connection: &NSXPCConnection) -> bool {
    connection.processIdentifier() > 0 && connection.effectiveUserIdentifier() == 0
}
fn installed_gui(pid: i32) -> bool {
    let mut path = [0i8; 4096];
    let count = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if count <= 0 || count as usize >= path.len() {
        return false;
    }
    let bytes = unsafe { std::slice::from_raw_parts(path.as_ptr().cast::<u8>(), path.len()) };
    CStr::from_bytes_until_nul(bytes).is_ok_and(|p| {
        p == c"/Library/Application Support/NeSpatPrivileged/NeSpat.app/Contents/MacOS/NeSpat"
    })
}
// Only callable inside dispatch. Read credentials from the connection on this
// thread, never from the request. uid=0 means the listener has no fixed user.
#[no_mangle]
pub extern "C" fn nespat_xpc_current_client(connection: &NSXPCConnection, uid: u32) -> bool {
    let Some(current) = NSXPCConnection::currentConnection() else {
        return false;
    };
    if !ptr::eq(Retained::as_ptr(&current), connection) {
        return false;
    }
    let pid = connection.processIdentifier();
    let euid = connection.effectiveUserIdentifier();
    let session: i32 = unsafe { msg_send![connection, auditSessionIdentifier] };
    pid > 0 && euid != 0 && session > 0 && (uid == 0 || (uid == euid && installed_gui(pid)))
}

use block2::{Block, ManualBlockEncoding, RcBlock};
use objc2::AnyThread;
use objc2_foundation::{
    NSData, NSError, NSXPCConnectionOptions, NSXPCInterface, NSXPCListenerEndpoint,
};
use std::ptr::NonNull;

#[no_mangle]
pub unsafe extern "C" fn nespat_xpc_open(
    requirement: &NSString,
    endpoint: *const NSXPCListenerEndpoint,
) -> *mut NSXPCConnection {
    let conn = if let Some(endpoint) = endpoint.as_ref() {
        NSXPCConnection::initWithListenerEndpoint(NSXPCConnection::alloc(), endpoint)
    } else {
        NSXPCConnection::initWithMachServiceName_options(
            NSXPCConnection::alloc(),
            &NSString::from_str("local.nespat.privilege-helper"),
            NSXPCConnectionOptions::Privileged,
        )
    };
    conn.setCodeSigningRequirement(requirement);
    conn.setRemoteObjectInterface(Some(&service_interface()));
    Retained::into_raw(conn)
}
struct DataBlockEncoding;
unsafe impl ManualBlockEncoding for DataBlockEncoding {
    type Arguments = (*mut NSData,);
    type Return = ();
    const ENCODING_CSTR: &'static CStr = c"v16@?0@8";
}
type ExchangeCompletion = Block<dyn Fn(*const NSData, i32, u32, u8)>;
#[no_mangle]
pub unsafe extern "C" fn nespat_xpc_exchange(
    connection: &NSXPCConnection,
    data: &NSData,
    hello: bool,
    completion: &ExchangeCompletion,
) {
    let on_error = completion.copy();
    let proxy =
        connection.remoteObjectProxyWithErrorHandler(&RcBlock::new(move |_: NonNull<NSError>| {
            on_error.call((ptr::null(), 0, 0, 1));
        }));
    let Some(conn) = Retained::retain(connection as *const _ as *mut NSXPCConnection) else {
        return;
    };
    let received = completion.copy();
    let callback =
        RcBlock::with_encoding::<_, _, _, DataBlockEncoding>(move |bytes: *mut NSData| {
            let pid = conn.processIdentifier();
            let uid = conn.effectiveUserIdentifier();
            if pid <= 0 || uid != 0 {
                conn.invalidate();
                received.call((ptr::null(), 0, 0, 2));
            } else if bytes.is_null() {
                received.call((ptr::null(), 0, 0, 1));
            } else {
                received.call((bytes, pid, uid, 0));
            }
        });
    if hello {
        let _: () = msg_send![&*proxy,handshake:data,reply:&*callback];
    } else {
        let _: () = msg_send![&*proxy,request:data,reply:&*callback];
    }
}

fn service_interface() -> Retained<NSXPCInterface> {
    use objc2::runtime::AnyProtocol;
    extern "C" {
        #[link_name = "OBJC_CLASS_$_NeSpatWireSchema"]
        static SCHEMA: std::ffi::c_void;
    }
    // The reference pulls the metadata-only object from the static archive.
    std::hint::black_box(std::ptr::addr_of!(SCHEMA));
    let schema = AnyProtocol::get(c"NeSpatServiceWireV1").expect("Linked service protocol");
    unsafe { NSXPCInterface::interfaceWithProtocol(schema) }
}

#[no_mangle]
pub unsafe extern "C" fn nespat_xpc_export(
    connection: &NSXPCConnection,
    endpoint: &objc2::runtime::AnyObject,
    requirement: &NSString,
) {
    connection.setCodeSigningRequirement(requirement);
    connection.setExportedInterface(Some(&service_interface()));
    connection.setExportedObject(Some(endpoint));
}
