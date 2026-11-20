use crate::request::{decode, uuid, uuid_text};
use core_foundation::{
    base::TCFType,
    data::{CFData, CFDataRef},
};
use serde_json::{json, Value};
use std::{mem::ManuallyDrop, ptr};

#[repr(C)]
pub struct Hello {
    pub(crate) epoch: [u8; 16],
    pub(crate) nonce: [u8; 16],
}

fn data(value: &Value) -> CFDataRef {
    ManuallyDrop::new(CFData::from_buffer(value.to_string().as_bytes())).as_concrete_TypeRef()
}

fn canonical(bytes: &[u8], limit: usize) -> Option<Value> {
    if bytes.len() > limit {
        return None;
    }
    let v: Value = serde_json::from_slice(bytes).ok()?;
    (v.is_object() && serde_json::to_vec(&v).ok()? == bytes).then_some(v)
}
fn kind(response: bool) -> &'static str {
    if response {
        "helloReply"
    } else {
        "hello"
    }
}

#[no_mangle]
pub extern "C" fn nespat_hello(h: &Hello, response: bool) -> CFDataRef {
    data(
        &json!({"version":1,"kind":kind(response),"epoch":uuid_text(&h.epoch),"nonce":uuid_text(&h.nonce)}),
    )
}

pub(crate) fn read_hello(bytes: &[u8], response: bool) -> Option<Hello> {
    let obj = canonical(bytes, 512)?;
    let fields = obj.as_object()?;
    if fields.len() != 4 || obj["version"].as_i64() != Some(1) || obj["kind"] != kind(response) {
        return None;
    }
    Some(Hello {
        epoch: uuid(obj["epoch"].as_str()?)?,
        nonce: uuid(obj["nonce"].as_str()?)?,
    })
}

#[no_mangle]
pub unsafe extern "C" fn nespat_read_hello(
    bytes: CFDataRef,
    response: bool,
    out: &mut Hello,
) -> bool {
    let bytes = CFData::wrap_under_get_rule(bytes);
    let Some(value) = read_hello(bytes.bytes(), response) else {
        return false;
    };
    *out = value;
    true
}

pub(crate) fn operation(bytes: &[u8], epoch: &[u8; 16], unwrap: bool) -> Option<CFDataRef> {
    if unwrap {
        let obj = canonical(bytes, 8192)?;
        if obj.as_object()?.len() != 3
            || obj["version"].as_i64() != Some(1)
            || obj["epoch"] != uuid_text(epoch)
        {
            return None;
        }
        let request = obj.get("request")?;
        decode(&serde_json::to_vec(request).ok()?)?;
        Some(data(request))
    } else {
        decode(bytes)?;
        let request: Value = serde_json::from_slice(bytes).ok()?;
        Some(data(
            &json!({"epoch":uuid_text(epoch),"version":1,"request":request}),
        ))
    }
}

#[no_mangle]
pub unsafe extern "C" fn nespat_operation(
    bytes: CFDataRef,
    epoch: &[u8; 16],
    unwrap: bool,
) -> CFDataRef {
    operation(CFData::wrap_under_get_rule(bytes).bytes(), epoch, unwrap).unwrap_or(ptr::null())
}

#[repr(C)]
pub struct Correlation {
    pub(crate) epoch: [u8; 16],
    pub(crate) id: [u8; 16],
}

// Foundation specifies the historical representation of floating point dates.
fn foundation_json(bytes: &[u8]) -> Option<Vec<u8>> {
    use objc2_foundation::{
        NSData, NSJSONReadingOptions, NSJSONSerialization, NSJSONWritingOptions,
    };
    let value = NSJSONSerialization::JSONObjectWithData_options_error(
        &NSData::with_bytes(bytes),
        NSJSONReadingOptions::empty(),
    )
    .ok()?;
    // value was created by this same JSON serializer with fragments disabled.
    unsafe {
        NSJSONSerialization::dataWithJSONObject_options_error(
            &value,
            NSJSONWritingOptions::SortedKeys,
        )
    }
    .ok()
    .map(|d| d.to_vec())
}
fn valid_payload(obj: &Value) -> Option<()> {
    let fields = obj.as_object()?;
    if !matches!(obj["state"].as_str()?, "enabled" | "disabled" | "unknown") {
        return None;
    }
    let has_session = fields.contains_key("session");
    for (name, value) in fields {
        let ok = match name.as_str() {
            "state" => true,
            "session" => uuid(value.as_str()?).is_some(),
            "deadline" => has_session && value.as_f64()?.abs() <= 9_007_199_254_740_992.0,
            "authorityExpires" => {
                has_session && value.as_f64()?.is_finite() && value.as_f64()? >= 0.0
            }
            "active" | "fullAuthority" | "selectedLifetime" => value.is_boolean(),
            "recoveryTicket" => {
                has_session
                    && value.as_str()?.len() == 64
                    && value
                        .as_str()?
                        .bytes()
                        .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
            }
            _ => false,
        };
        if !ok {
            return None;
        }
    }
    Some(())
}
pub(crate) fn reply(bytes: &[u8], key: &Correlation, unwrap: bool) -> Option<CFDataRef> {
    if bytes.len() > if unwrap { 8192 } else { 4096 } {
        return None;
    }
    let canonical = foundation_json(bytes)?;
    let epoch = uuid_text(&key.epoch);
    let id = uuid_text(&key.id);
    let obj: Value = serde_json::from_slice(&canonical).ok()?;
    obj.as_object()?;
    if unwrap {
        if canonical != bytes
            || obj.as_object()?.len() != 4
            || obj["version"].as_i64() != Some(1)
            || obj["epoch"] != epoch
            || obj["id"] != id
        {
            return None;
        }
        valid_payload(&obj["payload"])?;
        // Preserve Foundation's precision when extracting the original payload.
        let prefix = format!(r#"{{"epoch":"{epoch}","id":"{id}","payload":"#);
        let payload = bytes
            .strip_prefix(prefix.as_bytes())?
            .strip_suffix(br#","version":1}"#)?;
        Some(ManuallyDrop::new(CFData::from_buffer(payload)).as_concrete_TypeRef())
    } else {
        let mut out = format!(r#"{{"epoch":"{epoch}","id":"{id}","payload":"#).into_bytes();
        out.extend(canonical);
        out.extend(br#","version":1}"#);
        Some(ManuallyDrop::new(CFData::from_buffer(&out)).as_concrete_TypeRef())
    }
}
#[no_mangle]
pub unsafe extern "C" fn nespat_reply(
    bytes: CFDataRef,
    key: &Correlation,
    unwrap: bool,
) -> CFDataRef {
    reply(CFData::wrap_under_get_rule(bytes).bytes(), key, unwrap).unwrap_or(ptr::null())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foundation_dates_survive_roundtrip_without_reformatting() {
        let key = Correlation {
            epoch: [0; 16],
            id: [1; 16],
        };
        for date in [
            "12.125",
            "0.000000013",
            "9007199254740992",
            "543210987.9876543",
        ] {
            let bytes = format!(
                r#"{{"session":"{}","state":"enabled","deadline":{date}}}"#,
                uuid_text(&[2; 16])
            );
            let canonical = foundation_json(bytes.as_bytes()).unwrap();
            let envelope = unsafe {
                CFData::wrap_under_create_rule(reply(bytes.as_bytes(), &key, false).unwrap())
            };
            let payload = unsafe {
                CFData::wrap_under_create_rule(reply(envelope.bytes(), &key, true).unwrap())
            };
            assert_eq!(canonical, payload.bytes());
            let other = Correlation {
                epoch: key.epoch,
                id: [3; 16],
            };
            assert!(reply(envelope.bytes(), &other, true).is_none());
        }
    }
    #[test]
    fn field_types_and_request_context_are_required() {
        for value in [
            json!({"state":"enabled","active":1}),
            json!({"state":"disabled","deadline":0}),
            json!({"state":"unknown","recoveryTicket":"0".repeat(64)}),
            json!({"state":"unknown","session":uuid_text(&[1;16]),"authorityExpires":-1}),
            json!({"state":"enabled","other":false}),
        ] {
            assert!(valid_payload(&value).is_none());
        }
    }
}
