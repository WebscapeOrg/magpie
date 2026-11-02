//! Magpie for iPhone's own assistant: questions about mail and drafts, answered by Claude with the
//! phone's own key and kept on the phone. Its calls and replies keep the shapes the main machine's
//! /v1/ai/* gave the phone, so the app changes little.
//!
//! Invariants:
//! - A proposal is content only. Its account, message and draft come from the job, never from
//!   Claude, and only the owner applies it; nothing here edits, sends or moves mail.
//! - Mail and drafts reach Claude only as data inside the owner's JSON context, after the fixed rules.
//! - The history Claude has seen only grows: each request repeats the earlier ones exactly, because
//!   Claude ties its thinking to the exact conversation before it. A history kept under other rules
//!   or another model is not replayed; its conversation is supplied again as text instead.
//! - A turn runs in its own task, never inside an engine call, so a call returns at once and
//!   suspending the engine never waits for Claude. A queued or running turn without a task (the
//!   engine stopped) reads as interrupted and can be asked again.
//! - Backgrounding does not stop a turn: if iOS freezes its connection, the turn fails with a
//!   connection error and can be asked again. Only engine shutdown and account removal stop turns.
use super::{claude, now, store};
use crate::agent::{events, payload, prompt, proposals};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};

type Result<T> = std::result::Result<T, &'static str>;
pub(crate) type Reply = Pin<Box<dyn Future<Output = Result<Value>> + Send>>;
/// Sends one Messages API request body and returns Claude's reply.
pub(crate) type Sender = Arc<dyn Fn(Vec<u8>) -> Reply + Send + Sync>;

const MODEL: &str = claude::ASSISTANT_MODEL;
const MAX_TOKENS: u64 = 16_000;
const EVENTS_MAX_TOKENS: u64 = 4_000;
/// Requests one turn may make: each proposal takes one more.
const ROUNDS: usize = 8;
const ACTIVE_LIMIT: usize = 4;
const KEEP: usize = 200;
/// The app pages the history 32 at a time and moves on by 32 whatever it receives.
const PAGE: usize = 32;
const HISTORY_TURNS: usize = 8;
const HISTORY_BYTES: usize = 8 * 1024 * 1024;
const ANSWER_LIMIT: usize = 64 * 1024;
const TRANSCRIPT_ITEMS: usize = 200;
const TRANSCRIPT_BYTES: usize = 512 * 1024;
/// Below the store's 8 MiB file limit.
const RECORD_LIMIT: usize = 7 * 1024 * 1024;
/// The most history a follow-up replays. A longer one is supplied again as text, so a request stays
/// well inside Sonnet's context window and a follow-up's record inside RECORD_LIMIT.
const REPLAY_LIMIT: usize = 1024 * 1024;
/// The most the assistant keeps on the phone across all its questions; the oldest go first.
const TOTAL_BYTES: u64 = 256 * 1024 * 1024;
const STATES: [&str; 5] = ["queued", "running", "done", "failed", "cancelled"];
/// Failures the replayed history itself can cause; the failed turn's history is not replayed again.
const HISTORY_FAILURES: [&str; 3] = ["ai_request_rejected", "ai_context_full", "agent_context_too_large"];
/// Q-005 (open): $2 a day of its own, apart from what descriptions spend, until Dave chooses.
/// Billionths of a dollar.
const DAILY_SPEND: u64 = 2_000_000_000;
const DAILY_CALLS: u64 = 400;
const CANCELLED_KEEP: i64 = 31 * 86_400_000;
const CANCELLED_LIMIT: usize = 4096;
const VIEW: [&str; 20] = [
    "id",
    "conversationId",
    "requestPreview",
    "kind",
    "messageIds",
    "state",
    "created",
    "updated",
    "resultReady",
    "canContinue",
    "provider",
    "model",
    "progress",
    "accountId",
    "subject",
    "messageId",
    "draftKey",
    "draftFingerprint",
    "events",
    "error",
];
const START_FIELDS: [&str; 11] = [
    "accountId",
    "messageId",
    "messageIds",
    "draft",
    "prompt",
    "parentId",
    "requestId",
    "issuedAt",
    "events",
    "provider",
    "model",
];
const DRAFT_FIELDS: [&str; 16] = [
    "draftKey",
    "from",
    "to",
    "cc",
    "bcc",
    "replyTo",
    "subject",
    "body",
    "signature",
    "signatureHtml",
    "signatureOffset",
    "draftId",
    "threadId",
    "inReplyTo",
    "references",
    "attachments",
];
const RECORDED: &str = "Recorded for the owner to review. Nothing was changed or sent.";
const INVALID_PROPOSAL: &str = "agent_invalid_proposal: give a one-line subject of at most 4096 characters and a body that is not empty, of at most 65536 characters, and no other fields.";
const PROPOSAL_LIMIT: &str = "agent_proposal_limit: no more drafts can be proposed in this turn.";
const UNKNOWN_TOOL: &str = "Unknown tool. The only tool is propose_draft.";

pub(crate) struct Assistant {
    live: Mutex<HashMap<String, tokio::task::AbortHandle>>,
    sender: Sender,
}

impl Default for Assistant {
    fn default() -> Self {
        Self::with_sender(Arc::new(|body| Box::pin(claude::converse(body))))
    }
}

/// Removes a finished, failed or dropped turn's task from the live set.
struct Live {
    assistant: Arc<Assistant>,
    id: String,
}

impl Drop for Live {
    fn drop(&mut self) {
        if let Ok(mut live) = self.assistant.live.lock() {
            live.remove(&self.id);
        }
    }
}

/// What a turn that completed leaves for the record.
struct Finished {
    messages: Vec<Value>,
    transcript: Vec<Value>,
    proposals: Vec<Value>,
    output: String,
    events: Option<Vec<Value>>,
}

/// The history a new turn starts from.
struct Inherited {
    messages: Vec<Value>,
    seen: Value,
    unseen: Vec<Value>,
}

impl Assistant {
    pub(crate) fn with_sender(sender: Sender) -> Self {
        Self {
            live: Mutex::default(),
            sender,
        }
    }

    fn is_live(&self, id: &str) -> bool {
        self.live.lock().is_ok_and(|live| live.contains_key(id))
    }

    fn active(&self, job: &Value) -> bool {
        active_state(job) && self.is_live(job["id"].as_str().unwrap_or(""))
    }

    /// The job as the app sees it: a queued or running turn with no task was interrupted.
    fn effective(&self, job: &Value) -> Value {
        let mut job = job.clone();
        if active_state(&job) && !self.is_live(job["id"].as_str().unwrap_or("")) {
            job["state"] = json!("failed");
            job["error"] = json!("ai_interrupted");
            job["progress"] = json!("Stopped");
            job["resultReady"] = json!(false);
            job["canContinue"] = json!(job["kind"] != "events");
        }
        job
    }

    fn view(&self, job: &Value) -> Value {
        project(&self.effective(job), &VIEW)
    }

    /// Stops every running turn when the engine shuts down; each then reads as interrupted.
    pub(crate) fn stop_all(&self) {
        if let Ok(mut live) = self.live.lock() {
            for (_, task) in live.drain() {
                task.abort();
            }
        }
    }

    /// Forgets every question and answer about a removed account, and stops its running turns.
    pub(crate) fn forget_account(&self, account: &str) -> Result<()> {
        let removed = store::update(&index_name(), |index| {
            normalize(index)?;
            let mut removed = Vec::new();
            jobs_mut(index)?.retain(|job| {
                if job["accountId"] == account {
                    removed.push(job["id"].as_str().unwrap_or("").to_owned());
                    false
                } else {
                    true
                }
            });
            Ok(removed)
        })?;
        // Invariant: a record goes only after the index no longer names it, so a failed write never
        // leaves a listed question without its record. A turn still running finds its job gone and
        // writes nothing more.
        if let Ok(mut live) = self.live.lock() {
            for id in &removed {
                if let Some(task) = live.remove(id) {
                    task.abort();
                }
            }
        }
        for id in removed {
            store::remove(&record_name(&id))?;
        }
        Ok(())
    }

    /// The job a question already started, when this exact request was accepted before. A different
    /// question under the same request is refused.
    pub(crate) fn accepted(&self, p: &Value) -> Result<Option<Value>> {
        let (Ok(account), Ok(request)) = (bounded(p, "accountId", 1024), bounded(p, "requestId", 128))
        else {
            return Ok(None);
        };
        let index = read_index()?;
        let Some(existing) = find(&index, &job_id(&account, &request)) else {
            return Ok(None);
        };
        let digest = hex(&serde_json::to_vec(p).map_err(|_| "invalid_params")?);
        if existing["accountId"] != account || existing["submissionDigest"] != digest {
            return Err("agent_submission_conflict");
        }
        Ok(Some(self.view(existing)))
    }

    /// Accepts a question and starts its turn. `build` reads the named messages from Gmail into a
    /// context, as the desktop's `agent.context` does. Returns the queued job at once.
    pub(crate) async fn start<B, F>(self: &Arc<Self>, p: &Value, build: B) -> Result<Value>
    where
        B: FnOnce(Value) -> F,
        F: Future<Output = Result<Value>>,
    {
        let fields = p.as_object().ok_or("invalid_params")?;
        if fields.keys().any(|key| !START_FIELDS.contains(&key.as_str())) {
            return Err("invalid_params");
        }
        let account = bounded(p, "accountId", 1024)?;
        let request = bounded(p, "requestId", 128)?;
        if p.get("events").is_some_and(|value| !value.is_boolean()) {
            return Err("invalid_params");
        }
        let looking = p["events"] == true;
        // Invariant: Claude and its model are fixed on the phone; a main-machine choice is refused,
        // not silently replaced.
        for key in ["provider", "model"] {
            if p.get(key).is_some_and(|value| !value.is_null() && value != "") {
                return Err("invalid_params");
            }
        }
        let ids = selection(p)?;
        let parent = match p.get("parentId") {
            None | Some(Value::Null) => None,
            Some(Value::String(parent)) if parent.is_empty() => None,
            Some(Value::String(parent)) => {
                payload::check_id(parent)?;
                Some(parent.clone())
            }
            Some(_) => return Err("invalid_params"),
        };
        if looking && parent.is_some() {
            return Err("invalid_params");
        }
        let ask = p["prompt"]
            .as_str()
            .filter(|s| {
                !s.trim().is_empty()
                    && s.len() <= 200_000
                    && !s
                        .chars()
                        .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
            })
            .ok_or("invalid_params")?;
        let at = now();
        p["issuedAt"]
            .as_i64()
            .filter(|time| *time <= at + 60_000 && *time > at - 30 * 86_400_000)
            .ok_or("ai_request_expired")?;
        let id = job_id(&account, &request);
        let digest = hex(&serde_json::to_vec(p).map_err(|_| "invalid_params")?);
        let index = read_index()?;
        if index["cancelled"].get(&id).is_some() {
            return Err("agent_cancelled");
        }
        if let Some(existing) = find(&index, &id) {
            if existing["accountId"] != account || existing["submissionDigest"] != digest {
                return Err("agent_submission_conflict");
            }
            return Ok(self.view(existing));
        }
        spend_left(at)?;
        let draft = p["draft"].as_object().map(draft_fields).transpose()?;
        let context = if let Some(parent) = &parent {
            let job = find(&index, parent).ok_or("agent_job_missing")?;
            if job["accountId"] != account {
                return Err("agent_context_owner_mismatch");
            }
            let mut continuation = json!({"parent":parent,"prompt":ask});
            if let Some(draft) = &draft {
                let mut fields = json!({});
                for key in ["from", "to", "cc", "bcc", "subject", "body"] {
                    fields[key] = draft.get(key).cloned().unwrap_or(json!(""));
                }
                continuation["draftUpdate"] = json!({"accountId":account,"draftKey":draft.get("draftKey").cloned().unwrap_or(json!("")),"draft":fields});
            } else {
                let mut original: Vec<String> = job["messageIds"]
                    .as_array()
                    .ok_or("agent_invalid_record")?
                    .iter()
                    .filter_map(|id| id.as_str().map(str::to_owned))
                    .collect();
                let mut selected = ids.clone();
                original.sort();
                selected.sort();
                if original != selected {
                    return Err("agent_context_owner_mismatch");
                }
                if ids.len() == 1 {
                    let built = build(json!({"accountId":account,"requestId":request,"ids":[ids[0]],"summaries":[{"id":ids[0]}],"folder":"","prompt":ask})).await?;
                    continuation["mailUpdate"] = project(
                        &built["payload"],
                        &[
                            "accountId",
                            "messageId",
                            "message",
                            "threadContext",
                            "threadMessages",
                        ],
                    );
                }
            }
            payload::validate_payload(&continuation)?;
            let previous = read_record(parent)?["context"].clone();
            payload::continue_context(previous, &continuation, parent)?
        } else if let Some(draft) = draft {
            payload::draft_payload(&json!({"draftFields":draft,"ask":ask,"account":address(&account),"accountId":account}))?
        } else {
            let summaries: Vec<_> = ids.iter().map(|id| json!({"id":id})).collect();
            let built = build(json!({"accountId":account,"requestId":request,"ids":ids,"summaries":summaries,"folder":"","prompt":ask})).await?;
            let mut context = built["payload"].clone();
            if looking {
                context = project(
                    &context,
                    &["accountId", "messageId", "account", "subject", "message", "folder"],
                );
                context["events"] = json!(true);
                context["prompt"] = json!("Find the calendar events in this message.");
            }
            payload::validate_payload(&context)?
        };
        if context["accountId"] != account {
            return Err("agent_context_owner_mismatch");
        }
        if context["messageId"].as_str().unwrap_or("").is_empty()
            && context.get("messages").is_none()
            && !context["draft"].is_object()
        {
            return Err("agent_context_required");
        }
        if serde_json::to_vec(&context)
            .map_err(|_| "agent_invalid_context")?
            .len()
            > payload::INPUT_LIMIT
        {
            return Err("agent_context_too_large");
        }
        self.admit(&id, &account, &digest, parent.as_deref(), context, ask)
    }

    /// Records the job and starts its task under the index lock, so no reader ever sees the
    /// queued job without its task, and a cancel that came first wins.
    fn admit(
        self: &Arc<Self>,
        id: &str,
        account: &str,
        digest: &str,
        parent: Option<&str>,
        context: Value,
        ask: &str,
    ) -> Result<Value> {
        let (view, trimmed) = store::update(&index_name(), |index| {
            normalize(index)?;
            if index["cancelled"].get(id).is_some() {
                return Err("agent_cancelled");
            }
            if let Some(existing) = find(index, id) {
                if existing["accountId"] != account || existing["submissionDigest"] != digest {
                    return Err("agent_submission_conflict");
                }
                return Ok((self.view(existing), Vec::new()));
            }
            let jobs = index["jobs"].as_array().ok_or("inbox_storage_invalid")?;
            if jobs.iter().filter(|job| self.active(job)).count() >= ACTIVE_LIMIT {
                return Err("agent_active_limit");
            }
            let (conversation, inherited) = match parent {
                Some(parent) => {
                    let job = find(index, parent).ok_or("agent_job_missing")?;
                    if job["accountId"] != account {
                        return Err("agent_context_owner_mismatch");
                    }
                    let conversation = job["conversationId"].as_str().unwrap_or(parent);
                    let mut turns = jobs
                        .iter()
                        .filter(|job| job["conversationId"].as_str() == Some(conversation));
                    if jobs.iter().any(|job| {
                        job["conversationId"].as_str() == Some(conversation) && self.active(job)
                    }) {
                        return Err("agent_conversation_busy");
                    }
                    if turns.next().is_none_or(|head| head["id"] != parent) {
                        return Err("agent_parent_not_latest");
                    }
                    if self.effective(job)["canContinue"] != true {
                        return Err("agent_parent_not_ready");
                    }
                    (conversation.to_owned(), self.inherit(index, parent)?)
                }
                None => (
                    id.to_owned(),
                    Inherited {
                        messages: Vec::new(),
                        seen: Value::Null,
                        unseen: Vec::new(),
                    },
                ),
            };
            let preview: String = ask
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(120)
                .collect();
            let mut job = json!({
                "id": id,
                "conversationId": conversation,
                "parentId": parent.unwrap_or(""),
                "requestPreview": preview.trim_end(),
                "kind": payload::context_kind(&context),
                "messageIds": payload::context_message_ids(&context),
                "state": "queued",
                "created": payload::now(),
                "updated": payload::now(),
                "resultReady": false,
                "canContinue": false,
                "provider": "claude",
                "model": MODEL,
                "progress": "Starting...",
                "submissionDigest": digest,
            });
            for key in [
                "accountId",
                "subject",
                "messageId",
                "draftKey",
                "draftFingerprint",
            ] {
                job[key] = context.get(key).cloned().unwrap_or(json!(""));
            }
            let record = json!({
                "context": context,
                "messages": inherited.messages,
                "promptVersion": version(),
                "seen": inherited.seen,
                "unseen": inherited.unseen,
                "transcript": [{"role":"user","text":ask}],
                "proposals": [],
                "output": "",
            });
            job["bytes"] = json!(write_record(id, &record)?);
            let jobs = jobs_mut(index)?;
            jobs.insert(0, job.clone());
            // The oldest finished questions make room, never the one just asked or a running one.
            let mut trimmed = Vec::new();
            while jobs.len() > KEEP || kept_bytes(jobs) > TOTAL_BYTES {
                let Some(oldest) = (1..jobs.len()).rev().find(|at| !self.active(&jobs[*at])) else {
                    break;
                };
                let gone = jobs.remove(oldest);
                trimmed.push(gone["id"].as_str().unwrap_or("").to_owned());
            }
            // The task is in the live set before the index is written, so no reader sees the queued
            // job without it. The turn waits for this write before it begins.
            let mut live = self.live.lock().map_err(|_| "agent_worker_failed")?;
            let task = tokio::spawn(run(self.clone(), id.to_owned()));
            live.insert(id.to_owned(), task.abort_handle());
            Ok((project(&job, &VIEW), trimmed))
        })?;
        // Invariant: a record goes only after the index no longer names it. One left behind by a
        // failed removal is unreachable and costs only space.
        for gone in trimmed {
            let _ = store::remove(&record_name(&gone));
        }
        Ok(view)
    }

    /// The history a follow-up to `parent` starts from. Claude has seen the parent's messages; a
    /// stopped parent's question and any answer it wrote are passed on as conversation it missed.
    fn inherit(&self, index: &Value, parent: &str) -> Result<Inherited> {
        let record = read_record(parent)?;
        let job = find(index, parent).ok_or("agent_job_missing")?;
        let messages = record["messages"]
            .as_array()
            .ok_or("agent_invalid_record")?
            .clone();
        // A history too long to replay safely is supplied again as text, like one kept under other rules.
        if record["promptVersion"] == version()
            && !messages.is_empty()
            && encoded_len(&record["messages"])? <= REPLAY_LIMIT
        {
            let mut unseen = record["unseen"]
                .as_array()
                .ok_or("agent_invalid_record")?
                .clone();
            if self.effective(job)["state"] != "done" {
                unseen.extend(
                    record["transcript"]
                        .as_array()
                        .ok_or("agent_invalid_record")?
                        .iter()
                        .cloned(),
                );
            }
            // A finished turn keeps no separate copy of what Claude saw: it saw the turn's context.
            let seen = if record["seen"].is_null() {
                record["context"].clone()
            } else {
                record["seen"].clone()
            };
            return Ok(Inherited {
                messages,
                seen,
                unseen: newest(unseen),
            });
        }
        // Claude has seen none of this conversation, or saw it under other rules or another
        // model: start again with the whole conversation supplied as text.
        let mut turns = Vec::new();
        let mut cursor = parent.to_owned();
        while turns.len() < KEEP {
            let Some(turn) = find(index, &cursor) else {
                break;
            };
            let Some(record) = store::read(&record_name(&cursor))? else {
                break;
            };
            turns.push(record["transcript"].as_array().cloned().unwrap_or_default());
            cursor = turn["parentId"].as_str().unwrap_or("").to_owned();
            if cursor.is_empty() {
                break;
            }
        }
        Ok(Inherited {
            messages: Vec::new(),
            seen: Value::Null,
            unseen: newest(turns.into_iter().rev().flatten().collect()),
        })
    }

    /// The job, its latest answer, and up to eight turns of its conversation, ending at `before`
    /// when given; `previous` names the turn before them.
    pub(crate) fn show(&self, p: &Value) -> Result<Value> {
        let index = read_index()?;
        let id = self.named(p, &["id", "before", "requestId", "accountId"])?;
        let job = find(&index, &id).ok_or("agent_job_missing")?;
        if p.get("accountId").is_some_and(|account| account != &job["accountId"]) {
            return Err("agent_context_owner_mismatch");
        }
        let before = p
            .get("before")
            .map(|value| value.as_str().ok_or("invalid_params"))
            .transpose()?
            .unwrap_or("");
        if !before.is_empty() {
            payload::check_id(before)?;
        }
        let conversation = job["conversationId"].as_str().unwrap_or(&id);
        let mut cursor = if before.is_empty() { id.clone() } else { before.to_owned() };
        let mut chunks = Vec::new();
        let mut budget = 0;
        let mut visited = std::collections::HashSet::new();
        while !cursor.is_empty() && chunks.len() < HISTORY_TURNS {
            if !visited.insert(cursor.clone()) {
                return Err("agent_invalid_history");
            }
            let Some(turn) = find(&index, &cursor) else {
                cursor.clear();
                break;
            };
            if turn["accountId"] != job["accountId"]
                || turn["conversationId"].as_str() != Some(conversation)
            {
                return Err("agent_context_owner_mismatch");
            }
            let record = read_record(&cursor)?;
            let ready = self.effective(turn)["state"] == "done";
            let (said, cards) = checked_turn(&record, turn, ready)?;
            let chunk = json!({"transcript":said,"proposals":cards});
            let size = serde_json::to_vec(&chunk)
                .map_err(|_| "agent_invalid_history")?
                .len();
            // The turn asked about is always shown; earlier ones while they fit.
            if !chunks.is_empty() && budget + size > HISTORY_BYTES {
                break;
            }
            budget += size;
            chunks.push(chunk);
            cursor = turn["parentId"].as_str().unwrap_or("").to_owned();
        }
        let mut transcript = Vec::new();
        let mut cards = Vec::new();
        for chunk in chunks.into_iter().rev() {
            for card in chunk["proposals"].as_array().into_iter().flatten() {
                let mut card = card.clone();
                card["afterTurn"] = json!(
                    (transcript.len() as u64).saturating_add(card["afterTurn"].as_u64().unwrap_or(0))
                );
                cards.push(card);
            }
            transcript.extend(chunk["transcript"].as_array().into_iter().flatten().cloned());
        }
        let output = read_record(&id)?["output"]
            .as_str()
            .ok_or("agent_invalid_record")?
            .to_owned();
        Ok(json!({"job":self.view(job),"output":output,"transcript":transcript,"proposals":cards,"previous":cursor}))
    }

    /// One page of questions, newest first.
    pub(crate) fn list(&self, p: &Value) -> Result<Value> {
        let fields = p.as_object().ok_or("invalid_params")?;
        if fields.keys().any(|key| key != "offset") {
            return Err("invalid_params");
        }
        let offset = p
            .get("offset")
            .map(|value| value.as_u64().ok_or("invalid_params"))
            .transpose()?
            .unwrap_or(0) as usize;
        let index = read_index()?;
        let all = index["jobs"].as_array().map(Vec::as_slice).unwrap_or(&[]);
        let page: Vec<_> = all.iter().skip(offset).take(PAGE).map(|job| self.view(job)).collect();
        let more = offset.saturating_add(page.len()) < all.len();
        Ok(json!({"jobs":page,"hasMore":more}))
    }

    /// Stops a question. Named by its request, it is refused later even if it has not arrived yet.
    pub(crate) fn cancel(&self, p: &Value) -> Result<Value> {
        let id = self.named(p, &["id", "requestId", "accountId"])?;
        let by_request = p["id"].as_str().is_none_or(str::is_empty);
        let at = now();
        store::update(&index_name(), |index| {
            normalize(index)?;
            if by_request {
                let cancelled = index["cancelled"]
                    .as_object_mut()
                    .ok_or("inbox_storage_invalid")?;
                cancelled.retain(|_, time| time.as_i64().is_some_and(|t| t > at - CANCELLED_KEEP));
                if cancelled.len() >= CANCELLED_LIMIT {
                    return Err("agent_cancel_limit");
                }
                cancelled.insert(id.clone(), json!(at));
                if find(index, &id).is_none() {
                    return Ok(json!({"cancelled":true}));
                }
            }
            let job = find(index, &id).ok_or("agent_job_missing")?;
            if p.get("accountId").is_some_and(|account| account != &job["accountId"]) {
                return Err("agent_context_owner_mismatch");
            }
            // An interrupted job (queued or running with no task) is cancelled on disk too.
            if active_state(job) {
                let events = job["kind"] == "events";
                let job = find_mut(index, &id).ok_or("agent_job_missing")?;
                job["state"] = json!("cancelled");
                job["progress"] = json!("Stopped");
                job["canContinue"] = json!(!events);
                job["updated"] = json!(payload::now());
                if let Ok(mut live) = self.live.lock() {
                    if let Some(task) = live.remove(&id) {
                        task.abort();
                    }
                }
            }
            Ok(self.view(find(index, &id).ok_or("agent_job_missing")?))
        })
    }

    /// The job a show or cancel names: by `id`, or by the account and request that started it.
    fn named(&self, p: &Value, allowed: &[&str]) -> Result<String> {
        let fields = p.as_object().ok_or("invalid_params")?;
        if fields.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err("invalid_params");
        }
        if let Some(id) = p["id"].as_str().filter(|id| !id.is_empty()) {
            payload::check_id(id)?;
            return Ok(id.to_owned());
        }
        Ok(job_id(
            &bounded(p, "accountId", 1024)?,
            &bounded(p, "requestId", 128)?,
        ))
    }

    /// Marks the job running, or returns None when it was cancelled or forgotten first.
    fn begin(&self, id: &str) -> Result<Option<Value>> {
        store::update(&index_name(), |index| {
            normalize(index)?;
            let Some(job) = find_mut(index, id) else {
                return Ok(None);
            };
            if job["state"] != "queued" {
                return Ok(None);
            }
            job["state"] = json!("running");
            job["progress"] = json!("Thinking...");
            job["updated"] = json!(payload::now());
            Ok(Some(job.clone()))
        })
    }

    /// Saves what the turn has shown so far, while it is still running.
    fn progress(
        &self,
        id: &str,
        transcript: &[Value],
        proposals: &[Value],
        output: &str,
        label: &str,
    ) -> Result<()> {
        store::update(&index_name(), |index| {
            normalize(index)?;
            let Some(job) = find_mut(index, id) else {
                return Ok(());
            };
            if job["state"] != "running" {
                return Ok(());
            }
            let mut record = read_record(id)?;
            record["transcript"] = json!(transcript);
            record["proposals"] = json!(proposals);
            record["output"] = json!(output);
            job["bytes"] = json!(write_record(id, &record)?);
            job["progress"] = json!(label);
            job["updated"] = json!(payload::now());
            Ok(())
        })
    }

    fn finish(&self, id: &str, finished: &Finished) -> Result<()> {
        store::update(&index_name(), |index| {
            normalize(index)?;
            let Some(job) = find_mut(index, id) else {
                return Ok(());
            };
            if job["state"] != "running" {
                return Ok(());
            }
            let looking = job["kind"] == "events";
            let mut record = read_record(id)?;
            record["transcript"] = json!(finished.transcript);
            record["proposals"] = json!(finished.proposals);
            record["output"] = json!(finished.output);
            if !looking {
                record["messages"] = json!(finished.messages);
                record["promptVersion"] = json!(version());
                // Claude has now seen this turn's context; `inherit` reads an empty `seen` as that.
                record["seen"] = Value::Null;
                record["unseen"] = json!([]);
            }
            if encoded_len(&record)? > RECORD_LIMIT {
                // Too long to keep for replay: a follow-up supplies the conversation again as text.
                record["messages"] = json!([]);
                record["promptVersion"] = json!("");
            }
            job["bytes"] = json!(write_record(id, &record)?);
            job["state"] = json!("done");
            job["progress"] = json!("Done");
            job["resultReady"] = json!(true);
            job["canContinue"] = json!(!looking);
            job["updated"] = json!(payload::now());
            if let Some(found) = &finished.events {
                job["summary"] = json!(events::summary(found));
                job["events"] = json!(found);
            }
            Ok(())
        })
    }

    fn fail(&self, id: &str, error: &'static str) -> Result<()> {
        store::update(&index_name(), |index| {
            normalize(index)?;
            let Some(job) = find_mut(index, id) else {
                return Ok(());
            };
            if !active_state(job) {
                return Ok(());
            }
            // Invariant: a history Claude could not take is not replayed again, or every follow-up
            // would fail the same way; the next turn supplies the conversation as text instead.
            if HISTORY_FAILURES.contains(&error) {
                if let Ok(mut record) = read_record(id) {
                    record["messages"] = json!([]);
                    record["promptVersion"] = json!("");
                    if let Ok(size) = write_record(id, &record) {
                        job["bytes"] = json!(size);
                    }
                }
            }
            job["state"] = json!("failed");
            job["error"] = json!(error);
            job["progress"] = json!("Failed");
            job["resultReady"] = json!(false);
            job["canContinue"] = json!(job["kind"] != "events");
            job["updated"] = json!(payload::now());
            Ok(())
        })
    }

    /// Asks Claude until it answers, at most ROUNDS requests. A proposal is recorded and its
    /// result returned to Claude, which then goes on.
    async fn turn(&self, id: &str) -> Result<Option<Finished>> {
        let Some(job) = self.begin(id)? else {
            return Ok(None);
        };
        let record = read_record(id)?;
        let context = &record["context"];
        let looking = job["kind"] == "events";
        let mut transcript = record["transcript"]
            .as_array()
            .ok_or("agent_invalid_record")?
            .clone();
        let (mut body, max_tokens) = if looking {
            (
                json!({"model":MODEL,"max_tokens":EVENTS_MAX_TOKENS,"output_config":{"effort":"low"},"messages":[{"role":"user","content":events::prompt(context)}]}),
                EVENTS_MAX_TOKENS,
            )
        } else {
            let mut messages = record["messages"]
                .as_array()
                .ok_or("agent_invalid_record")?
                .clone();
            let unseen = record["unseen"].as_array().ok_or("agent_invalid_record")?;
            messages.push(json!({"role":"user","content":ask(context, &record["seen"], unseen, messages.is_empty())?}));
            (
                json!({"model":MODEL,"max_tokens":MAX_TOKENS,"output_config":{"effort":"low"},"cache_control":{"type":"ephemeral"},"system":prompt::MAIL_ROLE,"tools":[tool()],"messages":messages}),
                MAX_TOKENS,
            )
        };
        let mut cards: Vec<Value> = Vec::new();
        let mut output = String::new();
        for _ in 0..ROUNDS {
            let bytes = serde_json::to_vec(&body).map_err(|_| "ai_request_rejected")?;
            if bytes.len() > claude::REQUEST_LIMIT {
                return Err("agent_context_too_large");
            }
            let reserved = reservation(bytes.len(), max_tokens);
            admit_call(reserved, now())?;
            let reply = match (self.sender)(bytes).await {
                Ok(reply) => reply,
                Err(error) => {
                    // A request Claude refused costs nothing. One cut off on the way back may
                    // have been charged, so its reservation stays counted.
                    if !matches!(error, "ai_unreachable" | "ai_invalid_response") {
                        let _ = settle(reserved, 0, now());
                    }
                    return Err(error);
                }
            };
            let _ = settle(reserved, cost(&reply), now());
            let content = reply["content"]
                .as_array()
                .filter(|blocks| blocks.iter().all(Value::is_object))
                .ok_or("ai_invalid_response")?
                .clone();
            let text: String = content
                .iter()
                .filter(|block| block["type"] == "text")
                .filter_map(|block| block["text"].as_str())
                .collect();
            let stop = reply["stop_reason"].as_str().unwrap_or("");
            if looking {
                return match stop {
                    "end_turn" | "stop_sequence" => {
                        let found = events::parse(&text);
                        transcript.push(json!({"role":"assistant","text":events::summary(&found)}));
                        Ok(Some(Finished {
                            messages: Vec::new(),
                            transcript,
                            proposals: Vec::new(),
                            output: events::summary(&found),
                            events: Some(found),
                        }))
                    }
                    "refusal" => Err("ai_refused"),
                    "max_tokens" => Err("ai_answer_cut"),
                    "model_context_window_exceeded" => Err("ai_context_full"),
                    _ => Err("ai_invalid_response"),
                };
            }
            body["messages"]
                .as_array_mut()
                .ok_or("ai_request_rejected")?
                .push(json!({"role":"assistant","content":content}));
            let text = clean(&text);
            if !text.trim().is_empty() {
                if text.len() > ANSWER_LIMIT {
                    return Err("ai_answer_cut");
                }
                output = text.trim().to_owned();
                transcript.push(json!({"role":"assistant","text":output}));
            }
            let mut results = Vec::new();
            if stop == "tool_use" {
                for call in content.iter().filter(|block| block["type"] == "tool_use") {
                    let tool = call["id"]
                        .as_str()
                        .filter(|tool| !tool.is_empty() && tool.len() <= 256)
                        .ok_or("ai_invalid_response")?;
                    let (answer, refused) = if call["name"] == "propose_draft" {
                        transcript.push(json!({"role":"status","text":"Creating draft"}));
                        match proposals::validate(&call["input"]) {
                            Ok(_) if cards.len() >= proposals::MAX_PROPOSALS => (PROPOSAL_LIMIT, true),
                            Ok(draft) => {
                                cards.push(json!({"id":format!("{id}-{}", cards.len()),"jobId":id,"accountId":job["accountId"],"messageId":job["messageId"],"draftKey":job["draftKey"],"afterTurn":transcript.len(),"subject":draft["subject"],"body":draft["body"]}));
                                (RECORDED, false)
                            }
                            Err(_) => (INVALID_PROPOSAL, true),
                        }
                    } else {
                        (UNKNOWN_TOOL, true)
                    };
                    results.push(json!({"type":"tool_result","tool_use_id":tool,"content":answer,"is_error":refused}));
                }
                if results.is_empty() {
                    return Err("ai_invalid_response");
                }
            }
            if transcript.len() > TRANSCRIPT_ITEMS || encoded_len(&json!(transcript))? > TRANSCRIPT_BYTES
            {
                return Err("ai_answer_cut");
            }
            match stop {
                "end_turn" | "stop_sequence" => {
                    return Ok(Some(Finished {
                        messages: body["messages"].as_array().cloned().unwrap_or_default(),
                        transcript,
                        proposals: cards,
                        output,
                        events: None,
                    }));
                }
                "tool_use" => {
                    body["messages"]
                        .as_array_mut()
                        .ok_or("ai_request_rejected")?
                        .push(json!({"role":"user","content":results}));
                    self.progress(id, &transcript, &cards, &output, "Creating draft")?;
                }
                "refusal" => return Err("ai_refused"),
                "max_tokens" => return Err("ai_answer_cut"),
                "model_context_window_exceeded" => return Err("ai_context_full"),
                _ => return Err("ai_invalid_response"),
            }
        }
        Err("ai_turn_limit")
    }
}

async fn run(assistant: Arc<Assistant>, id: String) {
    let _live = Live {
        assistant: assistant.clone(),
        id: id.clone(),
    };
    // Invariant: an answer Claude was paid for is kept whenever the phone can write it. A brief
    // storage problem is tried again; an answer that still cannot be kept fails the job with the
    // reason. Only a store that takes no write at all leaves the job to read as interrupted.
    let _ = match assistant.turn(&id).await {
        Ok(Some(finished)) => match recorded(|| assistant.finish(&id, &finished)).await {
            Err(error) => recorded(|| assistant.fail(&id, error)).await,
            done => done,
        },
        Ok(None) => Ok(()),
        Err(error) => recorded(|| assistant.fail(&id, error)).await,
    };
}

/// Runs a store change, trying again a few times after a pause when the store was briefly busy
/// or unavailable.
async fn recorded(change: impl Fn() -> Result<()>) -> Result<()> {
    for _ in 0..3 {
        match change() {
            Err("private_fs_busy" | "inbox_storage_unavailable") => {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            done => return done,
        }
    }
    change()
}

/// The owner's message for a new turn: the rules and the whole context to start a conversation,
/// then only what changed since Claude last saw it.
fn ask(context: &Value, seen: &Value, unseen: &[Value], fresh: bool) -> Result<String> {
    if fresh {
        let supplied = prompt::turn(context, None, unseen, false);
        let text = serde_json::to_string(&supplied).map_err(|_| "agent_invalid_context")?;
        return Ok(format!(
            "{}{}\n\n{text}",
            prompt::INSTRUCTIONS,
            prompt::DRAFTS
        ));
    }
    let mut supplied = prompt::turn(context, Some(seen), &[], true);
    if !unseen.is_empty() {
        supplied["conversation"] = json!(unseen);
    }
    serde_json::to_string(&supplied).map_err(|_| "agent_invalid_context")
}

/// The proposal tool in the Messages API's shape.
fn tool() -> Value {
    let tool = proposals::tool();
    json!({"name":tool["name"],"description":tool["description"],"input_schema":tool["inputSchema"]})
}

/// Names the model, system prompt and tools a history was made under, which Claude checks when
/// the history is sent again.
fn version() -> String {
    let rules = json!({"model":MODEL,"system":prompt::MAIL_ROLE,"tools":[tool()]});
    hex(&serde_json::to_vec(&rules).unwrap_or_default())[..16].to_owned()
}

fn selection(p: &Value) -> Result<Vec<String>> {
    if p.get("draft").is_some_and(|draft| !draft.is_object()) {
        return Err("invalid_params");
    }
    if p["draft"].is_object() {
        if p.get("messageId").is_some() || p.get("messageIds").is_some() || p["events"] == true {
            return Err("invalid_params");
        }
        return Ok(Vec::new());
    }
    let ids = if let Some(ids) = p.get("messageIds") {
        if p.get("messageId").is_some() {
            return Err("invalid_params");
        }
        ids.as_array()
            .filter(|ids| !ids.is_empty() && ids.len() <= 20)
            .ok_or("invalid_params")?
            .clone()
    } else {
        vec![json!(bounded(p, "messageId", 4096)?)]
    };
    let mut chosen: Vec<String> = Vec::new();
    for id in &ids {
        let id = id.as_str().ok_or("invalid_params")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        if chosen.iter().any(|known| known == id) {
            return Err("invalid_params");
        }
        chosen.push(id.to_owned());
    }
    if p["events"] == true && chosen.len() != 1 {
        return Err("invalid_params");
    }
    Ok(chosen)
}

/// The editor fields Claude may read. Attachments and signatures stay on the phone.
fn draft_fields(draft: &serde_json::Map<String, Value>) -> Result<serde_json::Map<String, Value>> {
    if draft.keys().any(|key| !DRAFT_FIELDS.contains(&key.as_str())) {
        return Err("invalid_params");
    }
    let mut fields = draft.clone();
    for key in ["attachments", "signature", "signatureHtml", "signatureOffset"] {
        fields.remove(key);
    }
    Ok(fields)
}

/// The account's address, which a draft without a sender is from.
fn address(account: &str) -> String {
    crate::account::list_readonly()
        .ok()
        .and_then(|registry| {
            registry["accounts"]
                .as_array()?
                .iter()
                .find(|row| row["id"] == account)
                .and_then(|row| row["email"].as_str().map(str::to_owned))
        })
        .unwrap_or_else(|| account.to_owned())
}

fn bounded(p: &Value, key: &str, limit: usize) -> Result<String> {
    p[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or("invalid_params")
}

fn job_id(account: &str, request: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(b"phone-assistant\0");
    hash.update(account.as_bytes());
    hash.update(b"\0");
    hash.update(request.as_bytes());
    format!("{:x}", hash.finalize())[..32].to_owned()
}

fn hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn project(value: &Value, keys: &[&str]) -> Value {
    json!(
        keys.iter()
            .filter_map(|key| value.get(key).map(|v| ((*key).to_owned(), v.clone())))
            .collect::<serde_json::Map<_, _>>()
    )
}

/// Model text as shown to the owner, without control characters that could disturb a display.
fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| {
            !((*c < ' ' && !matches!(c, '\t' | '\r' | '\n')) || ('\u{7f}'..='\u{9f}').contains(c))
        })
        .collect()
}

/// The newest entries that fit the transcript limits.
fn newest(mut items: Vec<Value>) -> Vec<Value> {
    while !items.is_empty()
        && (items.len() > TRANSCRIPT_ITEMS
            || serde_json::to_vec(&items).map_or(usize::MAX, |bytes| bytes.len())
                > TRANSCRIPT_BYTES)
    {
        items.remove(0);
    }
    items
}

fn active_state(job: &Value) -> bool {
    matches!(job["state"].as_str(), Some("queued" | "running"))
}

fn index_name() -> String {
    store::key(&["assistant"])
}

fn record_name(id: &str) -> String {
    store::key(&["assistant", id])
}

fn ledger_name() -> String {
    store::key(&["assistant-spend"])
}

fn normalize(index: &mut Value) -> Result<()> {
    if !index.is_object() {
        return Err("inbox_storage_invalid");
    }
    if index.get("jobs").is_none() {
        index["jobs"] = json!([]);
    }
    if index.get("cancelled").is_none() {
        index["cancelled"] = json!({});
    }
    if !index["jobs"].is_array() || !index["cancelled"].is_object() {
        return Err("inbox_storage_invalid");
    }
    // Invariant: the index is read back from disk, so an entry unlike what this code writes is
    // dropped, never shown or acted on, and the next write leaves it out.
    jobs_mut(index)?.retain(valid_job);
    index["cancelled"]
        .as_object_mut()
        .ok_or("inbox_storage_invalid")?
        .retain(|id, time| payload::check_id(id).is_ok() && time.is_i64());
    Ok(())
}

/// A job index entry exactly as `admit`, `finish` and `fail` write it.
fn valid_job(job: &Value) -> bool {
    let Some(fields) = job.as_object() else {
        return false;
    };
    let text = |key: &str, limit: usize| {
        fields
            .get(key)
            .is_some_and(|value| payload::text(value).is_ok_and(|text| text.len() <= limit))
    };
    let id = |key: &str| {
        fields
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|id| payload::check_id(id).is_ok())
    };
    let one_of = |key: &str, allowed: &[&str]| {
        fields
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| allowed.contains(&value))
    };
    let flag = |key: &str| fields.get(key).is_some_and(Value::is_boolean);
    let count = |key: &str| fields.get(key).is_some_and(Value::is_u64);
    id("id")
        && id("conversationId")
        && fields
            .get("parentId")
            .and_then(Value::as_str)
            .is_some_and(|parent| parent.is_empty() || payload::check_id(parent).is_ok())
        && one_of("state", &STATES)
        && one_of("kind", &["message", "draft", "events"])
        && fields
            .get("messageIds")
            .and_then(Value::as_array)
            .is_some_and(|ids| {
                ids.len() <= 20
                    && ids
                        .iter()
                        .all(|id| payload::text(id).is_ok_and(|id| !id.is_empty() && id.len() <= 4096))
            })
        && flag("resultReady")
        && flag("canContinue")
        && count("created")
        && count("updated")
        && text("requestPreview", 1024)
        && text("accountId", 1024)
        && text("subject", 4 * 4096)
        && text("messageId", 4 * 4096)
        && text("draftKey", 4 * 4096)
        && text("draftFingerprint", 64)
        && one_of("provider", &["claude"])
        && text("model", 64)
        && text("progress", 64)
        && fields
            .get("submissionDigest")
            .and_then(Value::as_str)
            .is_some_and(|digest| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
        && fields.get("error").is_none_or(|error| {
            error.as_str().is_some_and(|error| {
                !error.is_empty()
                    && error.len() <= 64
                    && error.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
            })
        })
        && fields
            .get("events")
            .is_none_or(|found| events::validate(found).is_ok())
        && fields
            .get("summary")
            .is_none_or(|summary| payload::text(summary).is_ok_and(|summary| summary.len() <= 64))
        && fields.get("bytes").is_none_or(Value::is_u64)
}

/// A turn's transcript and proposal cards as read back from disk, checked against what `turn`
/// writes. Each card's account, message and draft are the turn's own.
fn checked_turn(record: &Value, turn: &Value, ready: bool) -> Result<(Vec<Value>, Vec<Value>)> {
    let invalid = "agent_invalid_record";
    let said = record["transcript"]
        .as_array()
        .filter(|said| said.len() <= TRANSCRIPT_ITEMS)
        .ok_or(invalid)?;
    for entry in said {
        let fields = entry
            .as_object()
            .filter(|fields| fields.len() == 2)
            .ok_or(invalid)?;
        let role = fields.get("role").and_then(Value::as_str).unwrap_or("");
        if !["user", "assistant", "status"].contains(&role)
            || !fields
                .get("text")
                .is_some_and(|text| payload::text(text).is_ok_and(|text| text.len() <= 200_000))
        {
            return Err(invalid);
        }
    }
    let id = turn["id"].as_str().ok_or(invalid)?;
    let saved = record["proposals"]
        .as_array()
        .filter(|cards| cards.len() <= proposals::MAX_PROPOSALS)
        .ok_or(invalid)?;
    let mut cards = Vec::new();
    for (at, card) in saved.iter().enumerate() {
        let draft = proposals::validate(&json!({"subject":card["subject"],"body":card["body"]}))
            .map_err(|_| invalid)?;
        let after = card["afterTurn"]
            .as_u64()
            .filter(|after| *after <= said.len() as u64)
            .ok_or(invalid)?;
        if card["id"] != format!("{id}-{at}")
            || card["jobId"] != id
            || card["accountId"] != turn["accountId"]
            || card["messageId"] != turn["messageId"]
            || card["draftKey"] != turn["draftKey"]
        {
            return Err(invalid);
        }
        cards.push(json!({"id":card["id"],"jobId":id,"accountId":turn["accountId"],"messageId":turn["messageId"],
            "draftKey":turn["draftKey"],"afterTurn":after,"subject":draft["subject"],"body":draft["body"],"applicable":ready}));
    }
    Ok((said.clone(), cards))
}

fn read_index() -> Result<Value> {
    let mut index = store::read(&index_name())?.unwrap_or(json!({}));
    normalize(&mut index)?;
    Ok(index)
}

fn jobs_mut(index: &mut Value) -> Result<&mut Vec<Value>> {
    index["jobs"].as_array_mut().ok_or("inbox_storage_invalid")
}

fn find<'a>(index: &'a Value, id: &str) -> Option<&'a Value> {
    index["jobs"].as_array()?.iter().find(|job| job["id"] == id)
}

fn find_mut<'a>(index: &'a mut Value, id: &str) -> Option<&'a mut Value> {
    index["jobs"].as_array_mut()?.iter_mut().find(|job| job["id"] == id)
}

fn read_record(id: &str) -> Result<Value> {
    store::read(&record_name(id))?
        .filter(Value::is_object)
        .ok_or("agent_context_missing")
}

/// Writes a job's record and returns its size.
fn write_record(id: &str, record: &Value) -> Result<usize> {
    let size = encoded_len(record)?;
    if size > RECORD_LIMIT {
        return Err("agent_context_too_large");
    }
    store::write(&record_name(id), record)?;
    Ok(size)
}

/// What the kept questions' records take on the phone.
fn kept_bytes(jobs: &[Value]) -> u64 {
    jobs.iter()
        .map(|job| job["bytes"].as_u64().unwrap_or(0))
        .fold(0, u64::saturating_add)
}

fn encoded_len(value: &Value) -> Result<usize> {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .map_err(|_| "inbox_storage_invalid")
}

fn today(at: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at)
        .map(|time| time.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn same_day(saved: &mut Value, at: i64) -> Result<()> {
    if !saved.is_object() {
        *saved = json!({});
    }
    let day = today(at);
    if saved["day"].as_str() != Some(day.as_str()) {
        *saved = json!({"day":day,"calls":0,"spent":0});
    }
    Ok(())
}

/// Refuses a new question once today's assistant spending or requests reach their limits.
fn spend_left(at: i64) -> Result<()> {
    let saved = store::read(&ledger_name())?.unwrap_or(json!({}));
    let current = saved["day"].as_str() == Some(today(at).as_str());
    if current
        && (saved["calls"].as_u64().unwrap_or(0) >= DAILY_CALLS
            || saved["spent"].as_u64().unwrap_or(0) >= DAILY_SPEND)
    {
        return Err("ai_daily_limit");
    }
    Ok(())
}

/// Counts a request before it is sent, with the most it could cost; `settle` corrects it to what
/// Claude reports. A request cut off before its reply keeps the reservation.
fn admit_call(reserved: u64, at: i64) -> Result<()> {
    store::update(&ledger_name(), |saved| {
        same_day(saved, at)?;
        let calls = saved["calls"].as_u64().unwrap_or(0);
        let spent = saved["spent"].as_u64().unwrap_or(0);
        // Invariant: after the day's first request, a request is sent only if the most it could
        // cost fits what is left, so the day overshoots the cap by at most that first request.
        if calls >= DAILY_CALLS
            || spent >= DAILY_SPEND
            || (calls > 0 && spent.saturating_add(reserved) > DAILY_SPEND)
        {
            return Err("ai_daily_limit");
        }
        saved["calls"] = json!(calls.saturating_add(1));
        saved["spent"] = json!(spent.saturating_add(reserved));
        Ok(())
    })
}

fn settle(reserved: u64, actual: u64, at: i64) -> Result<()> {
    store::update(&ledger_name(), |saved| {
        let day = today(at);
        let spent = if saved["day"].as_str() == Some(day.as_str()) {
            saved["spent"].as_u64().unwrap_or(0).saturating_sub(reserved)
        } else {
            same_day(saved, at)?;
            0
        };
        saved["spent"] = json!(spent.saturating_add(actual));
        Ok(())
    })
}

/// The most a request can cost: every input token at the cache-write price (about three bytes of
/// JSON make a token, and usually more) and every output token.
fn reservation(bytes: usize, max_tokens: u64) -> u64 {
    (bytes as u64 / 3) * 2_500 + max_tokens * 10_000
}

/// What a reply cost in billionths of a dollar at Sonnet 5.5's prices: $2 per million input
/// tokens, $2.50 per million written to the cache, $0.20 per million read from it, $10 per million
/// output tokens.
fn cost(reply: &Value) -> u64 {
    let usage = &reply["usage"];
    let tokens = |key: &str| usage[key].as_u64().unwrap_or(0);
    [
        ("input_tokens", 2_000u64),
        ("cache_creation_input_tokens", 2_500),
        ("cache_read_input_tokens", 200),
        ("output_tokens", 10_000),
    ]
    .into_iter()
    .fold(0u64, |total, (key, price)| total.saturating_add(tokens(key).saturating_mul(price)))
}

#[cfg(test)]
#[path = "assistant_tests.rs"]
mod tests;
