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
