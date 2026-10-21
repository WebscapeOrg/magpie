use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{Mutex, Semaphore, SemaphorePermit},
    time::Instant,
};

// Invariant: 1,200 + 75 * 60 = 5,700 units in any minute, below Google's 6,000.
const BURST: f64 = 1200.0;
const UNITS_PER_SECOND: f64 = 75.0;
const BACKGROUND_RESERVE: f64 = 600.0;
const CONCURRENT: usize = 4;
static SERIAL: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy)]
pub enum Lane {
    Interactive,
    Background,
    Poll,
    Queue,
}
impl Lane {
    pub fn name(self) -> &'static str {
        match self {
            Self::Interactive => "interactive",
            Self::Background => "background",
            Self::Poll => "poll",
            Self::Queue => "queue",
        }
    }
}

struct State {
    units: f64,
    updated: Instant,
    cooldown: Instant,
}
pub struct Budget {
    pub id: u64,
    state: Mutex<State>,
    slots: Semaphore,
    foreground: AtomicUsize,
    valid: Arc<AtomicBool>,
}
pub struct Admission<'a> {
    _permit: SemaphorePermit<'a>,
    _foreground: Option<Waiting<'a>>,
}
struct Waiting<'a>(&'a AtomicUsize);
impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Default for Budget {
    fn default() -> Self {
        Self::new(Arc::new(AtomicBool::new(true)))
    }
}
impl Budget {
    pub fn new(valid: Arc<AtomicBool>) -> Self {
        let now = Instant::now();
        Self {
            id: SERIAL.fetch_add(1, Ordering::Relaxed) + 1,
            state: Mutex::new(State {
                units: BURST,
                updated: now,
                cooldown: now,
            }),
            slots: Semaphore::new(CONCURRENT),
            foreground: AtomicUsize::new(0),
            valid,
        }
    }
}
impl Budget {
    pub async fn acquire(
        &self,
        cost: u32,
        lane: Lane,
        deadline: Instant,
    ) -> Result<Admission<'_>, &'static str> {
        let background = matches!(lane, Lane::Background);
        let waiting = if background {
            None
        } else {
            self.foreground.fetch_add(1, Ordering::Relaxed);
            Some(Waiting(&self.foreground))
        };
        let mut permit = Some(if background {
            if self.foreground.load(Ordering::Relaxed) != 0 {
                return Err("gmail_rate_limited");
            }
            self.slots.try_acquire().map_err(|_| "gmail_rate_limited")?
        } else {
            tokio::time::timeout_at(deadline, self.slots.acquire())
                .await
                .map_err(|_| "gmail_rate_limited")?
                .map_err(|_| "gmail_rate_limited")?
        });
        loop {
            if !self.valid.load(Ordering::Acquire) {
                return Err("gmail_session_invalidated");
            }
            let now = Instant::now();
            let wait = {
                let mut state = self.state.lock().await;
                state.units = (state.units
                    + now.duration_since(state.updated).as_secs_f64() * UNITS_PER_SECOND)
                    .min(BURST);
                state.updated = now;
                let reserve = if background { BACKGROUND_RESERVE } else { 0.0 };
                let debt = (f64::from(cost) + reserve - state.units).max(0.0);
                let wait = Duration::from_secs_f64(debt / UNITS_PER_SECOND)
                    .max(state.cooldown.saturating_duration_since(now));
                if wait.is_zero() && now < deadline {
                    state.units -= f64::from(cost);
                    return Ok(Admission {
                        _permit: permit.take().unwrap(),
                        _foreground: waiting,
                    });
                }
                wait
            };
            if now + wait >= deadline {
                return Err("gmail_rate_limited");
            }
            if background {
                drop(permit.take());
            }
            tokio::time::sleep(wait).await;
            if background {
                if self.foreground.load(Ordering::Relaxed) != 0 {
                    return Err("gmail_rate_limited");
                }
                permit = Some(self.slots.try_acquire().map_err(|_| "gmail_rate_limited")?);
            }
        }
    }
    pub async fn cool_down(&self, wait: Duration) {
        let mut state = self.state.lock().await;
        state.cooldown = state.cooldown.max(Instant::now() + wait);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn a_minute_of_reads_stays_below_quota_and_accounts_are_independent() {
        let budget = Budget::default();
        let start = Instant::now();
        let mut units = 0;
        loop {
            let permit = budget
                .acquire(
                    60,
                    Lane::Interactive,
                    Instant::now() + Duration::from_secs(20),
                )
                .await
                .unwrap();
            if start.elapsed() >= Duration::from_secs(60) {
                break;
            }
            units += 60;
            drop(permit);
        }
        assert!(units <= 5700, "{units} units sent in one minute");
        let other = Budget::default();
        let start = Instant::now();
        let _permit = other
            .acquire(60, Lane::Interactive, start + Duration::from_secs(1))
            .await
            .unwrap();
        assert_eq!(start.elapsed(), Duration::ZERO);
    }
    #[tokio::test(start_paused = true)]
    async fn background_yields_and_cancelled_waits_do_not_spend_future_quota() {
        let budget = Budget::default();
        let deadline = Instant::now() + Duration::from_secs(20);
        drop(
            budget
                .acquire(1200, Lane::Interactive, deadline)
                .await
                .unwrap(),
        );
        assert!(
            budget
                .acquire(
                    60,
                    Lane::Background,
                    Instant::now() + Duration::from_millis(100)
                )
                .await
                .is_err()
        );
        let before = Instant::now();
        assert!(
            budget
                .acquire(60, Lane::Interactive, before + Duration::from_millis(100))
                .await
                .is_err()
        );
        assert_eq!(before.elapsed(), Duration::ZERO);
        drop(
            budget
                .acquire(60, Lane::Interactive, deadline)
                .await
                .unwrap(),
        );
        assert_eq!(before.elapsed(), Duration::from_millis(800));
    }
    #[tokio::test(start_paused = true)]
    async fn cooldown_is_shared_and_a_slot_wait_is_cancellable() {
        let budget = Budget::default();
        budget.cool_down(Duration::from_secs(90)).await;
        let before = Instant::now();
        assert!(
            budget
                .acquire(1, Lane::Interactive, before + Duration::from_secs(20))
                .await
                .is_err()
        );
        assert_eq!(before.elapsed(), Duration::ZERO);
        tokio::time::advance(Duration::from_secs(90)).await;
        let mut permits = Vec::new();
        for _ in 0..4 {
            permits.push(
                budget
                    .acquire(
                        1,
                        Lane::Interactive,
                        Instant::now() + Duration::from_secs(1),
                    )
                    .await
                    .unwrap(),
            );
        }
        assert!(
            budget
                .acquire(
                    1,
                    Lane::Interactive,
                    Instant::now() + Duration::from_secs(1)
                )
                .await
                .is_err()
        );
        assert_eq!(budget.foreground.load(Ordering::Relaxed), 4);
        drop(permits);
        assert_eq!(budget.foreground.load(Ordering::Relaxed), 0);
        assert!(
            budget
                .acquire(1, Lane::Background, Instant::now() + Duration::from_secs(1))
                .await
                .is_ok()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn background_waits_leave_slots_and_reserve_available_to_browsing() {
        let budget = Arc::new(Budget::default());
        let deadline = Instant::now() + Duration::from_secs(20);
        drop(
            budget
                .acquire(600, Lane::Interactive, deadline)
                .await
                .unwrap(),
        );
        let background = tokio::spawn({
            let budget = Arc::clone(&budget);
            async move {
                budget
                    .acquire(60, Lane::Background, deadline)
                    .await
                    .map(drop)
            }
        });
        tokio::task::yield_now().await;
        assert_eq!(
            budget.slots.available_permits(),
            CONCURRENT,
            "background token waits cannot hold transport slots"
        );
        let before = Instant::now();
        let browsing = budget
            .acquire(600, Lane::Interactive, deadline)
            .await
            .unwrap();
        assert_eq!(
            before.elapsed(),
            Duration::ZERO,
            "the browsing reserve is available immediately"
        );
        assert_eq!(background.await.unwrap(), Err("gmail_rate_limited"));
        drop(browsing);
    }

    #[tokio::test(start_paused = true)]
    async fn dropping_a_token_wait_releases_foreground_priority_without_debt() {
        let budget = Budget::default();
        let deadline = Instant::now() + Duration::from_secs(20);
        drop(
            budget
                .acquire(1200, Lane::Interactive, deadline)
                .await
                .unwrap(),
        );
        assert!(
            tokio::time::timeout(
                Duration::from_millis(100),
                budget.acquire(60, Lane::Interactive, deadline)
            )
            .await
            .is_err()
        );
        assert_eq!(budget.foreground.load(Ordering::Relaxed), 0);
        assert_eq!(budget.slots.available_permits(), CONCURRENT);
        let before = Instant::now();
        drop(
            budget
                .acquire(60, Lane::Interactive, deadline)
                .await
                .unwrap(),
        );
        assert_eq!(before.elapsed(), Duration::from_millis(700));
    }
}
