// Typed disk format shared by helper and watchdog. Optional fields are absent on
// disk. Unknown fields are rejected to avoid silently dropping ownership evidence.
use crate::request::{uuid, uuid_text};
use serde_json::{json, Map, Value};
type Id = [u8; 16];

trait Field: Sized {
    fn get(v: &Value) -> Option<Self>;
    fn put(&self) -> Value;
}
macro_rules! scalar {
    ($t:ty,$get:ident) => {
        impl Field for $t {
            fn get(v: &Value) -> Option<Self> {
                v.$get()?.try_into().ok()
            }
            fn put(&self) -> Value {
                json!(self)
            }
        }
    };
}
scalar!(u64, as_u64);
scalar!(u32, as_u64);
scalar!(i32, as_i64);
impl Field for String {
    fn get(v: &Value) -> Option<Self> {
        v.as_str().map(str::to_owned)
    }
    fn put(&self) -> Value {
        json!(self)
    }
}
impl Field for bool {
    fn get(v: &Value) -> Option<Self> {
        v.as_bool()
    }
    fn put(&self) -> Value {
        json!(self)
    }
}
impl Field for f64 {
    fn get(v: &Value) -> Option<Self> {
        v.as_f64().filter(|n| n.is_finite())
    }
    fn put(&self) -> Value {
        json!(self)
    }
}
impl Field for Id {
    fn get(v: &Value) -> Option<Self> {
        uuid(v.as_str()?)
    }
    fn put(&self) -> Value {
        json!(uuid_text(self))
    }
}
macro_rules! document {
    ($name:ident { $($req:ident : $rt:ty => $rk:literal),* } { $($opt:ident : $ot:ty => $ok:literal),* })=>{
        #[derive(Clone,Debug,PartialEq)]pub(crate) struct $name {$(pub $req:$rt,)* $(pub $opt:Option<$ot>,)*}
        impl Field for $name{
            fn get(v:&Value)->Option<Self>{
                let fields=v.as_object()?;
                if fields.keys().any(|k|!matches!(k.as_str(),$($rk)|* $(| $ok)*)){return None;}
                Some(Self{$($req:<$rt>::get(fields.get($rk)?)?,)* $($opt:match fields.get($ok){None=>None,Some(val)=>Some(<$ot>::get(val)?)},)*})
            }
            fn put(&self)->Value{let mut m=Map::new();$(m.insert($rk.into(),self.$req.put());)* $(if let Some(v)=&self.$opt{m.insert($ok.into(),v.put());})* Value::Object(m)}
        }
    };
}
document!(Stamp {pid:i32=>"pid",uid:u32=>"uid",seconds:u64=>"startSeconds",micros:u64=>"startMicroseconds",boot:Id=>"bootID"} {});
document!(Peer {connection:Id=>"connection",uid:u32=>"uid",audit:u32=>"auditSession"}{code:String=>"codeIdentity",process:Stamp=>"process"});
document!(Attempt {setup:Id=>"setup",session:Id=>"session",epoch:Id=>"helperEpoch",owner:Peer=>"owner",boot:Id=>"boot",on_ac:bool=>"startedOnAC",issued:f64=>"issued",nonce:Id=>"nonce"}{expires:f64=>"expires",deadline:f64=>"deadline",selected:bool=>"selectedLifetime",unlimited:bool=>"unlimited"});
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Phase {
    Pending,
    Active,
}
impl Field for Phase {
    fn get(v: &Value) -> Option<Self> {
        match v.as_str()? {
            "pending" => Some(Self::Pending),
            "active" => Some(Self::Active),
            _ => None,
        }
    }
    fn put(&self) -> Value {
        json!(match self {
            Self::Pending => "pending",
            Self::Active => "active",
        })
    }
}
document!(Record {id:Id=>"id",owner:Peer=>"owner",boot:Id=>"bootID",baseline:bool=>"baselineEnabled",phase:Phase=>"phase"}{reservation:Id=>"exclusiveReservation",attempt:Attempt=>"exclusiveAttempt",interference:bool=>"interference",deadline:f64=>"deadline",expires:f64=>"authorityExpires"});
document!(Retry {record:Record=>"record",generation:u64=>"generation",nonce:Id=>"nonce",since:f64=>"since",last:f64=>"last",emergency:bool=>"emergency",clock_fault:bool=>"clockFault"}{failures:u64=>"failures"});
document!(Envelope {version:u32=>"version",generation:u64=>"generation"}{record:Record=>"record",retry:Retry=>"retry",completed:Id=>"lastCompleted"});
impl Peer {
    pub fn valid(&self) -> bool {
        self.uid != 0
            && self.audit != 0
            && self
                .code
                .as_ref()
                .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
            && self.process.as_ref().is_none_or(|p| {
                p.pid > 0 && p.uid == self.uid && p.seconds > 0 && p.micros < 1_000_000
            })
    }
    pub fn same_owner(&self, peer: &Peer) -> bool {
        self.valid()
            && peer.valid()
            && self.uid == peer.uid
            && self.audit == peer.audit
            && self.code == peer.code
    }
}
impl Record {
    pub fn owns(&self, boot: Id) -> bool {
        self.boot == boot
            && self.baseline
            && self.owner.valid()
            && self.owner.process.as_ref().is_none_or(|p| p.boot == boot)
    }
    pub fn timer_valid(&self) -> bool {
        self.expires.is_none_or(|e| e.is_finite() && e >= 0.)
            && self.deadline.is_none_or(|d| d.abs() <= (1u64 << 53) as f64)
    }
    pub fn proof(
        &self,
        setup: Id,
        uid: u32,
        client: &str,
        selected: bool,
        maximum: f64,
    ) -> Option<&Attempt> {
        let a = self.attempt.as_ref()?;
        if !self.owns(self.boot)
            || self.reservation != Some(setup)
            || a.setup != setup
            || a.session != self.id
            || a.owner != self.owner
            || self.owner.process.is_none()
            || self.owner.uid != uid
            || self.owner.code.as_deref() != Some(client)
            || a.boot != self.boot
            || !a.issued.is_finite()
            || a.issued < 0.
            || a.expires != self.expires
            || a.deadline != self.deadline
            || self.interference == Some(true)
            || !self.timer_valid()
        {
            return None;
        }
        let scoped = a.selected == Some(true);
        if scoped && !selected {
            return None;
        }
        if a.unlimited == Some(true) {
            if !scoped || a.expires.is_some() || a.deadline.is_some() {
                return None;
            }
        } else {
            let e = a.expires?;
            if a.deadline.is_none() || e <= a.issued || (!scoped && e - a.issued > maximum) {
                return None;
            }
        }
        Some(a)
    }
}
// Historical JSONEncoder journal tickets hash the exact UTF-8 spelling, including
// the sign and two exponent digits. Keep this separate from XPC's JSONSerialization format.
fn encode_disk(value: &Value, out: &mut Vec<u8>) -> Option<()> {
    match value {
        Value::Object(map) => {
            out.push(b'{');
            for (i, (k, v)) in map.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                serde_json::to_writer(&mut *out, k).ok()?;
                out.push(b':');
                encode_disk(v, out)?;
            }
            out.push(b'}');
        }
        Value::Number(n) if n.is_f64() => {
            let v = n.as_f64()?;
            if !v.is_finite() {
                return None;
            }
            let text = if v != 0. && !(0.0001..1e16).contains(&v.abs()) {
                let text = format!("{v:e}");
                let (digits, exponent) = text.split_once('e')?;
                let exponent = exponent.parse::<i32>().ok()?;
                format!("{digits}e{exponent:+03}")
            } else {
                v.to_string()
            };
            out.extend_from_slice(text.as_bytes());
        }
        _ => serde_json::to_writer(&mut *out, value).ok()?,
    }
    Some(())
}
impl Envelope {
    pub(crate) fn encode(&self) -> Option<Vec<u8>> {
        let mut bytes = Vec::new();
        encode_disk(&self.put(), &mut bytes)?;
        Some(bytes)
    }
    pub(crate) fn decode(bytes: &[u8]) -> Option<Self> {
        let v = Self::get(&serde_json::from_slice(bytes).ok()?)?;
        if v.version != 2 || v.generation == 0 || v.encode()?.as_slice() != bytes {
            return None;
        }
        if let Some(retry) = &v.retry {
            if retry.generation != v.generation || Some(&retry.record) != v.record.as_ref() {
                return None;
            }
        }
        Some(v)
    }
    pub(crate) fn replace(&mut self, next: Option<Record>) -> Option<()> {
        if self.record != next {
            self.generation = self.generation.checked_add(1)?;
        }
        self.completed = if next.is_none() {
            self.record.as_ref().map(|v| v.id).or(self.completed)
        } else {
            None
        };
        if let (Some(prev), Some(rec)) = (&self.record, &next) {
            if prev.id == rec.id
                && prev.owner == rec.owner
                && prev.boot == rec.boot
                && prev.baseline == rec.baseline
                && prev.phase == rec.phase
            {
                if let Some(retry) = self.retry.as_mut() {
                    retry.record = rec.clone();
                    retry.generation = self.generation;
                }
            } else {
                self.retry = None;
            }
        } else {
            self.retry = None;
        }
        self.record = next;
        Some(())
    }
}
#[no_mangle]
pub unsafe extern "C" fn nespat_verify_record(
    bytes: *const u8,
    len: usize,
    setup: &[u8; 16],
    uid: u32,
    code: core_foundation::string::CFStringRef,
    selected: bool,
    maximum: f64,
) -> bool {
    use core_foundation::{base::TCFType, string::CFString};
    if bytes.is_null() || len > 8192 || code.is_null() {
        return false;
    }
    let code = CFString::wrap_under_get_rule(code).to_string();
    serde_json::from_slice(std::slice::from_raw_parts(bytes, len))
        .ok()
        .and_then(|v| Record::get(&v))
        .is_some_and(|r| r.proof(*setup, uid, &code, selected, maximum).is_some())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn double_encoding_matches_historical_swift_journals() {
        for (n, expected) in [
            (0.0, "0"),
            (-0.0, "-0"),
            (1e-6, "1e-06"),
            (1e-7, "1e-07"),
            (1e-4, "0.0001"),
            (1e15, "1000000000000000"),
            (1e16, "1e+16"),
            (816700000.001, "816700000.001"),
        ] {
            let mut v = Vec::new();
            encode_disk(&n.put(), &mut v).unwrap();
            assert_eq!(v, expected.as_bytes());
        }
    }
    #[test]
    fn migration_only_accepts_exact_provisioned_journal() {
        let old = br#"{"generation":1,"version":2}"#;
        assert_eq!(Envelope::decode(old).unwrap().encode().unwrap(), old);
        for bad in [
            &br#"{"version":2,"generation":1}"#[..],
            br#"{"generation":0,"version":2}"#,
            br#"{"generation":1,"retry":null,"version":2}"#,
            br#"{"generation":1,"unknown":1,"version":2}"#,
        ] {
            assert!(Envelope::decode(bad).is_none());
        }
    }
}
