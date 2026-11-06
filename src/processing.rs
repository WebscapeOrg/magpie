use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{future::Future, time::Instant};

tokio::task_local! { static ORIGIN: Origin; }

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Origin {
    App,
    BackgroundRefresh,
    Desktop,
}

impl Origin {
    pub(crate) fn current() -> Self {
        ORIGIN.try_with(|origin| *origin).unwrap_or(if cfg!(feature = "mobile") { Self::App } else { Self::Desktop })
    }
}

pub(crate) async fn scope<T>(origin: Origin, work: impl Future<Output = T>) -> T {
    ORIGIN.scope(origin, work).await
}

#[derive(Clone, Copy)]
struct Activity {
    active: Option<bool>,
    suspensions: u64,
}

fn activity() -> Activity {
    #[cfg(feature = "mobile")]
    return Activity { active: Some(crate::inbox::claude::diagnostics::active()), suspensions: crate::inbox::claude::diagnostics::suspensions() };
    #[cfg(not(feature = "mobile"))]
    Activity { active: None, suspensions: 0 }
}

#[derive(Clone)]
pub(crate) struct Run {
    origin: Origin,
    at: i64,
    clock: Instant,
    activity: Activity,
    remaining_text: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    origin: Origin,
    started_at: i64,
    finished_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    started_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    finished_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    left_app: Option<bool>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    remaining_text: bool,
}

impl Run {
    pub(crate) fn start() -> Self {
        Self { origin: Origin::current(), at: chrono::Utc::now().timestamp_millis(), clock: Instant::now(), activity: activity(), remaining_text: false }
    }

    pub(crate) fn token(&self) -> Value {
        serde_json::json!({"process":std::process::id(),"startedAt":self.at,"suspensions":self.activity.suspensions})
    }

    pub(crate) fn continuing(record: &Value, token: &Value) -> Self {
        let mut run = Self::start();
        run.remaining_text = true;
        let Some(value) = clean(record) else { return run };
        let Ok(record) = serde_json::from_value::<Record>(value) else { return run };
        let Some(suspensions) = token["suspensions"].as_u64() else { return run };
        if token["process"] != std::process::id() || token["startedAt"] != record.started_at { return run; }
        run.origin = record.origin;
        run.at = record.started_at;
        run.activity = Activity { active: record.started_active, suspensions };
        run.remaining_text = false;
        run
    }

    pub(crate) fn is_remaining_text(&self) -> bool { self.remaining_text }

    pub(crate) fn millis(&self) -> u64 {
        u64::try_from(self.clock.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    pub(crate) fn finish(&self) -> Value {
        self.finished(chrono::Utc::now().timestamp_millis(), activity())
    }

    fn finished(&self, at: i64, after: Activity) -> Value {
        serde_json::to_value(Record {
            origin: self.origin,
            started_at: self.at,
            finished_at: at,
            started_active: self.activity.active,
            finished_active: after.active,
            left_app: self.activity.active.map(|_| self.activity.suspensions != after.suspensions || (self.activity.active == Some(true) && after.active == Some(false))),
            remaining_text: self.remaining_text,
        }).unwrap_or(Value::Null)
    }
}

pub(crate) fn clean(value: &Value) -> Option<Value> {
    let record: Record = serde_json::from_value(value.clone()).ok()?;
    if ![record.started_at, record.finished_at].into_iter().all(|at| (1..=9_007_199_254_740_991).contains(&at)) { return None; }
    let mobile = [record.started_active, record.finished_active, record.left_app];
    if record.origin == Origin::Desktop && mobile.iter().any(Option::is_some) { return None; }
    if record.origin != Origin::Desktop && mobile.iter().any(Option::is_none) { return None; }
    serde_json::to_value(record).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn origins_survive_explicit_worker_handoff_without_leaking_to_other_work() {
        let original = Origin::current();
        let work = scope(Origin::BackgroundRefresh, async {
            let origin = Origin::current();
            tokio::spawn(scope(origin, async { Run::start().finish()["origin"].clone() })).await.unwrap()
        });
        let (background, other) = tokio::join!(work, async { Run::start().finish()["origin"].clone() });
        assert_eq!(background, "backgroundRefresh");
        assert_eq!(other, serde_json::to_value(original).unwrap());
        assert_eq!(Origin::current(), original);
    }

    #[test]
    fn leaving_and_returning_keeps_the_original_operation_and_records_the_transition() {
        let run = Run { origin: Origin::App, at: 100, clock: Instant::now(), activity: Activity { active: Some(true), suspensions: 4 }, remaining_text: false };
        let record = run.finished(200, Activity { active: Some(true), suspensions: 5 });
        assert_eq!(record, json!({"origin":"app","startedAt":100,"finishedAt":200,"startedActive":true,"finishedActive":true,"leftApp":true}));
        assert_eq!(clean(&record), Some(record));
        assert_eq!(run.finished(200, Activity { active: Some(false), suspensions: 5 })["finishedActive"], false);
        assert_eq!(run.finished(200, Activity { active: Some(false), suspensions: 4 })["leftApp"], true);
    }

    #[test]
    fn unknown_history_and_untrusted_fields_do_not_become_processing_records() {
        for value in [Value::Null, json!({}), json!({"origin":"backgroundRefresh"}), json!({"origin":"desktop","startedAt":1,"finishedAt":2,"mail":"private"}), json!({"origin":"app","startedAt":1,"finishedAt":2}), json!({"origin":"desktop","startedAt":0,"finishedAt":2})] {
            assert_eq!(clean(&value), None);
        }
        assert!(clean(&json!({"origin":"desktop","startedAt":1,"finishedAt":2})).is_some());
    }
}
