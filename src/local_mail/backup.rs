use super::{LocalMail, Store, store::sql, vfs};
use crate::platform::{dirs::AppDirs, private_fs as fs};
use rusqlite::{
    Connection,
    backup::{Backup, StepResult},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    os::fd::AsRawFd,
    sync::Arc,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, &'static str>;
const ARCHIVE: &str = "mail-backup.tar";
const SCRATCH_FILES: &[&str] = &[
    "mail.sqlite",
    "mail.sqlite-wal",
    "mail.sqlite-journal",
    ".owner",
    "archive.tar",
];

impl LocalMail {
    pub(crate) async fn export_backup(&self) -> Result<Value> {
        let stores = self
            .stores
            .lock()
            .map_err(|_| "local_storage_unavailable")?
            .iter()
            .map(|(account, store)| {
                (
                    format!("{:x}", Sha256::digest(account.as_bytes())),
                    store.clone(),
                )
            })
            .collect();
        tokio::task::spawn_blocking(move || {
            let dirs = AppDirs::discover()?;
            let root = fs::directories_readonly(&dirs.state, &["omamail"])?
                .ok_or("local_backup_no_store")?;
            export(&root, stores)
        })
        .await
        .map_err(|_| "local_backup_failed")?
    }
}

pub(super) fn check_deadline(deadline: Instant) -> Result<()> {
    if Instant::now() >= deadline {
        return Err("local_backup_timed_out");
    }
    Ok(())
}

struct TimedReader<R> {
    inner: R,
    deadline: Instant,
}
impl<R: Read> Read for TimedReader<R> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        check_deadline(self.deadline).map_err(std::io::Error::other)?;
        self.inner.read(bytes)
    }
}

pub(super) fn copy_database(
    source: &Connection,
    target: &mut Connection,
    deadline: Instant,
) -> Result<()> {
    let backup = sql(Backup::new(source, target))?;
    loop {
        if Instant::now() >= deadline {
            return Err("local_backup_timed_out");
        }
        match sql(backup.step(1024))? {
            StepResult::Done => return Ok(()),
            StepResult::More => (),
            _ => return Err("local_backup_busy"),
        }
    }
}

fn store_ids(mail: &File) -> Result<Vec<String>> {
    let mut ids = fs::names(mail)?;
    ids.retain(|id| id != ".backup");
    if ids.iter().any(|id| !digest_name(id)) {
        return Err("local_backup_unknown_store");
    }
    ids.sort();
    Ok(ids)
}

fn digest_name(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn clear_scratch(scratch: &File) -> Result<()> {
    let names = fs::names(scratch)?;
    if names
        .iter()
        .any(|name| !SCRATCH_FILES.contains(&name.as_str()))
    {
        return Err("local_backup_unsafe_staging");
    }
    for name in &names {
        fs::regular_readonly(scratch, name)?;
    }
    for name in names {
        fs::remove_owned(scratch, &name)?;
    }
    fs::sync_dir(scratch)
}

fn export(root: &File, stores: HashMap<String, Arc<Store>>) -> Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(9 * 60);
    fs::validate_owned_root(root)?;
    let _lease = fs::lock_exclusive(root, ".mail-backup.lock")?;
    fs::regular_readonly(root, ARCHIVE)?;
    let mail =
        fs::open_dir_readonly(root, "mail".as_ref(), true)?.ok_or("local_backup_no_store")?;
    let ids = store_ids(&mail)?;
    if ids.is_empty() {
        return Err("local_backup_no_store");
    }
    let scratch =
        fs::open_dir(&mail, ".backup".as_ref(), true, true)?.ok_or("local_backup_failed")?;
    clear_scratch(&scratch)?;
    let result = write_archive(&scratch, &mail, &ids, &stores, deadline);
    let receipt = match result {
        Ok(receipt) => receipt,
        Err(error) => {
            let _ = clear_scratch(&scratch);
            check_deadline(deadline)?;
            return Err(error);
        }
    };
    if store_ids(&mail)? != ids {
        clear_scratch(&scratch)?;
        return Err("local_backup_stores_changed");
    }
    check_deadline(deadline)?;
    let previous = fs::regular_readonly(root, ARCHIVE)?.is_some();
    let flags = if previous {
        libc::RENAME_EXCHANGE
    } else {
        libc::RENAME_NOREPLACE
    };
    if unsafe {
        libc::renameat2(
            scratch.as_raw_fd(),
            c"archive.tar".as_ptr(),
            root.as_raw_fd(),
            c"mail-backup.tar".as_ptr(),
            flags,
        )
    } != 0
    {
        let _ = clear_scratch(&scratch);
        return Err("local_backup_publish_failed");
    }
    if fs::sync_dir(root)
        .and_then(|_| fs::sync_dir(&scratch))
        .is_err()
    {
        if previous
            && unsafe {
                libc::renameat2(
                    scratch.as_raw_fd(),
                    c"archive.tar".as_ptr(),
                    root.as_raw_fd(),
                    c"mail-backup.tar".as_ptr(),
                    libc::RENAME_EXCHANGE,
                )
            } == 0
        {
            if fs::sync_dir(root)
                .and_then(|_| fs::sync_dir(&scratch))
                .is_ok()
            {
                return Err("local_backup_publish_failed");
            }
            return Err("local_backup_completion_unknown");
        }
        return Err("local_backup_completion_unknown");
    }
    // The displaced complete archive stays in private staging until the next export.
    Ok(receipt)
}

fn write_archive(
    scratch: &File,
    mail: &File,
    ids: &[String],
    stores: &HashMap<String, Arc<Store>>,
    deadline: Instant,
) -> Result<Value> {
    let mut output = fs::create_private(scratch, "archive.tar")?;
    let mut archive = tar::Builder::new(&mut output);
    let mut accounts = Vec::new();
    for id in ids {
        check_deadline(deadline)?;
        let source =
            fs::open_dir_readonly(mail, id.as_ref(), true)?.ok_or("local_backup_stores_changed")?;
        fs::regular_readonly(&source, "mail.sqlite")?.ok_or("local_backup_incomplete")?;
        let target_vfs = vfs::Vfs::new(scratch.try_clone().map_err(|_| "local_backup_failed")?)?;
        let mut target = target_vfs.connect()?;
        match stores.get(id) {
            Some(store) => {
                use std::os::unix::fs::MetadataExt;
                let pinned = store
                    .directory()
                    .metadata()
                    .map_err(|_| "local_backup_failed")?;
                let current = source.metadata().map_err(|_| "local_backup_failed")?;
                if (pinned.dev(), pinned.ino()) != (current.dev(), current.ino()) {
                    return Err("local_backup_stores_changed");
                }
                store.backup_database(&mut target.connection, deadline)?;
            }
            None => {
                let owner = vfs::Vfs::new(source.try_clone().map_err(|_| "local_backup_failed")?)?;
                let database = owner.connect()?;
                copy_database(&database.connection, &mut target.connection, deadline)?;
            }
        }
        sql(target
            .connection
            .progress_handler(1000, Some(move || Instant::now() >= deadline)))?;
        let details = validate_database(&target.connection)?;
        let blobs = referenced_blobs(&target.connection)?;
        sql(target
            .connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"))?;
        drop(target);
        drop(target_vfs);
        let database =
            fs::regular_readonly(scratch, "mail.sqlite")?.ok_or("local_backup_incomplete")?;
        let digest = append_file(
            &mut archive,
            &format!("mail/{id}/mail.sqlite"),
            database,
            deadline,
        )?;
        for (message, hash) in &blobs {
            check_deadline(deadline)?;
            if !digest_name(hash) {
                return Err("local_storage_corrupt");
            }
            let directory = fs::open_dir_readonly(&source, "blobs".as_ref(), true)?
                .ok_or("local_content_missing")?;
            let directory = fs::open_dir_readonly(&directory, hash[..2].as_ref(), true)?
                .ok_or("local_content_missing")?;
            let file = fs::regular_readonly(&directory, hash)?.ok_or("local_content_missing")?;
            let mut bytes = Vec::new();
            TimedReader {
                inner: file,
                deadline,
            }
            .take(128 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "local_content_missing")?;
            if bytes.len() > 128 * 1024 * 1024 || format!("{:x}", Sha256::digest(&bytes)) != *hash {
                return Err("local_content_invalid");
            }
            let resource: Value =
                serde_json::from_slice(&bytes).map_err(|_| "local_content_invalid")?;
            if resource["id"] != *message {
                return Err("local_content_invalid");
            }
            append_bytes(
                &mut archive,
                &format!("mail/{id}/blobs/{}/{hash}", &hash[..2]),
                &bytes,
            )?;
        }
        accounts.push(json!({"store":id,"databaseSha256":digest,"messages":blobs.len(),"pendingEdits":details}));
        for name in SCRATCH_FILES.iter().filter(|name| **name != "archive.tar") {
            fs::remove_owned(scratch, name)?;
        }
    }
    let manifest = json!({"format":1,"createdAt":chrono::Utc::now().to_rfc3339(),"backendVersion":env!("CARGO_PKG_VERSION"),"accounts":accounts});
    append_bytes(
        &mut archive,
        "manifest.json",
        &serde_json::to_vec_pretty(&manifest).map_err(|_| "local_backup_failed")?,
    )?;
    archive.finish().map_err(|_| "local_backup_failed")?;
    drop(archive);
    output.sync_all().map_err(|_| "local_backup_failed")?;
    let bytes = output.metadata().map_err(|_| "local_backup_failed")?.len();
    output
        .seek(SeekFrom::Start(0))
        .map_err(|_| "local_backup_failed")?;
    let mut digest = Sha256::new();
    std::io::copy(
        &mut TimedReader {
            inner: &mut output,
            deadline,
        },
        &mut digest,
    )
    .map_err(|_| "local_backup_failed")?;
    Ok(
        json!({"archive":ARCHIVE,"bytes":bytes,"sha256":format!("{:x}", digest.finalize()),"accounts":accounts,"complete":true}),
    )
}

fn validate_database(db: &Connection) -> Result<i64> {
    let integrity: String = sql(db.query_row("PRAGMA integrity_check", [], |row| row.get(0)))?;
    let mut foreign = sql(db.prepare("PRAGMA foreign_key_check"))?;
    if integrity != "ok"
        || sql(foreign.query([]))?
            .next()
            .map_err(|_| "local_storage_corrupt")?
            .is_some()
    {
        return Err("local_storage_corrupt");
    }
    let version: i64 = sql(db.pragma_query_value(None, "user_version", |row| row.get(0)))?;
    if version != 1 {
        return Err("local_schema_newer");
    }
    sql(db.query_row(
        "SELECT count(*) FROM edits WHERE state IN ('queued','sending')",
        [],
        |row| row.get(0),
    ))
}

fn referenced_blobs(db: &Connection) -> Result<Vec<(String, String)>> {
    let mut query = sql(db.prepare("SELECT id,blob FROM messages ORDER BY id"))?;
    sql(sql(query.query_map([], |row| Ok((row.get(0)?, row.get(1)?))))?.collect())
}

fn append_bytes<W: std::io::Write>(
    archive: &mut tar::Builder<W>,
    name: &str,
    bytes: &[u8],
) -> Result<()> {
    let mut header = header(bytes.len() as u64);
    archive
        .append_data(&mut header, name, bytes)
        .map_err(|_| "local_backup_failed")
}

fn header(size: u64) -> tar::Header {
    let mut header = tar::Header::new_ustar();
    header.set_size(size);
    header.set_mode(0o600);
    header.set_uid(0);
    header.set_gid(0);
    header.set_mtime(0);
    header.set_entry_type(tar::EntryType::Regular);
    header.set_cksum();
    header
}

fn append_file<W: std::io::Write>(
    archive: &mut tar::Builder<W>,
    name: &str,
    file: File,
    deadline: Instant,
) -> Result<String> {
    struct Hashed {
        file: File,
        digest: Sha256,
    }
    impl Read for Hashed {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            let count = self.file.read(bytes)?;
            self.digest.update(&bytes[..count]);
            Ok(count)
        }
    }
    let mut header = header(file.metadata().map_err(|_| "local_backup_failed")?.len());
    let mut reader = Hashed {
        file,
        digest: Sha256::new(),
    };
    archive
        .append_data(
            &mut header,
            name,
            TimedReader {
                inner: &mut reader,
                deadline,
            },
        )
        .map_err(|_| "local_backup_failed")?;
    Ok(format!("{:x}", reader.digest.finalize()))
}

#[cfg(test)]
mod tests;
