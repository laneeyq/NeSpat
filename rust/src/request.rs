use crate::policy::nespat_minutes_to_seconds;
use core_foundation::{
    base::TCFType,
    data::{CFData, CFDataRef},
};
use serde_json::{json, Value};
use std::{mem::ManuallyDrop, slice};

const OPERATIONS: [&str; 8] = [
    "status",
    "begin",
    "changeDeadline",
    "end",
    "recover",
    "revoke",
    "heartbeat",
    "pollRecovery",
];

#[repr(C)]
#[derive(Default)]
pub struct Request {
    pub(crate) id: [u8; 16],
    pub(crate) session: [u8; 16],
    pub(crate) minutes: i64,
    pub(crate) sequence: i64,
    pub(crate) operation: u8,
    pub(crate) has_session: bool,
    pub(crate) has_minutes: bool,
    pub(crate) has_sequence: bool,
}

#[no_mangle]
pub extern "C" fn nespat_valid_request(r: &Request) -> bool {
    let valid_args = match r.operation {
        0 | 5 => !r.has_session && !r.has_minutes,
        1 => !r.has_session,
        2 => r.has_session,
        3 | 4 | 6 | 7 => r.has_session && !r.has_minutes,
        _ => false,
    };
    valid_args
        && (!r.has_minutes || nespat_minutes_to_seconds(r.minutes) > 0)
        && (!r.has_sequence || (r.operation == 6 && r.sequence > 0))
}

pub(crate) fn uuid(text: &str) -> Option<[u8; 16]> {
    let bytes = text.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    let mut id = [0; 16];
    let mut index = 0;
    for (i, octet) in id.iter_mut().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            if bytes[index] != b'-' {
                return None;
            }
            index += 1;
        }
        let hex = |b: u8| (b as char).to_digit(16).map(|n| n as u8);
        *octet = (hex(bytes[index])? << 4) | hex(bytes[index + 1])?;
        index += 2;
    }
    Some(id)
}
pub(crate) fn uuid_text(id: &[u8; 16]) -> String {
    use std::fmt::Write;
    let mut text = String::with_capacity(36);
    for (i, b) in id.iter().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            text.push('-');
        }
        write!(text, "{b:02X}").unwrap();
    }
    text
}
pub(crate) fn decode(bytes: &[u8]) -> Option<Request> {
    if bytes.len() > 4096 {
        return None;
    }
    let object = serde_json::from_slice::<Value>(bytes).ok()?;
    let f = object.as_object()?;
    // Valid request values are restricted to ASCII identifiers and integers.
    // Canonical byte equality additionally enforces order and unique keys.
    if serde_json::to_vec(&object).ok()? != bytes
        || f.get("version").and_then(Value::as_i64) != Some(1)
    {
        return None;
    }
    if f.keys().any(|k| {
        !matches!(
            k.as_str(),
            "version" | "id" | "operation" | "session" | "minutes" | "heartbeatSequence"
        )
    }) {
        return None;
    }
    let operation = OPERATIONS
        .iter()
        .position(|s| Some(*s) == f.get("operation").and_then(Value::as_str))?
        as u8;
    let mut r = Request {
        id: uuid(f.get("id")?.as_str()?)?,
        operation,
        ..Request::default()
    };
    if let Some(s) = f.get("session") {
        r.session = uuid(s.as_str()?)?;
        r.has_session = true;
    }
    if let Some(n) = f.get("minutes") {
        r.minutes = n.as_i64()?;
        r.has_minutes = true;
    }
    if let Some(n) = f.get("heartbeatSequence") {
        r.sequence = n.as_i64()?;
        r.has_sequence = true;
    }
    nespat_valid_request(&r).then_some(r)
}
#[no_mangle]
pub unsafe extern "C" fn nespat_decode_request(
    bytes: *const u8,
    len: usize,
    out: &mut Request,
) -> bool {
    if bytes.is_null() || len > 4096 {
        return false;
    }
    let Some(r) = decode(slice::from_raw_parts(bytes, len)) else {
        return false;
    };
    *out = r;
    true
}
#[no_mangle]
pub extern "C" fn nespat_encode_request(r: &Request) -> CFDataRef {
    if !nespat_valid_request(r) {
        return std::ptr::null();
    }
    let mut object =
        json!({"id":uuid_text(&r.id),"operation":OPERATIONS[r.operation as usize],"version":1});
    if r.has_session {
        object["session"] = json!(uuid_text(&r.session));
    }
    if r.has_minutes {
        object["minutes"] = r.minutes.into();
    }
    if r.has_sequence {
        object["heartbeatSequence"] = r.sequence.into();
    }
    let bytes = object.to_string();
    ManuallyDrop::new(CFData::from_buffer(bytes.as_bytes())).as_concrete_TypeRef()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_or_incomplete_input_fails_closed() {
        for data in [
            b"{}".as_slice(),
            br#"{"version":1}"#,
            br#"{"version":true}"#,
            br#"{"version":1,"version":1}"#,
        ] {
            assert!(decode(data).is_none());
        }
    }
    #[test]
    fn uuid_spelling_roundtrips() {
        let text = "23C175F2-A417-4E75-A540-28E9CA16CCAB";
        assert_eq!(uuid_text(&uuid(&text.to_lowercase()).unwrap()), text);
    }
}

#[cfg(test)]
mod regression {
    use super::*;
    #[test]
    fn every_operation_has_only_its_version_one_argument_shapes() {
        for op in 0..=8 {
            for session in [false, true] {
                for minutes in [false, true] {
                    for sequence in [false, true] {
                        let r = Request {
                            id: [1; 16],
                            session: [2; 16],
                            operation: op,
                            has_session: session,
                            has_minutes: minutes,
                            minutes: 60,
                            has_sequence: sequence,
                            sequence: 1,
                        };
                        let valid = match op {
                            0 | 5 => !session && !minutes,
                            1 => !session,
                            2 => session,
                            3 | 4 | 6 | 7 => session && !minutes,
                            _ => false,
                        } && (!sequence || op == 6);
                        assert_eq!(nespat_valid_request(&r), valid);
                        let encoded = nespat_encode_request(&r);
                        if !valid {
                            assert!(encoded.is_null());
                            continue;
                        }
                        let encoded = unsafe { CFData::wrap_under_create_rule(encoded) };
                        let parsed = decode(encoded.bytes()).unwrap();
                        assert_eq!(parsed.operation, r.operation);
                        assert_eq!(parsed.has_minutes, minutes);
                        assert_eq!(parsed.has_sequence, sequence);
                        assert_eq!(parsed.id, r.id);
                        if session {
                            assert_eq!(parsed.session, r.session);
                        }
                    }
                }
            }
        }
    }
    #[test]
    fn unknown_fields_identity_claims_and_malformed_numbers_are_rejected() {
        let q = json!({"id":uuid_text(&[1;16]),"operation":"begin","version":1});
        for field in [
            "command",
            "path",
            "arguments",
            "uid",
            "pid",
            "auditSession",
            "codeIdentity",
            "timeout",
            "expires",
            "bootID",
        ] {
            let mut value = q.clone();
            value[field] = json!(1);
            assert!(decode(&serde_json::to_vec(&value).unwrap()).is_none());
        }
        for v in [
            json!(0),
            json!(-1),
            json!(1.5),
            json!(false),
            json!("60"),
            Value::Null,
            json!(i64::MAX),
        ] {
            let mut value = q.clone();
            value["minutes"] = v;
            assert!(decode(&serde_json::to_vec(&value).unwrap()).is_none());
        }
        assert!(decode(&vec![b' '; 4097]).is_none());
    }
}
