use super::*;
use crate::local_mail::tests::{directory, message, open_directory};
use std::os::unix::fs::{PermissionsExt, symlink};

fn fixture() -> (std::path::PathBuf, File, String, Arc<Store>) {
    let path = directory();
    let root = open_directory(&path);
    let mail = fs::open_dir(&root, "mail".as_ref(), true, true)
        .unwrap()
        .unwrap();
    let id = "a".repeat(64);
    let store_dir = fs::open_dir(&mail, id.as_ref(), true, true)
        .unwrap()
        .unwrap();
    let store = Store::open(store_dir).unwrap();
    store
        .put(&message("one", "Offline retained text"), 1)
        .unwrap();
    (path, root, id, store)
}

fn restore(path: &std::path::Path, id: &str) -> (std::path::PathBuf, Arc<Store>, Value) {
    let restored = directory();
    tar::Archive::new(File::open(path.join(ARCHIVE)).unwrap())
        .unpack(&restored)
        .unwrap();
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(restored.join("manifest.json")).unwrap()).unwrap();
    let parent = restored.join("mail");
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let account = parent.join(id);
    std::fs::set_permissions(&account, std::fs::Permissions::from_mode(0o700)).unwrap();
    let db = std::fs::read(account.join("mail.sqlite")).unwrap();
    assert_eq!(
        manifest["accounts"][0]["databaseSha256"],
        format!("{:x}", Sha256::digest(db))
    );
    let store = Store::open(open_directory(&account)).unwrap();
    (restored, store, manifest)
}

#[test]
fn restore_keeps_wal_edits_search_and_exact_referenced_content() {
    let (path, root, id, store) = fixture();
    store
        .edit(
            "offline",
            &["one".into()],
            &["STARRED".into()],
            &["UNREAD".into()],
        )
        .unwrap();
    store
        .write(|db| super::super::store::set_state(db, "paused", "true"))
        .unwrap();
    store
        .put(&message("two", "Deleted historical blob"), 1)
        .unwrap();
    store.delete("two").unwrap();
    let answer = export(&root, HashMap::from([(id.clone(), store.clone())])).unwrap();
    assert_eq!(answer["complete"], true);
    assert_eq!(answer["accounts"][0]["pendingEdits"], 1);
    let (restored, restored_store, manifest) = restore(&path, &id);
    assert_eq!(manifest["accounts"][0]["messages"], 1);
    assert_eq!(
        restored_store.resource("one").unwrap(),
        store.resource("one").unwrap()
    );
    assert_eq!(
        restored_store.list("retained", 50, "").unwrap()["summaries"],
        store.list("retained", 50, "").unwrap()["summaries"]
    );
    assert_eq!(restored_store.status().unwrap()["pendingEdits"], 1);
    assert!(restored_store.resource("two").unwrap().is_none());
    restored_store.cancel_edit("offline").unwrap();
    assert_eq!(
        restored_store.resource("one").unwrap().unwrap()["labelIds"],
        json!(["INBOX", "UNREAD"])
    );
    let metadata = std::fs::metadata(path.join(ARCHIVE)).unwrap();
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    assert_eq!(
        answer["sha256"],
        format!(
            "{:x}",
            Sha256::digest(std::fs::read(path.join(ARCHIVE)).unwrap())
        )
    );
    drop(restored_store);
    drop(store);
    std::fs::remove_dir_all(restored).unwrap();
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn closed_retained_accounts_are_included_and_live_foreign_owner_is_refused() {
    let (path, root, id, store) = fixture();
    assert_eq!(export(&root, HashMap::new()), Err("private_fs_busy"));
    assert!(!path.join(ARCHIVE).exists());
    drop(store);
    let result = export(&root, HashMap::new()).unwrap();
    assert_eq!(result["accounts"][0]["store"], id);
    let (restored, store, _) = restore(&path, &id);
    assert!(store.resource("one").unwrap().is_some());
    drop(store);
    std::fs::remove_dir_all(restored).unwrap();
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn missing_corrupt_and_redirected_blobs_preserve_previous_complete_archive() {
    for defect in ["missing", "content", "symlink", "hardlink", "permissions"] {
        let (path, root, id, store) = fixture();
        let owners = HashMap::from([(id.clone(), store.clone())]);
        export(&root, owners.clone()).unwrap();
        let before = std::fs::read(path.join(ARCHIVE)).unwrap();
        let hash = store
            .read(
                |db| sql(db.query_row("SELECT blob FROM messages", [], |r| r.get::<_, String>(0))),
            )
            .unwrap();
        let blob = path
            .join("mail")
            .join(&id)
            .join("blobs")
            .join(&hash[..2])
            .join(&hash);
        let sentinel = path.join("sentinel");
        std::fs::write(&sentinel, b"untouched").unwrap();
        std::fs::set_permissions(&sentinel, std::fs::Permissions::from_mode(0o600)).unwrap();
        match defect {
            "missing" => std::fs::remove_file(&blob).unwrap(),
            "content" => std::fs::write(&blob, b"corrupt").unwrap(),
            "symlink" => {
                std::fs::remove_file(&blob).unwrap();
                symlink(&sentinel, &blob).unwrap();
            }
            "hardlink" => {
                std::fs::remove_file(&blob).unwrap();
                std::fs::hard_link(&sentinel, &blob).unwrap();
            }
            _ => std::fs::set_permissions(&blob, std::fs::Permissions::from_mode(0o644)).unwrap(),
        }
        assert!(export(&root, owners).is_err(), "{defect}");
        assert_eq!(
            std::fs::read(path.join(ARCHIVE)).unwrap(),
            before,
            "{defect}"
        );
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"untouched");
        if defect == "permissions" {
            assert_eq!(
                std::fs::metadata(&blob).unwrap().permissions().mode() & 0o777,
                0o644
            );
        }
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }
}

#[test]
fn concurrent_export_and_unsafe_destinations_never_replace_previous_data() {
    for defect in ["busy", "archive-link", "scratch-link", "scratch-unknown"] {
        let (path, root, id, store) = fixture();
        let owners = HashMap::from([(id, store.clone())]);
        export(&root, owners.clone()).unwrap();
        let before = std::fs::read(path.join(ARCHIVE)).unwrap();
        let sentinel = path.join("sentinel");
        std::fs::write(&sentinel, b"untouched").unwrap();
        let mut lease = None;
        match defect {
            "busy" => lease = Some(fs::lock_exclusive(&root, ".mail-backup.lock").unwrap()),
            "archive-link" => {
                std::fs::remove_file(path.join(ARCHIVE)).unwrap();
                symlink(&sentinel, path.join(ARCHIVE)).unwrap();
            }
            "scratch-link" => {
                std::fs::remove_dir_all(path.join("mail/.backup")).unwrap();
                symlink(&path, path.join("mail/.backup")).unwrap();
            }
            _ => std::fs::write(path.join("mail/.backup/unowned"), b"retained").unwrap(),
        }
        assert!(export(&root, owners).is_err(), "{defect}");
        if defect != "archive-link" {
            assert_eq!(std::fs::read(path.join(ARCHIVE)).unwrap(), before);
        }
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"untouched");
        if defect == "scratch-unknown" {
            assert_eq!(
                std::fs::read(path.join("mail/.backup/unowned")).unwrap(),
                b"retained"
            );
        }
        drop(lease);
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }
}

#[test]
fn later_account_failure_does_not_publish_partial_archive() {
    let (path, root, id, store) = fixture();
    let owners = HashMap::from([(id.clone(), store.clone())]);
    export(&root, owners.clone()).unwrap();
    let before = std::fs::read(path.join(ARCHIVE)).unwrap();
    let mail = fs::open_dir(&root, "mail".as_ref(), false, true)
        .unwrap()
        .unwrap();
    let broken = fs::open_dir(&mail, "b".repeat(64).as_ref(), true, true)
        .unwrap()
        .unwrap();
    let mut file = fs::create_private(&broken, "mail.sqlite").unwrap();
    use std::io::Write;
    file.write_all(b"not a database").unwrap();
    drop(file);
    assert!(export(&root, owners).is_err());
    assert_eq!(std::fs::read(path.join(ARCHIVE)).unwrap(), before);
    assert_eq!(
        std::fs::read(path.join("mail").join("b".repeat(64)).join("mail.sqlite")).unwrap(),
        b"not a database"
    );
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn expired_budget_never_copies_database_or_reads_content() {
    let (source_path, _root, _, store) = fixture();
    let target_path = directory();
    let target = vfs::Vfs::new(open_directory(&target_path)).unwrap();
    let mut database = target.connect().unwrap();
    let deadline = Instant::now() - Duration::from_millis(1);
    assert_eq!(
        store.backup_database(&mut database.connection, deadline),
        Err("local_backup_timed_out")
    );
    assert_eq!(
        database
            .connection
            .query_row("SELECT count(*) FROM sqlite_schema", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    struct Unread;
    impl Read for Unread {
        fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
            panic!("expired reader touched input");
        }
    }
    let mut reader = TimedReader {
        inner: Unread,
        deadline,
    };
    assert!(reader.read(&mut [0; 32]).is_err());
    drop(store);
    drop(database);
    drop(target);
    std::fs::remove_dir_all(source_path).unwrap();
    std::fs::remove_dir_all(target_path).unwrap();
}
