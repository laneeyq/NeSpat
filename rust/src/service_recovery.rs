use crate::service_platform::idle;
use crate::service_platform::{clock, nespat_profile_enabled, nespat_set_power, power};
use crate::{
    client::new_id,
    host::{boot, nespat_snapshot, ProcessStamp},
    observation::{nespat_active_uid, nespat_lid_closed},
    profile::Profile,
    pulse,
    recovery::{nespat_retry_decision, Retry as Decision},
    service_record::{Phase, Record, Retry, Stamp},
    service_store::Transaction,
    setter::SetterResult,
};
use objc2_foundation::NSProcessInfo;
use std::time::{SystemTime, UNIX_EPOCH};
pub(crate) fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(f64::NAN, |d| d.as_secs_f64() - 978307200.)
}
pub(crate) fn live(p: &Stamp) -> bool {
    let mut stamp = ProcessStamp::default();
    boot() == Some(p.boot)
        && nespat_snapshot(p.pid, &mut stamp) == 1
        && p.uid == stamp.uid
        && p.seconds == stamp.seconds
        && p.micros == stamp.micros
}
pub(crate) struct Host {
    pub profile: Profile,
    pub client: String,
    pub boot: [u8; 16],
    pub epoch: [u8; 16],
    pub watchdog: bool,
}
impl Host {
    #[cfg(not(test))]
    pub fn safety(&self, starting: bool) -> (u8, i8) {
        if (!self.watchdog && !pulse::available(self.boot, self.profile.setup, true))
            || nespat_active_uid() != self.profile.uid()
            || nespat_lid_closed() < 0
        {
            return (1, -1);
        }
        let b = crate::battery::nespat_current_battery();
        let thermal = match NSProcessInfo::processInfo().thermalState().0 {
            0 | 1 => 0,
            2 | 3 => 1,
            _ => -1,
        };
        (
            crate::policy::nespat_assess(
                b.percent,
                b.external,
                crate::nespat_chip_temperature(),
                thermal,
                starting,
            ),
            b.external,
        )
    }
    #[cfg(not(test))]
    pub fn can_arm(&self) -> bool {
        !self.watchdog
            && nespat_profile_enabled(&self.profile)
            && nespat_lid_closed() == 0
            && pulse::available(self.boot, self.profile.setup, true)
            && nespat_active_uid() == self.profile.uid()
    }
    #[cfg(test)]
    pub fn safety(&self, _: bool) -> (u8, i8) {
        crate::service_platform::SAFETY.get()
    }
    #[cfg(test)]
    pub fn can_arm(&self) -> bool {
        !self.watchdog && crate::service_platform::ARM.get()
    }
    pub fn finalize(&self, r: &Record) {
        if self.profile.trial_only()
            || r.boot != self.boot
            || r.attempt.is_none()
            || !nespat_profile_enabled(&self.profile)
        {
            return;
        }
        if matches!(self.safety(false).0, 2 | 3 | 5) && power() == 0 {
            let status = crate::service_platform::emergency_sleep();
            if status != 0 {
                eprintln!("Emergency sleep request failed ({status})");
            }
        }
    }
}
pub(crate) fn reserve(
    tx: &mut Transaction,
    rec: &Record,
    emergency: bool,
    manual: bool,
) -> Option<bool> {
    let s = tx.state();
    let time = clock();
    let generation = s.generation;
    let previous = s.retry.clone();
    let failures = previous.as_ref().and_then(|v| v.failures);
    if !time.is_finite() || time < 0. {
        if let Some(mut r) = previous {
            r.clock_fault = true;
            tx.retry(r)?;
        }
        return None;
    }
    if let Some(mut r) = previous {
        if &r.record != rec || r.generation != generation {
            return None;
        }
        match nespat_retry_decision(
            time,
            r.since,
            r.last,
            r.clock_fault,
            r.emergency,
            emergency,
            manual,
            if emergency { 30. } else { 300. },
        ) {
            Decision::ClockFault => {
                r.clock_fault = true;
                tx.retry(r)?;
                return None;
            }
            Decision::RepairClock => {
                r.since = time;
                r.last = time;
                r.clock_fault = false;
                r.emergency |= emergency;
                tx.retry(r)?;
                if !manual {
                    return Some(false);
                }
            }
            Decision::Wait => {
                r.last = time;
                tx.retry(r)?;
                return Some(false);
            }
            Decision::InvalidHistory => return None,
            Decision::Reserve => {}
        }
    }
    tx.retry(Retry {
        record: rec.clone(),
        generation,
        nonce: new_id(),
        since: time,
        last: time,
        emergency,
        clock_fault: false,
        failures,
    })?;
    Some(true)
}
pub(crate) fn failed(tx: &mut Transaction, r: &Record) -> Option<()> {
    let mut retry = tx.state().retry.clone()?;
    if &retry.record != r {
        return None;
    }
    retry.failures = Some(retry.failures.unwrap_or(0).checked_add(1)?);
    let time = clock();
    if time.is_finite() && time >= retry.last {
        retry.since = time;
        retry.last = time;
    } else {
        retry.clock_fault = true;
    }
    tx.retry(retry)
}
pub(crate) fn reconcile(
    h: &Host,
    tx: &mut Transaction,
    approval: Option<([u8; 16], &str)>,
) -> Option<()> {
    let Some(mut r) = tx.state().record.clone() else {
        return approval.is_none().then_some(());
    };
    if let Some((id, ticket)) = approval {
        if id != r.id || r.attempt.is_none() || ticket != tx.ticket() {
            return None;
        }
    }
    let p = &h.profile;
    if r.attempt.is_none() {
        if r.reservation != Some(p.setup)
            || r.boot != h.boot
            || !r.baseline
            || r.owner.uid != p.uid()
            || r.owner.code.as_deref() != Some(h.client.as_str())
            || r.owner.process.is_none()
            || r.phase != Phase::Pending
            || r.interference == Some(true)
            || !idle()
            || power() != 0
            || !tx.intact()
        {
            return None;
        }
        return tx.replace(None);
    }
    let proof = r.proof(p.setup, p.uid(), &h.client, p.selected(), p.maximum())?;
    if !idle() {
        return None;
    }
    match power() {
        0 => {
            if !tx.intact() || !idle() {
                return None;
            }
            if power() != 0 {
                r.interference = Some(true);
                tx.replace(Some(r))?;
                return None;
            }
            return tx.replace(None);
        }
        1 if r.boot == h.boot => {}
        _ => return None,
    }
    let time = clock();
    if !time.is_finite() || time < proof.issued {
        return None;
    }
    let (assessment, ac) = h.safety(false);
    let emergency = !nespat_profile_enabled(p)
        || assessment != 0
        || !p.permits_source(ac)
        || (!p.selected() && proof.on_ac && ac != 1);
    let helper = if approval.is_some() {
        None
    } else {
        pulse::latest(h.boot, p.setup, false)
    };
    if tx.state().retry.is_none()
        && !emergency
        && Some(proof.epoch) == helper
        && r.phase != Phase::Pending
        && proof.expires.is_none_or(|t| time < t)
        && proof.deadline.is_none_or(|t| wall() < t)
        && r.owner.process.as_ref().is_some_and(live)
    {
        return Some(());
    }
    if !reserve(tx, &r, emergency, approval.is_some())? {
        return Some(());
    }
    if !tx.intact() || !idle() || power() != 1 {
        return None;
    }
    if !matches!(nespat_set_power(false), SetterResult::Confirmed) || !tx.intact() || power() != 0 {
        failed(tx, &r)?;
        return None;
    }
    tx.replace(None)?;
    h.finalize(&r);
    Some(())
}
