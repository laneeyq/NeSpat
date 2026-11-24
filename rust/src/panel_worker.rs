// A single worker owns the authenticated session. UI callbacks only enqueue work,
// and revocation is visible even while a previous XPC operation is in flight.
use crate::driver::{Driver, Status};
use objc2::rc::autoreleasepool;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{channel, RecvTimeoutError, Sender},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

enum Command {
    Intent(bool),
    Recover,
    Quit,
    Stop,
}

#[derive(Clone, Default)]
pub struct Report {
    pub status: Status,
    pub quit: bool,
    pub desired: bool,
    pub display_notice: Option<&'static str>,
    generation: u64,
}

pub struct Worker {
    guard: crate::display_guard::Guard,
    desired: Arc<AtomicBool>,
    report: Arc<Mutex<Report>>,
    sender: Sender<(u64, Command)>,
}
impl Worker {
    pub fn start(automatic: bool) -> Self {
        let desired = Arc::new(AtomicBool::new(automatic));
        let report = Arc::new(Mutex::new(Report {
            desired: automatic,
            ..Report::default()
        }));
        let (sender, receiver) = channel();
        let guard = crate::display_guard::Guard::start();
        let monitor = guard.clone();
        let intent = desired.clone();
        let out = report.clone();
        thread::spawn(move || {
            let mut driver = Driver::default();
            let mut command = Some((0, Command::Intent(automatic)));
            let mut applied = 0;
            let mut quit = false;
            loop {
                autoreleasepool(|_| {
                    let action = command.take().map(|(generation, action)| {
                        applied = generation;
                        action
                    });
                    match action {
                        Some(Command::Intent(true)) => driver.new_intent(),
                        Some(Command::Recover) => driver.manual(&intent),
                        Some(Command::Quit) => quit = true,
                        _ => {}
                    }
                    driver.poll(&intent);
                    monitor.publish(applied, driver.display_permit);
                    if driver.status.finished {
                        // Serialize completion with intent changes. A queued new
                        // start must never be lost when an older session expires.
                        let mut state = out.lock().unwrap();
                        if state.desired && state.generation == applied {
                            state.desired = false;
                            intent.store(false, Ordering::Release);
                        }
                    }
                    let mut state = out.lock().unwrap();
                    state.status = driver.status.clone();
                    state.quit = quit
                        && state.generation == applied
                        && !intent.load(Ordering::Acquire)
                        && driver.can_exit()
                        && !monitor.layout_busy()
                        && crate::observation::nespat_sleep_disabled() == 0;
                });
                command = match receiver.recv_timeout(Duration::from_secs(5)) {
                    Ok((_, Command::Stop)) | Err(RecvTimeoutError::Disconnected) => break,
                    Ok(cmd) => Some(cmd),
                    Err(RecvTimeoutError::Timeout) => None,
                };
            }
        });
        Self {
            guard,
            desired,
            report,
            sender,
        }
    }
    pub fn report(&self) -> Report {
        let mut report = self.report.lock().unwrap().clone();
        report.display_notice = self.guard.notice();
        report
    }
    fn send(&self, on: bool, command: Command) {
        let mut report = self.report.lock().unwrap();
        report.desired = on;
        report.quit = false;
        self.desired.store(on, Ordering::Release);
        report.generation = report.generation.wrapping_add(1);
        self.guard.revoke(report.generation);
        let _ = self.sender.send((report.generation, command));
    }
    pub fn intent(&self, on: bool) {
        self.send(on, Command::Intent(on));
    }
    pub fn recover(&self) {
        self.send(false, Command::Recover);
    }
    pub fn quit(&self) {
        self.send(false, Command::Quit);
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.guard.stop();
        let _ = self.sender.send((0, Command::Stop));
    }
}
