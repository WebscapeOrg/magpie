#!/usr/bin/env python3
"""Exercise a frontend's API contract against an explicitly selected binary.

Uses the production QML JavaScript request, frame and response codecs in Node.
Only synthetic data, dry runs and local storage operations are used; no real account, credential,
mail server, or external agent is configured. This is a compatibility gate, not
an exhaustive provider/network integration suite.
"""
import argparse
from contextlib import contextmanager, ExitStack, nullcontext
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import signal
import shutil
import sqlite3
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_CREATE_NEW_PROCESS_GROUP = getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x00000200)


def selected_contract(released=False):
    spec = importlib.util.spec_from_file_location('package_backend_contract', ROOT / 'scripts/package-backend.py')
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    contract = package.read_api(ROOT / 'backend-api.json')
    return package.released_view(contract) if released else contract


@contextmanager
def redirected_folders(changes, get_path, set_path):
    originals = []
    try:
        for key, path in changes:
            original = get_path(key)
            set_path(key, str(path))
            originals.append((key, original))
        yield
    finally:
        errors = []
        for key, original in reversed(originals):
            try:
                set_path(key, original)
            except OSError as error:
                errors.append(error)
        if errors:
            raise RuntimeError('Could not restore isolated runner Known Folders') from errors[0]


def windows_known_folders():
    import ctypes
    import uuid
    shell = ctypes.WinDLL('shell32')
    memory = ctypes.WinDLL('ole32')
    shell.SHGetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
                                         ctypes.POINTER(ctypes.c_void_p)]
    shell.SHGetKnownFolderPath.restype = ctypes.c_long
    shell.SHSetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_wchar_p]
    shell.SHSetKnownFolderPath.restype = ctypes.c_long
    memory.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    memory.CoTaskMemFree.restype = None

    def guid(key):
        return ctypes.create_string_buffer(uuid.UUID(key).bytes_le)

    def get_path(key):
        pointer = ctypes.c_void_p()
        result = shell.SHGetKnownFolderPath(guid(key), 0x4000, None, ctypes.byref(pointer))
        if result < 0:
            raise OSError(f'SHGetKnownFolderPath failed: {result:#x}')
        try:
            return ctypes.wstring_at(pointer)
        finally:
            memory.CoTaskMemFree(pointer)

    def set_path(key, path):
        result = shell.SHSetKnownFolderPath(guid(key), 0x2000, None, path)
        if result < 0:
            raise OSError(f'SHSetKnownFolderPath failed: {result:#x}')

    return get_path, set_path


@contextmanager
def exclusive_fixture_directory(path):
    path.mkdir(mode=0o700)
    identity = path.stat(follow_symlinks=False)
    try:
        yield path
    finally:
        current = path.stat(follow_symlinks=False)
        if path.is_symlink() or not path.is_dir() or not os.path.samestat(identity, current):
            raise RuntimeError('Refusing to remove a replaced fixture directory')
        shutil.rmtree(path)


def windows_fixture_folders(home, config, get_path, set_path):
    return redirected_folders([
        ('3eb685db-65f9-4cf6-a03a-e3ef65729f3d', config),
        ('374de290-123f-4565-9164-39c4925e467b', home / 'Downloads'),
    ], get_path, set_path)


def process_group_options(platform=None):
    """Start the Node harness in a group that can be torn down with its backend."""
    if (platform or os.name) == 'nt':
        return {'creationflags': WINDOWS_CREATE_NEW_PROCESS_GROUP}
    return {'start_new_session': True}


def terminate_process_group(process, platform=None):
    """Terminate a timed-out harness and every backend process it created."""
    if process.poll() is not None:
        return
    if (platform or os.name) == 'nt':
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if process.poll() is None:
            process.kill()
    else:
        os.killpg(process.pid, signal.SIGKILL)


def make_windows_fixture_private(roots):
    entries = [{'path': str(path), 'directory': path.is_dir()}
               for root in roots for path in [root] + sorted(root.rglob('*'))]
    script = r"""
$ErrorActionPreference = 'Stop'
$entries = [Console]::In.ReadToEnd() | ConvertFrom-Json
$owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($entry in $entries) {
    if ($entry.directory) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    } else {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $owner, [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inherit, [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $entry.path -AclObject $acl
}
"""
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                            input=json.dumps(entries), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Could not set private fixture permissions: ' + result.stderr[:8192])


def run_fixture_process(command, env, home):
    process = subprocess.Popen(command, env=env, cwd=home, **process_group_options())
    try:
        return process.wait(timeout=60)
    finally:
        try:
            terminate_process_group(process)
        except (OSError, ProcessLookupError):
            pass
        process.wait(timeout=10)


HARNESS = r"""
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const {spawn} = require('child_process');
const {load} = require(process.env.CONTRACT_ROOT + '/ui/tests/load.js');
const Wire = load('backend/Wire.js');
const Chunks = load('backend/Chunks.js');
const whole = JSON.parse(fs.readFileSync(process.env.CONTRACT_ROOT + '/backend-api.json'));
// The pinned, published binary is asked only for the released API; a binary
// built from this checkout for all of it.
const released = process.env.CONTRACT_RELEASED === '1';
const standalone = process.env.CONTRACT_STANDALONE === '1';
const unreleased = whole.unreleased || {methods: [], cases: []};
const selected = released ? (whole.releasedContract || {
  apiVersion: whole.releasedApiVersion, protocolVersion: whole.protocolVersion,
  methods: whole.methods.filter(m => !unreleased.methods.includes(m)),
  contractCases: whole.contractCases.filter(c => !unreleased.cases.includes(c.name))
}) : whole;
// Standalone Linux/macOS share the native assistant. Windows remains deferred
// and must reject the unavailable methods without touching storage.
const agentUnavailable = standalone && process.platform === 'win32';
const methodUnavailable = method => (agentUnavailable && method.startsWith('agent.')) ||
  (process.platform !== 'linux' && method.startsWith('phone.'));
const unavailable = selected.methods.filter(methodUnavailable);
const contract = {
  ...selected,
  methods: selected.methods.filter(m => !methodUnavailable(m)),
  contractCases: selected.contractCases.filter(c => !methodUnavailable(c.method))
};
const child = spawn(process.env.CONTRACT_BINARY, ['serve'], {stdio:['pipe','pipe','pipe']});
let buffer = '', state = null, serial = 0, finished = false;
const pending = new Map();
const tested = new Set();
function fail(error) { console.error(error.stack || error); child.kill('SIGKILL'); process.exit(1); }
child.on('error', fail);
child.on('exit', code => { if (!finished) fail(new Error('Backend exited before contract completed: ' + code)); });
// Stderr is consumed, bounded and never printed: errors must not dump mail data.
let stderrBytes = 0;
child.stderr.on('data', chunk => { stderrBytes += chunk.length; if (stderrBytes > 1048576) fail(new Error('Excessive backend stderr')); });
child.stdout.setEncoding('utf8');
child.stdout.on('data', chunk => {
  try {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      const decoded = Chunks.decode(state, line); state = decoded.state;
      assert.ok(!decoded.error, 'production chunk decoder accepts frame');
      if (decoded.line === null) continue;
      if (Wire.notificationValue(decoded.value)) continue;
      const reply = Wire.responseValue(decoded.value);
      assert.ok(reply && pending.has(reply.id), 'production response codec and request correlation');
      const entry = pending.get(reply.id); pending.delete(reply.id); clearTimeout(entry.timer);
      entry.resolve(reply);
    }
    assert.ok(buffer.length < 1048576, 'bounded unfinished frame');
  } catch (error) { fail(error); }
});
async function call(method, params = {}, errorCode = null, advertised = true) {
  assert.equal(contract.methods.includes(method), advertised, 'method inventory: ' + method);
  if (advertised) tested.add(method);
  const id = String(++serial);
  const reply = await new Promise(resolve => {
    pending.set(id, {resolve, timer:setTimeout(() => fail(new Error('RPC deadline: ' + method)), 10000)});
    child.stdin.write(Wire.request(id, method, params));
  });
  if (errorCode !== null) { assert.equal(reply.error && reply.error.code, errorCode, method + ': ' + JSON.stringify(reply.error)); return reply.error; }
  assert.ok(!reply.error, method + ': ' + JSON.stringify(reply.error));
  return reply.result;
}
function safeDocument(value) {
  assert.ok(value && typeof value === 'object');
  assert.ok(!JSON.stringify(value).includes('forbiddenScript'));
}
function storageSnapshot() {
  const snapshot = {};
  function visit(path) {
    const stat = fs.lstatSync(path, {bigint:true});
    snapshot[path] = [String(stat.mode), String(stat.ino), String(stat.mtimeNs),
      stat.isFile() ? fs.readFileSync(path).toString('base64') : null];
    if (stat.isDirectory()) for (const name of fs.readdirSync(path).sort()) visit(path + '/' + name);
  }
  for (const directory of JSON.parse(process.env.CONTRACT_STORAGE_ROOTS)) visit(directory);
  return snapshot;
}
(async () => {
  const info = await call('system.info');
  assert.equal(info.name, 'omamail');
  assert.equal(info.protocol, contract.protocolVersion);
  if (process.env.CONTRACT_VERSION) assert.equal(info.version, process.env.CONTRACT_VERSION);
  const api = info.apiVersion === undefined && info.version === '0.9.0' ? 1 : info.apiVersion;
  assert.equal(api, contract.apiVersion, 'API version (only released 0.9.0 has a legacy fallback)');
  assert.ok(Array.isArray(info.methods));
  for (const method of contract.methods) assert.ok(info.methods.includes(method), 'advertised API method: ' + method);
  if (standalone) assert.equal(info.capabilities && info.capabilities.agent, !agentUnavailable, 'standalone agent capability follows platform support');
  for (const method of unavailable) {
    assert.ok(!info.methods.includes(method), 'standalone does not advertise: ' + method);
    const before = storageSnapshot();
    const error = await call(method, {}, -32601, false);
    assert.equal(error.message, 'Method not found');
    assert.deepEqual(storageSnapshot(), before, method + ': disabled method has no effects');
  }
  if (!released) {
    assert.equal(info.contractHash, require('crypto').createHash('sha256').update(fs.readFileSync(process.env.CONTRACT_ROOT + '/backend-api.json')).digest('hex'), 'compiled API contract matches the UI contract');
    assert.deepEqual([...info.methods].sort(), [...contract.methods].sort(), 'current inventory has no removed methods');
    const removed = (whole.releasedContract ? whole.releasedContract.methods : [])
      .filter(method => !whole.methods.includes(method));
    for (const method of [...removed, 'jmap.actionAvailability', 'jmap.actionRows']) {
      assert.ok(!info.methods.includes(method), 'removed or internal method is not advertised');
      const before = storageSnapshot();
      const error = await call(method, {}, -32601, false);
      assert.equal(error.message, 'Method not found');
      assert.deepEqual(storageSnapshot(), before, 'unknown method has no account or provider effects');
    }
  }
  // Versioned request/response fixtures live with the published API inventory.
  function at(value, path) { return path ? path.split('.').reduce((v, key) => v === undefined || v === null ? undefined : v[key], value) : value; }
  assert.ok(Array.isArray(contract.contractCases) && contract.contractCases.length);
  for (const fixture of contract.contractCases) {
    if (fixture.name === 'AI transcript pages preserve native session identity') {
      // Match agent::storage::Store, including macOS where XDG_STATE_HOME
      // is unset. Never seed a relative "undefined/" tree in the fixture home.
      const base = process.env.XDG_STATE_HOME || path.join(process.env.HOME, '.local/state');
      const root = path.join(base, 'omamail/assistant');
      assert.ok(path.isAbsolute(root), 'agent fixture uses an absolute private state path');
      fs.mkdirSync(root, {recursive:true, mode:0o700});
      const id = n => (n + 1).toString(16).padStart(32, '0');
      for (let index = 0; index < 10; index++) {
        const directory = root + '/' + id(index);
        fs.mkdirSync(directory, {mode:0o700});
        const job = {id:id(index),conversationId:id(0),accountId:'contract-account',messageId:'mail',
          messageIds:['mail'],draftKey:'',draftFingerprint:'',subject:'Synthetic',kind:'message',
          state:'done',created:1,createdOrder:index+1,updated:1,resultReady:true,displayVersion:2,
          sessionId:'11111111-2222-3333-4444-555555555555',provider:'claude'};
        const display = {transcript:[{role:'user',text:'question-'+index},{role:'assistant',text:'answer-'+index}],
          output:'answer-'+index,complete:true,sessionId:job.sessionId};
        const context = {accountId:job.accountId,prompt:'question-'+index,...(index ? {parent:id(index-1)} : {})};
        for (const [name, value] of Object.entries({'job.json':job,'display.json':display,'context.json':context,
          ...(index < 9 ? {'next.json':id(index+1)} : {})}))
          fs.writeFileSync(directory+'/'+name,JSON.stringify(value),{mode:0o600});
      }
    }
    const attachmentRecovery = fixture.name.startsWith('Attachment recovery ');
    if (attachmentRecovery) {
      // The stored path is a description, never authority to open or remove a file.
      const fixturePath = path.join(process.env.HOME, 'attachment-recovery-sentinel');
      if (!fs.existsSync(fixturePath)) fs.writeFileSync(fixturePath, 'synthetic-attachment-preserve', {mode:0o600});
      const drafts = fixture.params.record
        ? [fixture.params.record.draft, ...(fixture.params.record.parked || [])] : [];
      for (const draft of drafts) {
        for (const job of [...(draft.attachJobs || []), ...(draft.pendingAttachment ? [draft.pendingAttachment] : [])]) {
          if (job.path === '/synthetic/contract-attachment.bin') job.path = fixturePath;
        }
      }
      const jobCount = fixture.name === 'Attachment recovery preserves the bounded maximum job queue' ? 1000
        : fixture.name === 'Attachment recovery rejects an oversized pending queue' ? 1001 : 0;
      if (jobCount) {
        const job = fixture.params.record.draft.attachJobs[0];
        fixture.params.record.draft.attachJobs = Array.from({length:jobCount}, () => ({...job}));
      }
      if (fixture.method === 'compose.recoverySave' && fixture.errorCode === undefined)
        fixture.params.expectedRevision = (await call('compose.recoveryRead', {})).revision;
    }
    const registryPath = process.env.CONTRACT_REGISTRY_PATH;
    const emptyRegistry = fixture.name === 'mail list requires an account';
    const registryBefore = emptyRegistry ? fs.readFileSync(registryPath) : null;
    if (emptyRegistry) fs.writeFileSync(registryPath, JSON.stringify({version:1,accounts:[]}));
    // All owned fixture roots include seeded cache/config/state sentinels,
    // credential helper effects and any newly created outbox/draft files.
    const noWrites = fixture.method.startsWith('mail.') || fixture.name === 'recovery rejects invalid edit history'
      || fixture.name === 'AI recovery refuses nontext quote metadata'
      || (attachmentRecovery && fixture.errorCode !== undefined);
    const before = noWrites ? storageSnapshot() : null;
    if (fixture.name === 'AI recovery preserves app-owned quote metadata')
      fixture.params.expectedRevision = (await call('compose.recoveryRead', {})).revision;
    const value = await call(fixture.method, fixture.params, fixture.errorCode === undefined ? null : fixture.errorCode);
    if (noWrites) assert.deepEqual(storageSnapshot(), before, fixture.name + ': no storage or credential effects');
    if (emptyRegistry) fs.writeFileSync(registryPath, registryBefore);
    for (const [path, expected] of Object.entries(fixture.equals || {})) {
      const actual = at(value, path);
      // Production codecs run in a VM; compare JSON values across its realm,
      // not the Array/Object prototypes of the Node fixture loader.
      assert.deepEqual(actual === undefined ? undefined : JSON.parse(JSON.stringify(actual)), expected, fixture.name + ': ' + path);
    }
    for (const [path, expected] of Object.entries(fixture.types || {})) {
      const actual = at(value, path);
      const type = Array.isArray(actual) ? 'array' : actual === null ? 'null' : typeof actual;
      assert.equal(type, expected, fixture.name + ': ' + path);
    }
    if (attachmentRecovery) {
      const fixturePath = path.join(process.env.HOME, 'attachment-recovery-sentinel');
      assert.equal(fs.readFileSync(fixturePath, 'utf8'), 'synthetic-attachment-preserve', fixture.name + ': attachment bytes are untouched');
      if (!fixture.errorCode) {
        const drafts = [value.record.draft, ...(value.record.parked || [])].filter(Boolean);
        for (const draft of drafts) {
          for (const job of [...(draft.attachJobs || []), ...(draft.pendingAttachment ? [draft.pendingAttachment] : [])]) {
            assert.equal(job.path, fixturePath, fixture.name + ': pending path is preserved as metadata');
            assert.equal(job.owner, draft.draftKey, fixture.name + ': pending owner matches its draft');
            assert.equal(job.accountId, draft.accountId, fixture.name + ': pending account matches its draft');
            assert.deepEqual(Object.keys(job).sort(), ['accountId','mode','owner','path']);
          }
        }
        assert.ok(!JSON.stringify(value).includes('synthetic-attachment-preserve'), fixture.name + ': recovery never imports file bytes');
      }
    }
    if (fixture.name === 'recovery reads edit history')
      assert.equal(value.record.parked[1].userModified, undefined, 'legacy edit history remains absent');
  }

  await call('message.parse', {raw:17}, -32602);
  const providers = await call('providers.snapshot');
  const providerIds = released && contract.apiVersion < 8 ? ['gmail','outlook','hey','jmap','imap'] : ['gmail'];
  assert.deepEqual(Object.keys(providers).sort(), [...providerIds].sort());
  for (const id of providerIds) {
    assert.ok(providers[id] && providers[id].queries && providers[id].capabilities);
    assert.equal(typeof providers[id].nativeSync, 'boolean');
  }
  const text = 'Hello 合成 📨';
  const raw = 'From: Sender <sender@example.org>\r\nTo: reader@example.org\r\nSubject: Contract message\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n' + text;
  const payload = await call('message.parse', {raw:Buffer.from(raw).toString('base64url')});
  assert.equal(payload.mimeType, 'text/plain');
  assert.equal(Buffer.from(payload.body.data, 'base64url').toString(), text);
  const message = {id:'contract-message',labelIds:['INBOX','UNREAD'],internalDate:'1700000000000',payload};
  const prepared = await call('message.prepare', {message, now:1700000000000});
  assert.equal(prepared.body.text, text);
  assert.equal(prepared.summary.subject, 'Contract message');
  assert.ok(Array.isArray(prepared.attachments));
  const summary = await call('message.summarize', {message, now:1700000000000});
  assert.deepEqual(summary, prepared.summary);
  const html = '<p>Safe text</p><script>forbiddenScript()</script><img src="https://example.org/pixel.png">';
  const rendered = await call('message.render', {html, options:{allowRemoteImages:false,withReader:true}});
  safeDocument(rendered.document); safeDocument(rendered.reader.document);
  assert.ok(!JSON.stringify(rendered.document).includes('https://example.org/pixel.png'));
  const accountId = 'contract@example.org', id = 'cached';
  const resource = {id,payload:{mimeType:'multipart/alternative',headers:payload.headers,parts:[payload,
    {mimeType:'text/html',body:{data:Buffer.from(html).toString('base64url')}}]}};
  assert.equal((await call('cache.resourcePut', {accountId,id,resource})).stored, true);
  const cached = await call('message.prepareCached', {accountId,id});
  assert.equal(cached.nativeContent.body.text, text);
  assert.equal(cached.payload.parts[0].body.data, undefined);
  assert.equal(await call('message.prepareCached', {accountId,id:'missing'}), null);
  const view = await call('reader.open', {accountId,id,requestId:'contract-reader',now:1700000000000,cacheOnly:true,options:{allowRemoteImages:false}});
  assert.equal(typeof view.readerKey, 'string'); assert.ok(view.readerKey.length);
  assert.equal(view.hasHtml, true); assert.equal(view.nativeContent.body.text, text);
  assert.equal(view.nativeContent.html, undefined); assert.equal(view.payload.parts.length, 0);
  safeDocument(view.nativeRender.document); safeDocument(view.nativeRender.reader.document);
  const again = await call('reader.render', {accountId,id,readerKey:view.readerKey,now:1700000000000,options:{allowRemoteImages:false}});
  assert.equal(again.nativeRender.revision, view.nativeRender.revision);
  assert.deepEqual(again.nativeRender.document, view.nativeRender.document);
  // Cross-message identity must fail, without falling through to a network read.
  const wrong = await call('reader.render', {accountId,id:'other',readerKey:view.readerKey,now:1700000000000,options:{}}, -32000);
  assert.equal(typeof wrong.message, 'string');
  // More than one transport frame, with Unicode preserved by the actual QML decoder.
  const large = '合成 📨'.repeat(30000);
  assert.equal((await call('cache.bodyPut', {accountId,id:'chunked',body:{text:large}})).stored, true);
  assert.equal((await call('cache.bodyRead', {accountId,id:'chunked'})).text, large);
  assert.equal((await call('cache.bodyClear', {accountId})).cleared, true);
  assert.equal(await call('cache.bodyRead', {accountId,id:'chunked'}), null);
  console.log(`Backend API ${api}${released ? ' (released view)' : ''} contract PASS: ${tested.size} methods, ${contract.methods.length} advertised methods; binary ${info.version}`);
  finished = true;
  child.stdin.end();
  child.kill('SIGTERM');
})().catch(fail);
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expected-version')
    parser.add_argument('--smoke-host', type=Path, help='exercise a packaged host inside the same isolated data roots')
    parser.add_argument('--smoke-ready', type=Path, help='write the host readiness result to this new file')
    parser.add_argument('--released', action='store_true',
                        help='check only the released API, as the pinned published binary speaks it')
    parser.add_argument('--standalone', action='store_true',
                        help='check standalone capabilities, including native agents on Linux/macOS')
    parser.add_argument('--isolated-windows-runner', action='store_true',
                        help='use isolated app data on a disposable GitHub-hosted Windows runner')
    args = parser.parse_args()
    if os.name == 'nt' and not (args.isolated_windows_runner
            and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'):
        parser.error('Windows contract tests require --isolated-windows-runner on a disposable GitHub-hosted runner')
    if args.smoke_ready and not args.smoke_host:
        parser.error('--smoke-ready requires --smoke-host')
    smoke_host = args.smoke_host.resolve(strict=True) if args.smoke_host else None
    smoke_ready = args.smoke_ready.resolve() if args.smoke_ready else None
    if smoke_ready and smoke_ready.exists():
        parser.error('--smoke-ready must name a new file')
    binary = args.binary.resolve(strict=True)
    contract = selected_contract(args.released)
    with tempfile.TemporaryDirectory(prefix='omamail-api-contract-') as directory, ExitStack() as cleanup:
        # macOS exposes its temporary root through /var, a symlink to
        # /private/var. The production storage boundary refuses symlinked
        # ancestors, so seed and advertise the canonical isolated root.
        home = Path(directory).resolve()
        storage_roots = [home]
        env = {key: value for key, value in os.environ.items()
               if key in ('PATH', 'LANG', 'LC_ALL', 'SYSTEMROOT', 'QT_QPA_PLATFORM')}
        if os.name == 'nt':
            config_root = home / 'AppData/Roaming'
            get_folder, set_folder = windows_known_folders()
            local_root = Path(get_folder('f1b32785-6fba-4fcf-9d55-7b8e7f157091'))
            # Windows forbids relocating LocalAppData. Claim only this app's absent
            # subtree on the disposable runner; never reuse or remove existing data.
            owned_data = cleanup.enter_context(exclusive_fixture_directory(local_root / 'OmamailData'))
            storage_roots.append(owned_data)
            cache_root = local_root / 'OmamailData/Cache'
            state_root = local_root / 'OmamailData/State'
            data_root = local_root / 'OmamailData'
            runtime_root = local_root / 'OmamailData/Runtime'
            env.update(USERPROFILE=str(home), APPDATA=str(config_root),
                       LOCALAPPDATA=str(local_root))
        elif sys.platform == 'darwin':
            config_root = home / 'Library/Application Support'
            cache_root = home / 'Library/Caches'
            state_root = config_root
            data_root = config_root
            runtime_root = home / 'run'
        else:
            config_root = home / 'config'
            cache_root = home / 'cache'
            state_root = home / 'state'
            data_root = home / 'data'
            runtime_root = home / 'run'
            env.update(XDG_CONFIG_HOME=str(config_root), XDG_CACHE_HOME=str(cache_root),
                       XDG_DATA_HOME=str(data_root), XDG_STATE_HOME=str(state_root),
                       XDG_RUNTIME_DIR=str(runtime_root))
        registry = config_root / 'omamail/accounts.json'
        env.update(HOME=str(home), TMPDIR=str(runtime_root), TEMP=str(runtime_root),
                   TMP=str(runtime_root), CONTRACT_REGISTRY_PATH=str(registry),
                   CONTRACT_ROOT=str(ROOT), CONTRACT_BINARY=str(binary),
                   CONTRACT_STORAGE_ROOTS=json.dumps([str(root) for root in storage_roots]),
                   CONTRACT_VERSION=args.expected_version or '',
                   CONTRACT_RELEASED='1' if args.released else '',
                   CONTRACT_STANDALONE='1' if args.standalone else '')
        runtime_root.mkdir(parents=True, mode=0o700)
        if os.name == 'nt':
            (home / 'Downloads').mkdir(mode=0o700)
        registry.parent.mkdir(parents=True)
        if os.name != 'nt':
            registry.parent.chmod(0o700)
        accounts = [{'email': 'contract@example.org'}]
        if args.released and contract['apiVersion'] < 8:
            accounts.extend([
            {'provider': 'imap', 'email': 'sender@example.org',
             'imap': {'username': 'sender@example.org'}},
            {'provider': 'imap', 'email': 'named@example.org', 'senderName': 'Jane Example',
             'imap': {'username': 'named@example.org'}},
            {'provider': 'hey', 'email': 'sender@example.org'},
            {'provider': 'outlook', 'email': 'sender@example.org'}])
        gmail_status_cases = [case for case in contract['contractCases']
                              if case['name'].startswith('Gmail request status: ')]
        accounts.extend({'provider': 'gmail', 'email': case['params']['accountId']}
                        for case in gmail_status_cases)
        registry.write_text(json.dumps({'version': 1, 'activeId': 'contract@example.org',
                                        'accounts': accounts}))
        registry.chmod(0o600)
        for root in (cache_root, state_root, data_root):
            sentinel = root / 'omamail/sentinel'
            sentinel.parent.mkdir(parents=True, exist_ok=True)
            if os.name != 'nt':
                sentinel.parent.chmod(0o700)
            sentinel.write_bytes(b'preserve existing user state\n')
        import hashlib
        for case in gmail_status_cases:
            account = case['params']['accountId']
            folder = state_root / 'omamail/mail' / hashlib.sha256(account.encode()).hexdigest()
            folder.mkdir(parents=True, mode=0o700)
            folder.parent.chmod(0o700)
            database = folder / 'mail.sqlite'
            with sqlite3.connect(database) as connection:
                connection.executescript((ROOT / 'src/local_mail/schema.sql').read_text())
                connection.execute('INSERT INTO state VALUES(?,?)', ('error', case['equals']['error']))
                connection.execute('INSERT INTO jobs(id,error) VALUES(?,?)', ('synthetic-pending', case['equals']['error']))
            connection.close()
            database.chmod(0o600)
        summary_cases = [case for case in contract['contractCases']
                         if case['name'] == 'Local summaries return cached effective labels and query matches']
        if summary_cases:
            folder = state_root / 'omamail/mail' / hashlib.sha256(b'contract@example.org').hexdigest()
            folder.mkdir(parents=True, mode=0o700)
            folder.parent.chmod(0o700)
            database = folder / 'mail.sqlite'
            summary = {'id': 'search-cached', 'threadId': 'search-thread',
                       'subject': 'Synthetic invoice', 'unread': True,
                       'labelIds': ['INBOX', 'UNREAD']}
            with sqlite3.connect(database) as connection:
                connection.executescript((ROOT / 'src/local_mail/schema.sql').read_text())
                connection.execute('INSERT INTO messages(id,thread_id,date,summary,blob,server_labels,sender,recipients,copied,subject,filenames,has_attachment,text_complete) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
                                   ('search-cached', 'search-thread', 1792662000000, json.dumps(summary),
                                    '0' * 64, '["INBOX","UNREAD"]', 'sender@example.org',
                                    'contract@example.org', '', 'Synthetic invoice', '', 0, 1))
                connection.execute('INSERT INTO labels VALUES(?,?)', ('search-cached', 'INBOX'))
                connection.execute('INSERT INTO edits(ticket,id,additions,removals,before_labels) VALUES(?,?,?,?,?)',
                                   ('contract-search-edit', 'search-cached', '[]', '["UNREAD"]', '["INBOX","UNREAD"]'))
                connection.execute('INSERT INTO search(id,subject,sender,recipients,copied,filenames,body) VALUES(?,?,?,?,?,?,?)',
                                   ('search-cached', 'Synthetic invoice', 'sender@example.org',
                                    'contract@example.org', '', '', 'Synthetic saved message'))
            connection.close()
            database.chmod(0o600)
        digest = hashlib.sha256()
        for part in ('overviews', 'contract@example.org'):
            encoded = part.encode()
            digest.update(len(encoded).to_bytes(8, 'little'))
            digest.update(encoded)
        inbox = state_root / 'omamail/inbox'
        inbox.mkdir(mode=0o700)
        overview = inbox / (digest.hexdigest() + '.json')
        overview.write_text(json.dumps({'cached': {'state': 'failed', 'reason': 'AI response could not be verified against the mail; retry from Menu', 'version': 1, 'updated': 1}, 'ready': {'state': 'ready', 'text': 'Receipt — R780 paid', 'version': 2, 'expiresAt': 0, 'updated': 1}, 'expired': {'state': 'ready', 'text': 'Due yesterday', 'version': 2, 'expiresAt': 1, 'updated': 1}}))
        overview.chmod(0o600)
        helpers = home / 'bin'
        helpers.mkdir()
        credential_helper = helpers / 'secret-tool'
        credential_helper.write_text('#!/bin/sh\nprintf touched >> "$HOME/credential-touched"\nexit 1\n')
        credential_helper.chmod(0o700)
        env['PATH'] = str(helpers) + os.pathsep + env.get('PATH', '')
        if os.name == 'nt':
            # Replace every DACL: Python 0700 directories include explicit SYSTEM,
            # Administrators and OWNER RIGHTS grants that inheritance:r cannot remove.
            make_windows_fixture_private(storage_roots)
        folders = windows_fixture_folders(home, config_root, get_folder, set_folder) if os.name == 'nt' else nullcontext()
        with folders:
            if smoke_host:
                ready = smoke_ready or home / 'smoke-ready.json'
                for command in ([str(smoke_host), '--check-resources'],
                                [str(smoke_host), '--smoke-test', str(ready)]):
                    status = run_fixture_process(command, env, home)
                    if status:
                        raise SystemExit(status)
                if not ready.is_file():
                    raise RuntimeError('Packaged host did not create its readiness result')
            status = run_fixture_process(['node', '-e', HARNESS], env, home)
        if status:
            raise SystemExit(status)


if __name__ == '__main__':
    main()
