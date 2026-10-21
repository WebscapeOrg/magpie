//! SQLite filenames are capabilities within one pinned private directory.
//! The owner lease excludes other processes; SQLite's locks coordinate the
//! bounded connections in this process. WAL shared memory is never persisted.
use crate::platform::private_fs as fs;
use rusqlite::{Connection, OpenFlags, ffi::*};
use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char, c_int, c_void},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

static SERIAL: AtomicU64 = AtomicU64::new(0);
#[derive(Default)]
struct Locks {
    database: HashMap<u64, c_int>,
    shared: HashMap<(u64, c_int), bool>,
    pages: Vec<Box<[u64]>>,
}
struct Root {
    directory: File,
    _lease: fs::ExclusiveLock,
    locks: Mutex<Locks>,
}
pub(super) struct Vfs {
    raw: Box<sqlite3_vfs>,
    name: CString,
    root: Arc<Root>,
}
// The registration and callbacks are stable allocations; mutable shared state
// is behind Locks. Connections hold an Arc<Vfs> until sqlite3_close completes.
unsafe impl Send for Vfs {}
unsafe impl Sync for Vfs {}
impl Drop for Vfs {
    fn drop(&mut self) {
        unsafe {
            sqlite3_vfs_unregister(self.raw.as_mut());
        }
    }
}
impl Vfs {
    pub(super) fn new(directory: File) -> Result<Arc<Self>, &'static str> {
        fs::validate_owned_root(&directory)?;
        let lease = fs::lock_exclusive(&directory, ".owner")?;
        let root = Arc::new(Root {
            directory,
            _lease: lease,
            locks: Mutex::new(Locks::default()),
        });
        let name = CString::new(format!(
            "magpie-mail-{}",
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ))
        .map_err(|_| "local_storage_unavailable")?;
        let mut raw: Box<sqlite3_vfs> = Box::new(unsafe { std::mem::zeroed() });
        raw.iVersion = 1;
        raw.szOsFile = std::mem::size_of::<Handle>() as c_int;
        raw.mxPathname = 64;
        raw.zName = name.as_ptr();
        raw.pAppData = Arc::as_ptr(&root).cast_mut().cast();
        raw.xOpen = Some(open);
        raw.xDelete = Some(delete);
        raw.xAccess = Some(access);
        raw.xFullPathname = Some(full_path);
        raw.xRandomness = Some(randomness);
        raw.xSleep = Some(sleep);
        raw.xCurrentTime = Some(time);
        if unsafe { sqlite3_vfs_register(raw.as_mut(), 0) } != SQLITE_OK {
            return Err("local_storage_unavailable");
        }
        Ok(Arc::new(Self { raw, name, root }))
    }
    pub(super) fn connect(self: &Arc<Self>) -> Result<Database, &'static str> {
        let connection = Connection::open_with_flags_and_vfs(
            "mail.sqlite",
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
            self.name
                .to_str()
                .map_err(|_| "local_storage_unavailable")?,
        )
        .map_err(|_| "local_storage_unavailable")?;
        connection.execute_batch("PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000; PRAGMA mmap_size=0;")
            .map_err(|_| "local_storage_unavailable")?;
        Ok(Database {
            connection,
            _vfs: self.clone(),
        })
    }
    pub(super) fn directory(&self) -> &File {
        &self.root.directory
    }
}
pub(super) struct Database {
    pub connection: Connection,
    _vfs: Arc<Vfs>,
}
#[repr(C)]
struct Handle {
    base: sqlite3_file,
    state: *mut OpenFile,
}
struct OpenFile {
    file: File,
    root: Arc<Root>,
    id: u64,
}
unsafe fn state<'a>(file: *mut sqlite3_file) -> &'a mut OpenFile {
    unsafe { &mut *(*(file.cast::<Handle>())).state }
}
unsafe fn root<'a>(vfs: *mut sqlite3_vfs) -> &'a Root {
    unsafe { &*((*vfs).pAppData.cast::<Root>()) }
}
unsafe fn filename<'a>(name: *const c_char) -> Option<&'a str> {
    if name.is_null() {
        return None;
    }
    let name = unsafe { CStr::from_ptr(name) }.to_str().ok()?;
    matches!(
        name,
        "mail.sqlite" | "mail.sqlite-wal" | "mail.sqlite-journal"
    )
    .then_some(name)
}
unsafe extern "C" fn open(
    vfs: *mut sqlite3_vfs,
    name: *const c_char,
    out: *mut sqlite3_file,
    flags: c_int,
    returned: *mut c_int,
) -> c_int {
    unsafe {
        (*out).pMethods = ptr::null();
    }
    let Some(name) = (unsafe { filename(name) }) else {
        return SQLITE_CANTOPEN;
    };
    let root = unsafe { root(vfs) };
    let file = match fs::regular(&root.directory, name, flags & SQLITE_OPEN_READONLY == 0) {
        Ok(Some(file)) => file,
        Ok(None) if flags & SQLITE_OPEN_CREATE != 0 => {
            match fs::create_private(&root.directory, name) {
                Ok(file) => file,
                Err(_) => return SQLITE_CANTOPEN,
            }
        }
        _ => return SQLITE_CANTOPEN,
    };
    let root = unsafe {
        let pointer = (*vfs).pAppData.cast::<Root>();
        Arc::increment_strong_count(pointer);
        Arc::from_raw(pointer)
    };
    let state = Box::into_raw(Box::new(OpenFile {
        file,
        root,
        id: SERIAL.fetch_add(1, Ordering::Relaxed),
    }));
    unsafe {
        ptr::write(
            out.cast::<Handle>(),
            Handle {
                base: sqlite3_file { pMethods: &METHODS },
                state,
            },
        );
        if !returned.is_null() {
            *returned = flags;
        }
    }
    SQLITE_OK
}
unsafe extern "C" fn close(file: *mut sqlite3_file) -> c_int {
    let state = unsafe { Box::from_raw((*file.cast::<Handle>()).state) };
    if let Ok(mut locks) = state.root.locks.lock() {
        locks.database.remove(&state.id);
        locks.shared.retain(|(id, _), _| *id != state.id);
    }
    unsafe {
        (*file).pMethods = ptr::null();
    }
    SQLITE_OK
}
unsafe extern "C" fn read(
    file: *mut sqlite3_file,
    output: *mut c_void,
    size: c_int,
    offset: i64,
) -> c_int {
    if size < 0 || offset < 0 {
        return SQLITE_IOERR_READ;
    }
    let file = unsafe { &mut state(file).file };
    let bytes = unsafe { std::slice::from_raw_parts_mut(output.cast::<u8>(), size as usize) };
    bytes.fill(0);
    if file.seek(SeekFrom::Start(offset as u64)).is_err() {
        return SQLITE_IOERR_READ;
    }
    let mut done = 0;
    while done < bytes.len() {
        match file.read(&mut bytes[done..]) {
            Ok(0) => return SQLITE_IOERR_SHORT_READ,
            Ok(count) => done += count,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(_) => return SQLITE_IOERR_READ,
        }
    }
    SQLITE_OK
}
unsafe extern "C" fn write(
    file: *mut sqlite3_file,
    input: *const c_void,
    size: c_int,
    offset: i64,
) -> c_int {
    if size < 0 || offset < 0 {
        return SQLITE_IOERR_WRITE;
    }
    let file = unsafe { &mut state(file).file };
    let bytes = unsafe { std::slice::from_raw_parts(input.cast::<u8>(), size as usize) };
    match file
        .seek(SeekFrom::Start(offset as u64))
        .and_then(|_| file.write_all(bytes))
    {
        Ok(_) => SQLITE_OK,
        Err(e) if e.kind() == std::io::ErrorKind::StorageFull => SQLITE_FULL,
        Err(_) => SQLITE_IOERR_WRITE,
    }
}
unsafe extern "C" fn truncate(file: *mut sqlite3_file, size: i64) -> c_int {
    if size >= 0 && unsafe { state(file) }.file.set_len(size as u64).is_ok() {
        SQLITE_OK
    } else {
        SQLITE_IOERR_TRUNCATE
    }
}
unsafe extern "C" fn sync(file: *mut sqlite3_file, _: c_int) -> c_int {
    let file = unsafe { state(file) };
    if file.file.sync_all().is_ok() && fs::sync_dir(&file.root.directory).is_ok() {
        SQLITE_OK
    } else {
        SQLITE_IOERR_FSYNC
    }
}
unsafe extern "C" fn size(file: *mut sqlite3_file, out: *mut i64) -> c_int {
    match unsafe { state(file) }.file.metadata() {
        Ok(meta) => {
            unsafe {
                *out = meta.len() as i64;
            }
            SQLITE_OK
        }
        Err(_) => SQLITE_IOERR_FSTAT,
    }
}
unsafe extern "C" fn lock(file: *mut sqlite3_file, level: c_int) -> c_int {
    let file = unsafe { state(file) };
    let Ok(mut locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_LOCK;
    };
    if locks.database.iter().any(|(id, held)| {
        *id != file.id
            && (level >= SQLITE_LOCK_EXCLUSIVE && *held >= SQLITE_LOCK_SHARED
                || level >= SQLITE_LOCK_RESERVED && *held >= SQLITE_LOCK_RESERVED
                || level == SQLITE_LOCK_SHARED && *held >= SQLITE_LOCK_PENDING)
    }) {
        return SQLITE_BUSY;
    }
    locks.database.insert(file.id, level);
    SQLITE_OK
}
unsafe extern "C" fn unlock(file: *mut sqlite3_file, level: c_int) -> c_int {
    let file = unsafe { state(file) };
    let Ok(mut locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_UNLOCK;
    };
    locks.database.insert(file.id, level);
    SQLITE_OK
}
unsafe extern "C" fn reserved(file: *mut sqlite3_file, out: *mut c_int) -> c_int {
    let file = unsafe { state(file) };
    let Ok(locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_CHECKRESERVEDLOCK;
    };
    unsafe {
        *out = i32::from(locks.database.values().any(|v| *v >= SQLITE_LOCK_RESERVED));
    }
    SQLITE_OK
}
unsafe extern "C" fn control(_: *mut sqlite3_file, _: c_int, _: *mut c_void) -> c_int {
    SQLITE_NOTFOUND
}
unsafe extern "C" fn sector(_: *mut sqlite3_file) -> c_int {
    4096
}
unsafe extern "C" fn characteristics(_: *mut sqlite3_file) -> c_int {
    0
}
unsafe extern "C" fn shm_map(
    file: *mut sqlite3_file,
    page: c_int,
    size: c_int,
    extend: c_int,
    out: *mut *mut c_void,
) -> c_int {
    unsafe {
        *out = ptr::null_mut();
    }
    if !(0..65536).contains(&page) || size != 32768 {
        return SQLITE_IOERR_SHMMAP;
    }
    let file = unsafe { state(file) };
    let Ok(mut locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_SHMMAP;
    };
    if extend != 0 {
        while locks.pages.len() <= page as usize {
            locks
                .pages
                .push(vec![0_u64; size as usize / 8].into_boxed_slice());
        }
    }
    if let Some(page) = locks.pages.get_mut(page as usize) {
        unsafe {
            *out = page.as_mut_ptr().cast();
        }
    }
    SQLITE_OK
}
unsafe extern "C" fn shm_lock(
    file: *mut sqlite3_file,
    offset: c_int,
    count: c_int,
    flags: c_int,
) -> c_int {
    if offset < 0 || count <= 0 || offset + count > SQLITE_SHM_NLOCK {
        return SQLITE_IOERR_SHMLOCK;
    }
    let file = unsafe { state(file) };
    let Ok(mut locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_SHMLOCK;
    };
    let exclusive = flags & SQLITE_SHM_EXCLUSIVE != 0;
    if flags & SQLITE_SHM_UNLOCK != 0 {
        for byte in offset..offset + count {
            locks.shared.remove(&(file.id, byte));
        }
        return SQLITE_OK;
    }
    if locks.shared.iter().any(|((id, byte), held)| {
        *id != file.id && (offset..offset + count).contains(byte) && (exclusive || *held)
    }) {
        return SQLITE_BUSY;
    }
    for byte in offset..offset + count {
        locks.shared.insert((file.id, byte), exclusive);
    }
    SQLITE_OK
}
unsafe extern "C" fn barrier(_: *mut sqlite3_file) {
    std::sync::atomic::fence(Ordering::SeqCst);
}
unsafe extern "C" fn shm_unmap(file: *mut sqlite3_file, _: c_int) -> c_int {
    let file = unsafe { state(file) };
    let Ok(mut locks) = file.root.locks.lock() else {
        return SQLITE_IOERR_SHMLOCK;
    };
    locks.shared.retain(|(id, _), _| *id != file.id);
    SQLITE_OK
}
static METHODS: sqlite3_io_methods = sqlite3_io_methods {
    iVersion: 2,
    xClose: Some(close),
    xRead: Some(read),
    xWrite: Some(write),
    xTruncate: Some(truncate),
    xSync: Some(sync),
    xFileSize: Some(size),
    xLock: Some(lock),
    xUnlock: Some(unlock),
    xCheckReservedLock: Some(reserved),
    xFileControl: Some(control),
    xSectorSize: Some(sector),
    xDeviceCharacteristics: Some(characteristics),
    xShmMap: Some(shm_map),
    xShmLock: Some(shm_lock),
    xShmBarrier: Some(barrier),
    xShmUnmap: Some(shm_unmap),
    xFetch: None,
    xUnfetch: None,
};
unsafe extern "C" fn delete(vfs: *mut sqlite3_vfs, name: *const c_char, durable: c_int) -> c_int {
    let Some(name) = (unsafe { filename(name) }) else {
        return SQLITE_IOERR_DELETE;
    };
    let root = unsafe { root(vfs) };
    if fs::remove_owned(&root.directory, name).is_err() {
        return SQLITE_IOERR_DELETE;
    }
    if durable != 0 && fs::sync_dir(&root.directory).is_err() {
        return SQLITE_IOERR_DIR_FSYNC;
    }
    SQLITE_OK
}
unsafe extern "C" fn access(
    vfs: *mut sqlite3_vfs,
    name: *const c_char,
    _: c_int,
    out: *mut c_int,
) -> c_int {
    unsafe {
        *out = 0;
    }
    let Some(name) = (unsafe { filename(name) }) else {
        return SQLITE_OK;
    };
    match fs::regular(&unsafe { root(vfs) }.directory, name, false) {
        Ok(file) => {
            unsafe {
                *out = i32::from(file.is_some());
            }
            SQLITE_OK
        }
        Err(_) => SQLITE_IOERR_ACCESS,
    }
}
unsafe extern "C" fn full_path(
    _: *mut sqlite3_vfs,
    name: *const c_char,
    capacity: c_int,
    out: *mut c_char,
) -> c_int {
    let Some(name) = (unsafe { filename(name) }) else {
        return SQLITE_CANTOPEN;
    };
    if capacity as usize <= name.len() {
        return SQLITE_CANTOPEN;
    }
    unsafe {
        ptr::copy_nonoverlapping(name.as_ptr(), out.cast(), name.len());
        *out.add(name.len()) = 0;
    }
    SQLITE_OK
}
unsafe extern "C" fn randomness(_: *mut sqlite3_vfs, count: c_int, out: *mut c_char) -> c_int {
    let default = unsafe { sqlite3_vfs_find(ptr::null()) };
    if default.is_null() {
        return 0;
    }
    unsafe {
        (*default)
            .xRandomness
            .map_or(0, |call| call(default, count, out))
    }
}
unsafe extern "C" fn sleep(_: *mut sqlite3_vfs, micros: c_int) -> c_int {
    std::thread::sleep(std::time::Duration::from_micros(micros.max(0) as u64));
    micros
}
unsafe extern "C" fn time(_: *mut sqlite3_vfs, out: *mut f64) -> c_int {
    unsafe {
        *out = chrono::Utc::now().timestamp_millis() as f64 / 86_400_000.0 + 2_440_587.5;
    }
    SQLITE_OK
}
