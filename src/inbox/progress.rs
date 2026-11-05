use std::sync::{Arc, Mutex};

#[derive(Default, Clone)]
pub(super) struct Progress(Arc<Mutex<Option<Arc<Work>>>>);

struct Work {
    account: String,
    ids: Vec<String>,
}

pub(super) struct Running {
    progress: Progress,
    work: Arc<Work>,
}

impl Progress {
    pub(super) fn begin(&self, account: &str, ids: &[String]) -> Running {
        let work = Arc::new(Work {
            account: account.to_owned(),
            ids: ids.to_vec(),
        });
        *self.0.lock().unwrap_or_else(|error| error.into_inner()) = Some(work.clone());
        Running { progress: self.clone(), work }
    }

    pub(super) fn ids(&self, account: &str) -> Vec<String> {
        self.0.lock().unwrap_or_else(|error| error.into_inner())
            .as_ref().filter(|work| work.account == account)
            .map(|work| work.ids.clone()).unwrap_or_default()
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        let mut current = self.progress.0.lock().unwrap_or_else(|error| error.into_inner());
        if current.as_ref().is_some_and(|work| Arc::ptr_eq(work, &self.work)) {
            *current = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_is_private_to_its_account_and_ends_with_the_work() {
        let progress = Progress::default();
        assert!(progress.ids("one").is_empty());
        let running = progress.begin("one", &["same-id".into(), "next".into()]);
        assert_eq!(progress.ids("one"), ["same-id", "next"]);
        assert!(progress.ids("two").is_empty());
        assert!(Progress::default().ids("one").is_empty());
        drop(running);
        assert!(progress.ids("one").is_empty());
    }

    #[test]
    fn an_old_guard_cannot_clear_replacement_work() {
        let progress = Progress::default();
        let old = progress.begin("one", &["old".into()]);
        let new = progress.begin("two", &["new".into()]);
        drop(old);
        assert_eq!(progress.ids("two"), ["new"]);
        drop(new);
        assert!(progress.ids("two").is_empty());
    }

    #[tokio::test]
    async fn aborting_a_worker_does_not_leave_a_current_card() {
        let progress = Progress::default();
        let running = progress.begin("one", &["message".into()]);
        let task = tokio::spawn(async move {
            let _running = running;
            std::future::pending::<()>().await;
        });
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(progress.ids("one").is_empty());
    }
}
