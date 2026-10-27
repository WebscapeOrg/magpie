CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  date INTEGER NOT NULL,
  summary TEXT NOT NULL,
  blob TEXT NOT NULL,
  server_labels TEXT NOT NULL,
  sender TEXT NOT NULL,
  recipients TEXT NOT NULL,
  copied TEXT NOT NULL,
  subject TEXT NOT NULL,
  filenames TEXT NOT NULL,
  has_attachment INTEGER NOT NULL,
  text_complete INTEGER NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS message_date ON messages(date DESC, id DESC);
CREATE TABLE IF NOT EXISTS labels (
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY(message_id, label)
);
CREATE INDEX IF NOT EXISTS label_messages ON labels(label, message_id);
CREATE TABLE IF NOT EXISTS label_names (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL DEFAULT 'content',
  priority INTEGER NOT NULL DEFAULT 0,
  error TEXT NOT NULL DEFAULT '',
  retry_at INTEGER NOT NULL DEFAULT 0,
  generation INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS job_priority ON jobs(priority DESC, retry_at);
CREATE TABLE IF NOT EXISTS edits (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket TEXT NOT NULL,
  id TEXT NOT NULL,
  additions TEXT NOT NULL,
  removals TEXT NOT NULL,
  before_labels TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued',
  error TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS edit_message ON edits(id, sequence);
CREATE INDEX IF NOT EXISTS edit_ticket ON edits(ticket);
CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
  id UNINDEXED, subject, sender, recipients, copied, filenames, body,
  tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
);
PRAGMA user_version=1;

CREATE TABLE IF NOT EXISTS inventory_pages(generation INTEGER NOT NULL,token TEXT NOT NULL,PRIMARY KEY(generation,token));

CREATE INDEX IF NOT EXISTS complete_messages ON messages(text_complete);

CREATE TABLE IF NOT EXISTS history_pages(token TEXT PRIMARY KEY);

CREATE TABLE IF NOT EXISTS deleted_messages(id TEXT PRIMARY KEY);
