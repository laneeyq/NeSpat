use crate::service_platform::{clock, nespat_profile_enabled, nespat_set_power, power};
use crate::{
    authority::*,
    client::new_id,
    observation::nespat_active_uid,
    profile::Profile,
    request::{uuid_text, Request},
    service_record::{Attempt, Peer, Phase, Record, Stamp},
    service_recovery::{failed, reserve, wall, Host},
    service_store::{Store, Transaction},
    setter::SetterResult,
};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
type Id = [u8; 16];
#[derive(Clone)]
struct Grant {
    peer: Peer,
    until: f64,
    owned: Option<Id>,
    full: bool,
    selected: bool,
    expires: Option<f64>,
    last: f64,
    heartbeat: f64,
    sequence: i64,
    count: u32,
}
impl Grant {
    fn expired(&self, now: f64) -> bool {
        let end = if self.selected {
            self.expires
        } else {
            Some(self.until)
        };
        nespat_authority_expired(
            &AuthorityClock {
                expiry: end.unwrap_or(0.),
                has_expiry: end.is_some(),
                last_observation: self.last,
                last_heartbeat: self.heartbeat,
                full: self.full,
                has_observation: true,
                has_heartbeat: true,
                has_timeout: true,
                timeout: 20.,
            },
            now,
        )
    }
}
#[derive(Default)]
struct State {
    grants: HashMap<Id, Grant>,
    admitted: HashSet<Id>,
    disconnected: HashSet<Id>,
    ledger: ReplayLedger,
    remembered: Option<Record>,
    lost: bool,
}
fn active(stamp: &Stamp) -> Option<bool> {
    if crate::host::boot() != Some(stamp.boot) {
        return None;
    }
    let mut actual = crate::host::ProcessStamp::default();
    match crate::host::nespat_snapshot(stamp.pid, &mut actual) {
        0 => Some(false),
        1 => Some(
            stamp.uid == actual.uid
                && stamp.seconds == actual.seconds
                && stamp.micros == actual.micros,
        ),
        _ => None,
    }
}
impl State {
    fn retire(&mut self, peer: &Peer) {
        for g in self
            .grants
            .values_mut()
            .filter(|g| g.peer.same_owner(peer) && g.full)
        {
            g.full = false;
            g.count = 0;
        }
    }
    fn load(&mut self, tx: &Transaction) -> Option<Record> {
        let rec = tx.state().record.clone();
        if let Some(previous) = self.remembered.clone() {
            if rec.is_none() && tx.state().completed == Some(previous.id) && power() == 0 {
                self.retire(&previous.owner);
                self.remembered = None;
            } else if !rec.as_ref().is_some_and(|r| {
                r.id == previous.id
                    && r.owner == previous.owner
                    && r.phase == previous.phase
                    && r.attempt == previous.attempt
            }) {
                self.lost = true;
            }
        }
        if self.remembered.is_none() {
            self.remembered = rec.clone();
        }
        rec
    }
    fn reconnect(&self, record: &Record, peer: &Peer) -> bool {
        if !record.owner.same_owner(peer) {
            return false;
        }
        if record.owner.connection == peer.connection {
            return true;
        }
        let live = record.owner.process.as_ref().and_then(active);
        let same = record.owner.process.is_some() && record.owner.process == peer.process;
        !self.grants.contains_key(&record.owner.connection)
            && (live != Some(true) || same)
            && (self.disconnected.contains(&record.owner.connection) || live == Some(false) || same)
    }
    fn admit(&mut self, h: &Host, tx: &Transaction, peer: &Peer) -> Option<()> {
        if !peer.valid()
            || peer.uid != h.profile.uid()
            || peer.code.as_deref() != Some(&h.client)
            || peer.process.as_ref().and_then(active) != Some(true)
            || nespat_active_uid() != peer.uid
            || crate::host::boot() != Some(h.boot)
            || self.admitted.contains(&peer.connection)
            || self.admitted.len() >= 4096
            || self.grants.len() >= 64
        {
            return None;
        }
        let record = self.load(tx);
        if self.lost {
            return None;
        }
        let owned = if let Some(r) = record {
            if !r.owns(h.boot)
                || r.phase != Phase::Active
                || !self.reconnect(&r, peer)
                || self
                    .grants
                    .values()
                    .any(|g| !g.full && g.owned == Some(r.id))
            {
                return None;
            }
            Some(r.id)
        } else {
            None
        };
        let issued = clock();
        let enabled = nespat_profile_enabled(&h.profile);
        let mut until = issued + if enabled { h.profile.maximum() } else { 43200. };
        if enabled && h.profile.trial_only() {
            until = until.min(Profile::load()?.trial_expires()?);
        }
        let now = clock();
        if !issued.is_finite() || !now.is_finite() || now < issued || until <= now {
            return None;
        }
        if owned.is_none()
            && (!enabled
                || tx.state().retry.is_some()
                || !nespat_valid_grant(issued, until, h.profile.maximum())
                || self
                    .grants
                    .values()
                    .any(|g| g.full && g.peer.same_owner(peer))
                || power() != 0)
        {
            return None;
        }
        self.grants.insert(
            peer.connection,
            Grant {
                peer: peer.clone(),
                until,
                owned,
                full: owned.is_none(),
                selected: false,
                expires: None,
                last: now,
                heartbeat: now,
                sequence: 0,
                count: 0,
            },
        );
        self.admitted.insert(peer.connection);
        Some(())
    }
    fn reply(&self, h: &Host, tx: &Transaction, rec: Option<&Record>, p: &Peer) -> Value {
        let mut v = json!({"state":match power(){0=>"enabled",1=>"disabled",_=>"unknown"},"fullAuthority":self.grants.get(&p.connection).is_some_and(|g|g.full)});
        if let Some(r) = rec {
            v["session"] = json!(uuid_text(&r.id));
            v["active"] = json!(r.phase == Phase::Active);
            if let Some(e) = r.deadline {
                v["deadline"] = json!(e);
            }
            if let Some(e) = r.expires {
                v["authorityExpires"] = json!(e);
            }
            if let Some(a) = &r.attempt {
                if let Some(s) = a.selected {
                    v["selectedLifetime"] = json!(s);
                }
            }
            if p.same_owner(&r.owner)
                && r.proof(
                    h.profile.setup,
                    h.profile.uid(),
                    &h.client,
                    h.profile.selected(),
                    h.profile.maximum(),
                )
                .is_some()
            {
                v["recoveryTicket"] = json!(tx.ticket());
            }
        }
        v
    }
    fn precheck(&mut self, p: &Peer, q: &Request, now: f64) -> Option<Grant> {
        let g = self.grants.get(&p.connection)?;
        if g.peer != *p {
            return None;
        }
        if g.expired(now) || q.operation == 5 {
            self.retire(p);
        }
        let g = self.grants.get_mut(&p.connection)?;
        if !g.full && (!matches!(q.operation, 0 | 4 | 5 | 7) || g.owned.is_none()) {
            return None;
        }
        let mut r = RequestAdmission {
            id: q.id,
            sequence: q.sequence,
            last_sequence: g.sequence,
            requests: g.count,
            has_sequence: q.has_sequence,
            selected: g.selected,
            matching_session: g.owned == q.has_session.then_some(q.session),
            recovery: !g.full,
        };
        if !matches!(
            nespat_admit_request(&mut self.ledger, &mut r),
            Admission::Allowed
        ) {
            return None;
        }
        g.sequence = r.last_sequence;
        g.count = r.requests;
        g.last = now;
        Some(g.clone())
    }
    fn start(
        &mut self,
        h: &Host,
        tx: &mut Transaction,
        g: &Grant,
        q: &Request,
        now: f64,
    ) -> Option<()> {
        let p = &h.profile;
        if self.lost
            || tx.state().record.is_some()
            || !g.full
            || !h.can_arm()
            || g.expired(now)
            || g.until - now > p.maximum()
            || power() != 0
        {
            return None;
        }
        let (safety, ac) = h.safety(true);
        if safety != 0 || !p.permits_source(ac) {
            return None;
        }
        let duration = if q.has_minutes {
            let seconds = crate::policy::nespat_minutes_to_seconds(q.minutes);
            if seconds <= 0 {
                return None;
            }
            Some(seconds as f64)
        } else {
            None
        };
        let time = wall();
        let mut end = duration.map(|s| crate::policy::nespat_deadline(time, s));
        if end.is_some_and(|x| !x.is_finite()) {
            return None;
        }
        let expires = if p.selected() {
            duration.map(|d| now + d)
        } else {
            let upper = time + (g.until - now);
            end = Some(end.unwrap_or(upper).min(upper));
            Some(g.until)
        };
        let mut r = Record {
            id: new_id(),
            owner: g.peer.clone(),
            boot: h.boot,
            baseline: true,
            phase: Phase::Pending,
            reservation: Some(p.setup),
            attempt: None,
            interference: None,
            deadline: end,
            expires,
        };
        let id = g.peer.connection;
        tx.replace(Some(r.clone()))?;
        self.remembered = Some(r.clone());
        self.grants.get_mut(&id)?.owned = Some(r.id);
        let pre = h.safety(true);
        if pre.0 != 0
            || !p.permits_source(pre.1)
            || !tx.intact()
            || g.expired(clock())
            || !h.can_arm()
            || power() != 0
        {
            if tx.intact() && power() == 0 {
                tx.replace(None)?;
                self.remembered = None;
                self.grants.get_mut(&id)?.owned = None;
            }
            return None;
        }
        r.attempt = Some(Attempt {
            setup: p.setup,
            session: r.id,
            epoch: h.epoch,
            owner: g.peer.clone(),
            boot: h.boot,
            on_ac: pre.1 == 1,
            issued: now,
            nonce: new_id(),
            expires,
            deadline: end,
            selected: p.selected().then_some(true),
            unlimited: end.is_none().then_some(true),
        });
        r.proof(p.setup, p.uid(), &h.client, p.selected(), p.maximum())?;
        tx.replace(Some(r.clone()))?;
        self.remembered = Some(r.clone());
        let permitted = || {
            let (risk, ac) = h.safety(true);
            risk == 0
                && p.permits_source(ac)
                && h.can_arm()
                && clock() < g.until
                && end.is_none_or(|t| wall() < t)
        };
        if !tx.intact() || !permitted() {
            return None;
        }
        let result = if power() != 0 {
            SetterResult::Interference
        } else {
            nespat_set_power(true)
        };
        match result {
            SetterResult::Confirmed => {}
            SetterResult::Interference => {
                if tx.intact() {
                    r.interference = Some(true);
                    tx.replace(Some(r))?;
                }
                return None;
            }
            _ => return None,
        }
        if power() != 1 || !tx.intact() || clock() >= g.until || end.is_some_and(|e| wall() >= e) {
            return None;
        }
        r.phase = Phase::Active;
        tx.replace(Some(r.clone()))?;
        self.remembered = Some(r);
        let grant = self.grants.get_mut(&id)?;
        grant.selected = p.selected();
        grant.expires = expires;
        Some(())
    }
    fn restore(
        &mut self,
        h: &Host,
        tx: &mut Transaction,
        r: &Record,
        peer: Option<&Peer>,
    ) -> Option<()> {
        if self.lost || !r.owns(h.boot) || r.phase != Phase::Active || !tx.intact() {
            return None;
        }
        r.proof(
            h.profile.setup,
            h.profile.uid(),
            &h.client,
            h.profile.selected(),
            h.profile.maximum(),
        )?;
        if let Some(q) = peer {
            if !self.reconnect(r, q) {
                return None;
            }
        } else if !self.grants.contains_key(&r.owner.connection)
            && !self.disconnected.contains(&r.owner.connection)
            && r.owner.process.as_ref().and_then(active) != Some(false)
        {
            return None;
        }
        let initial = power();
        if !tx.intact() {
            return None;
        }
        if initial == 1 {
            let (risk, _) = h.safety(false);
            if risk != 0 {
                self.retire(&r.owner);
            }
            if !reserve(tx, r, risk != 0, false)? {
                return Some(());
            }
            if !tx.intact() {
                return None;
            }
            if !matches!(nespat_set_power(false), SetterResult::Confirmed) || power() != 0 {
                failed(tx, r)?;
                return None;
            }
        } else if initial != 0 {
            return None;
        }
        if !tx.intact() || power() != 0 || !tx.intact() {
            return None;
        }
        tx.replace(None)?;
        if initial == 1 {
            h.finalize(r);
        }
        self.remembered = None;
        self.lost = false;
        self.grants.retain(|_, g| {
            if g.owned != Some(r.id) {
                return true;
            }
            if !g.full {
                return false;
            }
            g.owned = None;
            g.selected = false;
            g.expires = None;
            true
        });
        Some(())
    }
    fn handle(
        &mut self,
        h: &Host,
        tx: &mut Transaction,
        p: &Peer,
        q: &Request,
        g: Grant,
        now: f64,
    ) -> Option<Value> {
        let rec = self.load(tx);
        if q.operation == 0 {
            return Some(self.reply(h, tx, rec.as_ref(), p));
        }
        if q.operation == 1 {
            self.start(h, tx, &g, q, now)?;
        } else {
            let r = rec?;
            if self.lost
                || !r.owns(h.boot)
                || g.owned != Some(r.id)
                || (q.operation != 5 && (!q.has_session || q.session != r.id))
                || !self.reconnect(&r, p)
            {
                return None;
            }
            match q.operation {
                6 => {
                    if !g.full || r.owner != *p || r.phase != Phase::Active {
                        return None;
                    }
                    if power() != 1 {
                        if power() == 0 {
                            let mut invalid = r;
                            invalid.interference = Some(true);
                            tx.replace(Some(invalid))?;
                        }
                        return None;
                    }
                    r.proof(
                        h.profile.setup,
                        h.profile.uid(),
                        &h.client,
                        h.profile.selected(),
                        h.profile.maximum(),
                    )?;
                    let at = clock();
                    if g.expired(at) {
                        self.retire(p);
                        return None;
                    }
                    let g = self.grants.get_mut(&p.connection)?;
                    g.heartbeat = at;
                    g.last = at;
                }
                3 | 5 | 7 => {
                    if q.operation == 7 {
                        self.retire(p);
                    }
                    self.restore(h, tx, &r, Some(p))?;
                }
                // Exclusive sessions have an immutable timer and separate admin recovery.
                _ => return None,
            }
        }
        Some(self.reply(h, tx, tx.state().record.as_ref(), p))
    }
}
pub(crate) struct Server {
    pub host: Host,
    store: Store,
    state: State,
}
impl Server {
    pub fn new(host: Host, store: Store) -> Self {
        Self {
            host,
            store,
            state: State::default(),
        }
    }
    pub fn request(&mut self, p: &Peer, q: &Request) -> Option<Value> {
        if !crate::request::nespat_valid_request(q) {
            return None;
        }
        if !self.state.grants.contains_key(&p.connection) {
            self.store
                .transaction(|t| self.state.admit(&self.host, t, p))?;
        }
        if q.operation == 5
            && self
                .state
                .grants
                .get(&p.connection)
                .is_some_and(|g| g.peer == *p && g.owned.is_none())
        {
            self.state.retire(p);
            self.state.grants.remove(&p.connection);
            return Some(json!({"state":match power(){0=>"enabled",1=>"disabled",_=>"unknown"}}));
        }
        let now = clock();
        let g = self.state.precheck(p, q, now)?;
        self.store
            .transaction(|tx| self.state.handle(&self.host, tx, p, q, g, now))
    }
    pub fn close(&mut self, p: &Peer) {
        if !self
            .state
            .grants
            .get(&p.connection)
            .is_some_and(|g| g.peer == *p)
        {
            return;
        }
        self.state.retire(p);
        let g = self.state.grants.remove(&p.connection).unwrap();
        self.state.disconnected.insert(p.connection);
        self.store.transaction(|t| {
            let r = self.state.load(t)?;
            if g.owned != Some(r.id) {
                return None;
            }
            self.state.restore(&self.host, t, &r, Some(p))
        });
    }
    pub fn tick(&mut self) -> Option<()> {
        self.store.transaction(|tx| {
            let Some(r) = self.state.load(tx) else {
                return Some(());
            };
            if self.state.lost || r.interference == Some(true) {
                return None;
            }
            if r.phase == Phase::Pending || r.boot != self.host.boot {
                return Some(());
            }
            if !r.owns(self.host.boot) || !r.timer_valid() {
                return None;
            }
            let t = clock();
            let g = self.state.grants.get(&r.owner.connection);
            let expired = g.is_none_or(|v| v.expired(t)) || r.expires.is_some_and(|e| e <= t);
            let full = g.is_some_and(|v| v.full);
            let (risk, _) = self.host.safety(false);
            if expired || risk != 0 {
                self.state.retire(&r.owner);
            } else if let Some(g) = self.state.grants.get_mut(&r.owner.connection) {
                g.last = t;
            }
            if expired || risk != 0 || !full || r.deadline.is_some_and(|e| wall() >= e) {
                self.state.restore(&self.host, tx, &r, None)?;
            }
            Some(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        profile::Profile,
        service_platform::{ARM, POWER, SAFETY, SETTERS, SLEEP, TIME},
        service_recovery::reconcile,
    };
    struct Fixture {
        folder: tempfile::TempDir,
        server: Server,
        peer: Peer,
    }
    impl Fixture {
        fn new() -> Self {
            TIME.set(100.);
            POWER.set(0);
            SAFETY.set((0, 1));
            ARM.set(true);
            SLEEP.set(0);
            SETTERS.set(0);
            let uid = unsafe { libc::getuid() };
            let boot = crate::host::boot().unwrap();
            let pid = std::process::id() as i32;
            let mut stamp = crate::host::ProcessStamp::default();
            assert_eq!(crate::host::nespat_snapshot(pid, &mut stamp), 1);
            let p = Profile::fixture(uid);
            let client = p.gui_pin().unwrap();
            let peer = Peer {
                uid,
                audit: 123,
                connection: new_id(),
                code: Some(client.clone()),
                process: Some(Stamp {
                    boot,
                    pid,
                    uid,
                    seconds: stamp.seconds,
                    micros: stamp.micros,
                }),
            };
            let folder = tempfile::tempdir().unwrap();
            let store = Store::fixture(folder.path());
            let host = Host {
                profile: p,
                client,
                boot,
                epoch: new_id(),
                watchdog: false,
            };
            Self {
                folder,
                peer,
                server: Server::new(host, store),
            }
        }
        fn req(&mut self, op: u8, session: Option<Id>, minutes: Option<i64>) -> Option<Value> {
            self.server.request(
                &self.peer,
                &Request {
                    id: new_id(),
                    operation: op,
                    session: session.unwrap_or_default(),
                    has_session: session.is_some(),
                    minutes: minutes.unwrap_or(0),
                    has_minutes: minutes.is_some(),
                    ..Default::default()
                },
            )
        }
        fn begin(&mut self, minutes: Option<i64>) -> Id {
            let v = self.req(1, None, minutes).unwrap();
            assert_eq!(v["active"], true);
            assert_eq!(v["state"], "disabled");
            crate::request::uuid(v["session"].as_str().unwrap()).unwrap()
        }
        fn watchdog(&self) -> Host {
            let h = &self.server.host;
            Host {
                profile: Profile::fixture(h.profile.uid()),
                client: h.client.clone(),
                boot: h.boot,
                epoch: new_id(),
                watchdog: true,
            }
        }
    }
    #[test]
    fn selected_unlimited_survives_unplug_and_ends_once() {
        let mut f = Fixture::new();
        let id = f.begin(None);
        SAFETY.set((0, 0));
        TIME.set(108.);
        let v = f.req(6, Some(id), None).unwrap();
        assert!(v.get("deadline").is_none());
        assert_eq!(v["selectedLifetime"], true);
        f.server.tick().unwrap();
        assert_eq!(POWER.get(), 1);
        f.req(3, Some(id), None).unwrap();
        assert_eq!(POWER.get(), 0);
        assert_eq!(SETTERS.get(), 2);
        assert_eq!(SLEEP.get(), 0);
        f.server
            .store
            .transaction(|t| {
                assert_eq!(t.state().completed, Some(id));
                Some(())
            })
            .unwrap();
    }
    #[test]
    fn independent_process_recovers_after_missing_pulse_and_only_forces_sleep_on_confirmed_danger()
    {
        for (risk, expected_sleep) in [(0, 0), (1, 0), (2, 1), (3, 1), (5, 1)] {
            let mut f = Fixture::new();
            f.begin(Some(5));
            let h = f.watchdog();
            drop(f.server);
            SAFETY.set((risk, 0));
            let mut store = Store::fixture(f.folder.path());
            store.transaction(|t| reconcile(&h, t, None)).unwrap();
            assert_eq!(
                (POWER.get(), SLEEP.get(), SETTERS.get()),
                (0, expected_sleep, 2)
            );
            store.transaction(|t| reconcile(&h, t, None)).unwrap();
            assert_eq!((SLEEP.get(), SETTERS.get()), (expected_sleep, 2));
        }
    }
    #[test]
    fn forged_owner_or_damaged_file_cannot_restore_or_activate() {
        let mut f = Fixture::new();
        let id = f.begin(None);
        let mut stranger = f.peer.clone();
        stranger.connection = new_id();
        stranger.audit += 1;
        assert!(f
            .server
            .request(
                &stranger,
                &Request {
                    id: new_id(),
                    operation: 3,
                    session: id,
                    has_session: true,
                    ..Default::default()
                }
            )
            .is_none());
        std::fs::write(f.folder.path().join("authority.json"), b"{}").unwrap();
        assert!(f.req(3, Some(id), None).is_none());
        let h = f.watchdog();
        assert!(f
            .server
            .store
            .transaction(|t| reconcile(&h, t, None))
            .is_none());
        assert_eq!(SETTERS.get(), 1);
    }
    #[test]
    fn reconnect_without_lease_cannot_resurrect_revoked_authority() {
        let mut f = Fixture::new();
        let id = f.begin(Some(1));
        TIME.set(161.);
        assert!(f.req(6, Some(id), None).is_none());
        f.server.tick().unwrap();
        assert_eq!(POWER.get(), 0);
        assert!(f.req(1, None, None).is_none());
        assert_eq!(SETTERS.get(), 2);
    }
    #[test]
    fn stale_manual_ticket_and_foreign_sleep_are_inert() {
        let mut f = Fixture::new();
        POWER.set(1);
        assert!(f.req(1, None, None).is_none());
        assert_eq!(SETTERS.get(), 0);
        POWER.set(0);
        let id = f.begin(None);
        let h = f.watchdog();
        assert!(f
            .server
            .store
            .transaction(|t| reconcile(&h, t, Some((id, "wrong"))))
            .is_none());
        assert_eq!(SETTERS.get(), 1);
    }
}
