#!/usr/bin/env python3
"""Verify the message link window opener against a fake Hyprland and a fake browser.

PATH holds only the fakes, so no test can reach the real compositor, browser or opener. The fake
browser listens on its own profile socket, as Chrome does, and every one a test starts is stopped
by the process id it recorded.
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
LINK = 'https://jobs.example.com/view/42?trk=mail&x="]]);os.exit()--'
APP_ADDRESS = '0x5629a4b8a0e0'
NOT_PUBLIC = 'Magpie Mail did not open the link, because it is not a public web address.'
NO_ANSWER = 'The browser did not answer, so the link did not open.'
NOT_ANSWERED = 'The browser has not answered, so the link may not open.'
NO_WINDOW = 'The link window is slow to open, so it may still appear.'
TOO_LONG = 'Magpie Mail did not open the link, because it is too long for the browser.'
SPLIT_NAME = ("Magpie Mail did not open the link, because the config folder Chrome reads its flags from has a space "
              "or one of * ? [ ( in its name.")
SITE = ['-a', 'Magpie Mail', '-t', '5000', 'Opening jobs.example.com']

FAKE_HYPRCTL = r'''
import fcntl, json, os, re, sys
state_path = os.environ['FAKE_STATE']
lock = open(state_path + '.lock', 'a')
fcntl.flock(lock, fcntl.LOCK_EX)
with open(state_path) as stream:
    state = json.load(stream)
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(['hyprctl', *sys.argv[1:]]) + '\n')
arguments = sys.argv[1:]
if arguments[:1] == ['-j']:
    answer = state['answers'].get(arguments[1])
    if answer is None:
        answer = {'clients': state['clients'], 'monitors': state['monitors']}.get(arguments[1], {})
    print(answer if isinstance(answer, str) else json.dumps(answer))
    sys.exit(0)
if arguments[:1] == ['getprop']:
    client = next(c for c in state['clients'] if 'address:' + c['address'] == arguments[1])
    default = 'false' if arguments[2].endswith('_override') else '0.985'
    print(client.get('props', {}).get(arguments[2], default))
    sys.exit(0)
if arguments[:1] == ['eval']:
    chunk = arguments[1]
    for client in state['clients']:
        if f'"address:{client["address"]}"' not in chunk:
            continue
        move = re.search(r'window\.move\(\{ workspace = "(\d+)"', chunk)
        if move:
            client['workspace'] = {'id': int(move.group(1)), 'name': move.group(1)}
        if 'window.float({ action = "enable"' in chunk:
            client['floating'] = True
        size = re.search(r'window\.resize\(\{ x = (\d+), y = (\d+), exact = true', chunk)
        if size:
            if state.get('self_resizes', 0) > 0:
                state['self_resizes'] -= 1
                client['size'] = [2558, 1412]
            else:
                client['size'] = [int(size.group(1)), int(size.group(2))]
        if state.get('props_ignored', 0) > 0:
            state['props_ignored'] -= 1
        else:
            for prop in re.findall(r'set_prop\(\{ prop = "([a-z_]+)", value = "1"', chunk):
                client.setdefault('props', {})[prop] = 'true' if prop.endswith('_override') else '1.000000'
    with open(state_path, 'w') as stream:
        json.dump(state, stream)
    sys.exit(0)
sys.exit(1)
'''

# The browser. Started as a launcher it hands its command line to a running browser, as Chrome's
# second process does, or becomes the browser: it writes its process name, takes the profile lock,
# listens on the profile socket and opens a window for each --app it is given.
FAKE_CHROME = r'''
import fcntl, json, os, socket, sys, tempfile, time, urllib.parse
STATE = os.environ['FAKE_STATE']

def data_folder():
    # The launcher reads its flags files unquoted, without lines that start with '#'; only Chromium's
    # reads the one in /etc, before the user's, and takes an empty XDG_CONFIG_HOME as the folder it runs
    # in. A relative folder is read from the browser's own.
    chromium = os.path.basename(sys.argv[0]) == 'chromium'
    product, name = ('chromium', 'chromium-flags.conf') if chromium else ('google-chrome', 'chrome-flags.conf')
    config = os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.environ['HOME'], '.config')
    chosen = ''
    for folder in [os.environ['FAKE_ETC'], os.environ.get('XDG_CONFIG_HOME', config)] if chromium else [config]:
        try:
            with open(os.path.join(folder, name)) as stream:
                for line in stream:
                    for word in [] if line.startswith('#') else line.split():
                        if word.startswith('--user-data-dir='):
                            chosen = word[16:]
        except OSError:
            pass
    chosen = chosen or os.environ.get('CHROME_USER_DATA_DIR', '')
    if chosen:
        return os.path.abspath(chosen)
    if os.environ.get('CHROME_CONFIG_HOME'):
        return os.path.join(os.path.abspath(os.environ['CHROME_CONFIG_HOME']), product)
    return os.path.join(os.path.abspath(config), product)

PROFILES = data_folder()
LOCK = os.path.join(PROFILES, 'SingletonLock')
SOCKET = os.path.join(PROFILES, 'SingletonSocket')

def log(*call):
    with open(os.environ['FAKE_LOG'], 'a') as stream:
        stream.write(json.dumps(list(call)) + '\n')

def read_state():
    with open(STATE + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(STATE) as stream:
            return json.load(stream)

def open_window(arguments):
    app = next((value[6:] for value in arguments if value.startswith('--app=')), None)
    profile = next((value[20:] for value in arguments if value.startswith('--profile-directory=')), 'Default')
    if not app:
        return
    with open(STATE + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(STATE) as stream:
            state = json.load(stream)
        if state.get('no_window'):
            return
        parts = urllib.parse.urlsplit(app)
        if state.get('other_window_first'):
            state['clients'].append({'address': '0x77aa', 'class': 'chrome-web.whatsapp.com__-Default',
                                     'floating': False, 'size': [1260, 1388], 'workspace': {'id': 4}})
        if state.pop('restores_link_window', False):
            state['clients'].append({'address': '0x88bb', 'floating': False, 'size': [1260, 1388],
                                     'class': 'chrome-__run_user_1000_magpie-links_0123456789abcdef_link-window.html-Default',
                                     'workspace': {'id': 2, 'name': '2'}})
        app_class = 'chrome-' + (parts.hostname or '') + '_' + parts.path.replace('/', '_') + '-' + profile.replace(' ', '_')
        desk = state.get('opens_on', 4)
        opened = sum(1 for client in state['clients'] if 'opened_link' in client)
        state['clients'].append({'address': state.get('next_address', hex(0x5629a4b8a0e0 + opened)), 'class': app_class,
                                 'floating': False, 'size': [1260, 1388], 'workspace': {'id': desk, 'name': str(desk)},
                                 'opened_link': forwarded(parts.fragment)})
        with open(STATE, 'w') as stream:
            json.dump(state, stream)

def forwarded(fragment):
    # The page forwards only a link whose length, given first, says it arrived whole.
    length, _, encoded = fragment.partition(':')
    return urllib.parse.unquote(encoded) if length.isdigit() and int(length) == len(encoded) else None

def running():
    try:
        pid = int(os.readlink(LOCK).rpartition('-')[2])
        with open(f'/proc/{pid}/comm') as stream:
            name = stream.read().strip()
        with open(f'/proc/{pid}/cmdline', 'rb') as stream:
            command = stream.read().replace(b'\0', b' ').split(b' ')
    except (OSError, ValueError):
        return False
    # Chrome, too, starts over a lock that names one of a browser's helpers, after waiting for it.
    return name == 'chrome' and not (len(command) > 1 and command[1].startswith(b'--type='))

def forward(arguments):
    target = os.readlink(SOCKET)
    folder = os.open(os.path.dirname(target), os.O_PATH | os.O_DIRECTORY)
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(5)
        channel.connect(f'/proc/self/fd/{folder}/{os.path.basename(target)}')
        channel.sendall(b'\0'.join(part.encode() for part in ['START', os.getcwd(), 'chrome', *arguments]))
        channel.shutdown(socket.SHUT_WR)
        channel.recv(16)

def serve(arguments, listen_delay):
    with open('/proc/self/comm', 'w') as stream:
        stream.write('chrome')
    with open(os.environ['FAKE_PIDS'], 'a') as stream:
        stream.write(f'{os.getpid()}\n')
    # Chrome takes a while to start before it locks its profile.
    time.sleep(read_state().get('lock_delay', 0))
    os.makedirs(PROFILES, exist_ok=True)
    for path in (LOCK, SOCKET):
        if os.path.lexists(path):
            os.unlink(path)
    os.symlink(f'{socket.gethostname()}-{os.getpid()}', LOCK)
    time.sleep(listen_delay)
    sockets = tempfile.mkdtemp(dir=os.environ['FAKE_SOCKETS'])
    folder = os.open(sockets, os.O_PATH | os.O_DIRECTORY)
    server = socket.socket(socket.AF_UNIX)
    server.bind(f'/proc/self/fd/{folder}/SingletonSocket')
    server.listen(16)
    os.symlink(os.path.join(sockets, 'SingletonSocket'), SOCKET)
    time.sleep(read_state().get('window_delay', 0))
    open_window(arguments)
    held = []
    server.settimeout(0.5)
    end = time.monotonic() + 60
    while time.monotonic() < end:
        try:
            channel, _ = server.accept()
        except socket.timeout:
            continue
        mode = read_state().get('browser', 'answers')
        log('connected', mode)
        if mode == 'hung':
            held.append(channel)
            continue
        channel.settimeout(5)
        message = b''
        try:
            while True:
                chunk = channel.recv(65536)
                if not chunk:
                    break
                message += chunk
        except OSError:
            pass
        if len(message) > 32 * 1024:
            log('overflow', len(message))
        parts = message.split(b'\0')
        if parts[0] != b'START' or len(parts) < 3:
            log('bad-message')
            channel.close()
            continue
        log('handoff', *(part.decode() for part in parts[1:]))
        if mode == 'quitting':
            os.unlink(LOCK)
            os.unlink(SOCKET)
            channel.sendall(b'SHUTDOWN')
            channel.close()
            return
        open_window([part.decode() for part in parts[3:]])
        if mode == 'answers':
            channel.sendall(b'ACK')
        channel.close()

if sys.argv[1:2] == ['--serve']:
    serve(json.loads(sys.argv[2]), float(sys.argv[3]))
    sys.exit(0)
log(os.path.basename(sys.argv[0]), *sys.argv[1:])
if running():
    forward(sys.argv[1:])
    sys.exit(0)
os.execv(sys.executable, ['chrome', os.path.abspath(sys.argv[0]), '--serve', json.dumps(sys.argv[1:]),
                          str(read_state().get('listen_delay', 0))])
'''

FAKE_SYSTEMD_RUN = r'''
import json, os, sys, time
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(['systemd-run', *sys.argv[1:]]) + '\n')
with open(os.environ['FAKE_STATE']) as stream:
    state = json.load(stream)
time.sleep(state.get('start_delay', 0))
if state.get('systemd_run_fails'):
    sys.exit(1)
command = sys.argv[sys.argv.index('--') + 1:]
os.execv(command[0], command)
'''

FAKE_LOGGED = r'''
import json, os, sys
name = os.path.basename(sys.argv[0])
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + '\n')
    if name == 'xdg-open':
        log.write(json.dumps(['xdg-open-folder', os.getcwd()]) + '\n')
'''

FAKE_DEFAULT_BROWSER = r'''
import os
print(os.environ.get('FAKE_DEFAULT_BROWSER', 'google-chrome.desktop'))
'''


def make_command(folder, name, body):
    path = folder / name
    path.write_text(f'#!{sys.executable}\n' + textwrap.dedent(body))
    path.chmod(0o755)


def fragment(link):
    encoded = urllib.parse.quote(link, safe='')
    return f'#{len(encoded)}:{encoded}'


def finished_pid():
    finished = subprocess.Popen([sys.executable, '-c', 'pass'])
    finished.wait()
    return finished.pid


class LinkWindow(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='magpie-link-window-')
        self.root = Path(self.temporary.name)
        self.plugin = self.root / 'plugin/scripts'
        self.plugin.mkdir(parents=True)
        self.script = self.plugin / 'open-link-window.py'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.etc = self.root / 'etc'
        self.etc.mkdir()
        # Invariant: the copy finds the browser and its system-wide flags where the fakes are.
        script = (ROOT / 'scripts/open-link-window.py').read_text()
        for line, value in (("SYSTEM_BIN = '/usr/bin'\n", self.bin), ("SYSTEM_CONFIG = '/etc'\n", self.etc),
                            ("LAUNCHER_SHELL = '/bin/bash'\n", self.bin / 'bash')):
            self.assertEqual(script.count(line), 1, line)
            script = script.replace(line, line.split('=')[0] + f'= {str(value)!r}\n')
        self.script.write_text(script)
        shutil.copy(ROOT / 'scripts/link-window.html', self.plugin / 'link-window.html')
        make_command(self.bin, 'google-chrome-stable', FAKE_CHROME)
        (self.bin / 'bash').symlink_to('/bin/bash')
        make_command(self.bin, 'systemd-run', FAKE_SYSTEMD_RUN)
        for name in ('xdg-open', 'firefox', 'notify-send'):
            make_command(self.bin, name, FAKE_LOGGED)
        make_command(self.bin, 'hyprctl', FAKE_HYPRCTL)
        make_command(self.bin, 'omarchy-cmd-default-browser', FAKE_DEFAULT_BROWSER)
        applications = self.root / 'data/applications'
        applications.mkdir(parents=True)
        (applications / 'google-chrome.desktop').write_text(
            '[Desktop Entry]\nName=Google Chrome\nExec=google-chrome-stable %U\n'
            '[Desktop Action new-window]\nExec=other-browser\n')
        (applications / 'firefox.desktop').write_text('[Desktop Entry]\nExec=firefox %u\n')
        self.profiles = self.root / 'config/google-chrome'
        for folder in ('Default', 'Profile 1', 'System Profile', 'Guest Profile'):
            (self.profiles / folder).mkdir(parents=True)
        self.write_local_state({
            'Default': {'name': 'Personal', 'user_name': 'person@gmail.example'},
            'Profile 1': {'name': 'Work', 'user_name': 'Reader@Work.Example'},
        })
        self.home = self.root / 'home'
        self.home.mkdir()
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        (self.root / 'tmp').mkdir(mode=0o700)
        self.sockets = self.root / 'sockets'
        self.sockets.mkdir(mode=0o700)
        self.pids = self.root / 'pids'
        self.pids.write_text('')
        self.log = self.root / 'log'
        self.log.write_text('')
        self.state = self.root / 'state.json'
        self.write_state({})
        self.started = []
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.close_browser)
        self.start_browser()

    def write_local_state(self, profiles):
        (self.profiles / 'Local State').write_text(json.dumps({'profile': {'info_cache': profiles}}))

    def write_state(self, extra):
        state = {
            'clients': [
                {'address': '0x1', 'class': 'org.quickshell', 'floating': False, 'size': [1260, 1388],
                 'workspace': {'id': 4, 'name': 'Messaging'}},
                {'address': '0x2', 'class': 'chrome-mail.google.com__mail_-Profile_1', 'floating': False,
                 'size': [1260, 1388], 'workspace': {'id': 3, 'name': 'Browsers'}},
            ],
            'monitors': [{'id': 0, 'width': 5120, 'height': 2880, 'scale': 2, 'transform': 0, 'focused': True}],
            'answers': {
                'activewindow': {'address': '0x1', 'monitor': 0, 'workspace': {'id': 4, 'name': 'Messaging'}},
                'activeworkspace': {'id': 4, 'monitorID': 0},
            },
        }
        state.update(extra)
        self.state.write_text(json.dumps(state))

    def change_state(self, change):
        state = json.loads(self.state.read_text())
        change(state)
        self.state.write_text(json.dumps(state))

    def opener_environment(self, hyprland, environment):
        env = {'PATH': str(self.bin), 'HOME': str(self.home), 'XDG_CONFIG_HOME': str(self.root / 'config'),
               'XDG_DATA_HOME': str(self.root / 'data'), 'XDG_DATA_DIRS': str(self.root / 'none'),
               'XDG_RUNTIME_DIR': str(self.runtime), 'TMPDIR': str(self.root / 'tmp'),
               'FAKE_STATE': str(self.state), 'FAKE_LOG': str(self.log), 'MAGPIE_LINK_WINDOW_WAIT': '2',
               'FAKE_ETC': str(self.etc), 'FAKE_SOCKETS': str(self.sockets), 'FAKE_PIDS': str(self.pids)}
        if hyprland:
            env['HYPRLAND_INSTANCE_SIGNATURE'] = 'test-instance'
        env.update(environment)
        # Invariant: a variable given as None is left out.
        return {name: value for name, value in env.items() if value is not None}

    def start_browser(self, listen_delay=0, sockets=None):
        """A browser of this user's holds the profile and, unless it is still starting, listens on it."""
        environment = self.opener_environment(True, {'FAKE_SOCKETS': str(sockets or self.sockets)})
        browser = subprocess.Popen(['chrome', str(self.bin / 'google-chrome-stable'), '--serve', '[]',
                                    str(listen_delay)], executable=sys.executable, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.started.append(browser)
        lock, listening = self.profiles / 'SingletonLock', self.profiles / 'SingletonSocket'
        deadline = time.monotonic() + 10
        while not (os.path.lexists(lock) if listen_delay else listening.exists()):
            self.assertLess(time.monotonic(), deadline, 'the fake browser did not start')
            time.sleep(0.02)

    def close_browser(self):
        """Stop every fake browser this test started, by the process id each one recorded."""
        for browser in self.started:
            browser.terminate()
            browser.wait(timeout=10)
        self.started = []
        for line in self.pids.read_text().split():
            try:
                with open(f'/proc/{int(line)}/cmdline', 'rb') as stream:
                    command = stream.read()
            except OSError:
                continue
            # Invariant: a recorded id is stopped only while it is still this test's fake browser.
            if any(str(self.bin / name).encode() in command for name in ('google-chrome-stable', 'chromium')):
                os.kill(int(line), signal.SIGTERM)
        self.pids.write_text('')
        for name in ('SingletonLock', 'SingletonSocket'):
            if os.path.lexists(self.profiles / name):
                (self.profiles / name).unlink()

    def run_opener(self, *arguments, hyprland=True, cwd=None, **environment):
        result = subprocess.run([sys.executable, '-I', str(self.script), *arguments],
                                env=self.opener_environment(hyprland, environment), cwd=cwd, capture_output=True,
                                text=True, timeout=60)
        self.settle()
        return result

    def settle(self):
        # Invariant: a detached fake may still be writing its call when the opener exits.
        deadline = time.monotonic() + 3
        seen = self.log.read_text()
        while time.monotonic() < deadline:
            time.sleep(0.4)
            now = self.log.read_text()
            if now == seen:
                break
            seen = now

    def lock_profiles(self, holder):
        (self.profiles / 'SingletonLock').symlink_to(holder)

    def calls(self, name=None):
        found = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [call for call in found if name is None or call[0] == name]

    def handoffs(self):
        """What the opener itself handed to the running browser: the working folder, then the command line."""
        return [call for call in self.calls('handoff') if call[2] == 'browser']

    def told(self):
        return [call[1:] for call in self.calls('notify-send')]

    def windows_opened(self):
        return [client for client in json.loads(self.state.read_text())['clients'] if 'opened_link' in client]

    def evals(self):
        return [call[2] for call in self.calls('hyprctl') if call[1] == 'eval']

    def client(self, address=APP_ADDRESS):
        clients = json.loads(self.state.read_text())['clients']
        return next(client for client in clients if client['address'] == address)

    def assert_page(self, arguments, link=LINK, folder=None):
        """The browser was given only this click's own copy of the page, carrying the link."""
        folder = folder or self.runtime / 'magpie-links'
        self.assertEqual(len(arguments), 1, arguments)
        page = re.escape(folder.as_uri()) + r'/[0-9a-f]{16}/link-window\.html'
        self.assertRegex(arguments[0], '^--app=' + page + re.escape(fragment(link)) + '$')
        return Path(urllib.parse.urlsplit(arguments[0][6:]).path)

    def assert_tab(self, link=LINK):
        """The running browser was given the link alone, which opens it in a tab, and nothing started."""
        self.assertEqual(self.handoffs(), [['handoff', '/', 'browser', '--profile-directory=Profile 1', link]])
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.calls('systemd-run'), [])

    def assert_started_with_tab(self, link=LINK):
        """The browser was started with the link alone, which opens it in a tab, and nothing else."""
        started = self.calls('systemd-run')
        self.assertEqual(len(started), 1)
        self.assertEqual(started[0][started[0].index('--') + 1:],
                         [str(self.bin / 'google-chrome-stable'), '--profile-directory=Profile 1', link])
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.handoffs(), [])

    def assert_too_long(self, result):
        """The link was told too long, and nothing was started, connected to or handed over."""
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.told(), [['-a', 'Magpie Mail', TOO_LONG]])
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.calls('connected'), [])

    def assert_refused(self, link):
        self.log.write_text('')
        result = self.run_opener(link, 'reader@work.example')
        self.assertEqual(result.returncode, 2)
        self.assertEqual([call for call in self.calls() if call[0] != 'notify-send'], [])
        self.assertEqual(self.told(), [['-a', 'Magpie Mail', NOT_PUBLIC]])
        self.assertFalse((self.runtime / 'magpie-links').exists())

    def test_the_link_opens_in_the_mailbox_profile_floating_over_the_desk(self):
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        handed = self.handoffs()
        self.assertEqual(len(handed), 1)
        self.assertEqual(handed[0][:4], ['handoff', '/', 'browser', '--profile-directory=Profile 1'])
        self.assert_page(handed[0][4:])
        window = self.client()
        self.assertEqual(window['opened_link'], LINK)
        self.assertTrue(window['floating'])
        self.assertEqual(window['size'], [1280, 922])
        self.assertEqual(window['workspace']['id'], 4)
        self.assertIn(f'hl.dispatch(hl.dsp.focus({{ window = "address:{APP_ADDRESS}" }}))', self.evals()[0])
        self.assertIn(f'hl.dsp.window.center({{ window = "address:{APP_ADDRESS}" }})', self.evals()[0])
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.calls('google-chrome-stable'), [])
        self.assertEqual(self.told(), [SITE])

    def test_the_site_is_shown_for_a_few_seconds_and_nothing_else_of_the_link(self):
        self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(self.told(), [SITE])
        self.assertFalse(any(part in ' '.join(self.told()[0]) for part in ('view', '42', 'trk', 'mail&')))

    def test_the_window_is_named_after_the_page_and_not_the_link(self):
        self.run_opener(LINK, 'reader@work.example')
        page = self.assert_page(self.handoffs()[0][4:])
        window_class = self.client()['class']
        self.assertEqual(window_class, 'chrome-_' + str(page).replace('/', '_') + '-Profile_1')
        self.assertIn('_link-window.html-', window_class)
        self.assertNotIn('jobs.example.com', window_class)
        self.assertNotIn('view_42', window_class)

    def test_each_click_gets_its_own_private_copy_of_the_page(self):
        self.run_opener(LINK, 'reader@work.example')
        self.write_state({})
        self.run_opener(LINK, 'reader@work.example')
        pages = [self.assert_page(call[4:]) for call in self.handoffs()]
        self.assertEqual(len(pages), 2)
        self.assertNotEqual(pages[0].parent, pages[1].parent)
        for page in pages:
            self.assertEqual(page.read_bytes(), (ROOT / 'scripts/link-window.html').read_bytes())
            self.assertEqual(page.stat().st_mode & 0o777, 0o600)
            self.assertEqual(page.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.runtime / 'magpie-links').stat().st_mode & 0o777, 0o700)

    def test_pages_left_from_earlier_clicks_are_cleared_and_nothing_else(self):
        folder = self.runtime / 'magpie-links'
        folder.mkdir(mode=0o700)
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'link-window.html').write_text('keep')
        old = time.time() - 3600
        for name in ('aaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbb', 'not-a-page-folder'):
            (folder / name).mkdir()
            (folder / name / 'link-window.html').write_text('page')
        (folder / 'dddddddddddddddd').mkdir()
        (folder / 'eeeeeeeeeeeeeeee').mkdir()
        (folder / 'eeeeeeeeeeeeeeee' / 'other').write_text('keep')
        (folder / 'ffffffffffffffff').mkdir()
        (folder / 'ffffffffffffffff' / 'link-window.html').symlink_to(outside / 'link-window.html')
        (folder / 'cccccccccccccccc').symlink_to(outside)
        for name in ('aaaaaaaaaaaaaaaa', 'not-a-page-folder', 'dddddddddddddddd', 'eeeeeeeeeeeeeeee',
                     'ffffffffffffffff'):
            os.utime(folder / name, (old, old))
        os.utime(folder / 'cccccccccccccccc', (old, old), follow_symlinks=False)
        # Invariant: a sweep that followed the link would find an old folder at its end.
        os.utime(outside, (old, old))
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        left = sorted(path.name for path in folder.iterdir())
        page = self.assert_page(self.handoffs()[0][4:])
        self.assertEqual(left, sorted(['bbbbbbbbbbbbbbbb', 'cccccccccccccccc', 'eeeeeeeeeeeeeeee', 'ffffffffffffffff',
                                       'not-a-page-folder', page.parent.name]))
        self.assertEqual((outside / 'link-window.html').read_text(), 'keep')
        self.assertEqual((folder / 'eeeeeeeeeeeeeeee' / 'other').read_text(), 'keep')
        self.assertTrue((folder / 'ffffffffffffffff' / 'link-window.html').is_symlink())

    def test_a_page_folder_that_is_not_private_opens_the_link_in_a_tab(self):
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir(mode=0o700)
        folder = self.runtime / 'magpie-links'
        for browser in ('running', 'closed'):
            for kind in ('shared', 'link'):
                with self.subTest(browser=browser, kind=kind):
                    if browser == 'closed':
                        self.close_browser()
                    if kind == 'shared':
                        folder.mkdir()
                        folder.chmod(0o755)
                    else:
                        folder.symlink_to(elsewhere)
                    self.log.write_text('')
                    result = self.run_opener(LINK, 'reader@work.example')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if browser == 'running':
                        self.assert_tab()
                    else:
                        self.assert_started_with_tab()
                    self.assertEqual(list(elsewhere.iterdir()), [])
                    self.assertEqual(list(folder.iterdir()), [])
                    folder.unlink() if kind == 'link' else folder.rmdir()

    def test_without_a_session_folder_the_page_goes_to_a_private_temporary_folder(self):
        result = self.run_opener(LINK, 'reader@work.example', XDG_RUNTIME_DIR='')
        self.assertEqual(result.returncode, 0, result.stderr)
        folder = self.root / 'tmp' / f'magpie-links-{os.getuid()}'
        self.assert_page(self.handoffs()[0][4:], folder=folder)
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        self.assertTrue(self.client()['floating'])

    def test_the_link_window_is_solid(self):
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['props'], {
            'opacity': '1.000000', 'opacity_override': 'true', 'opacity_inactive': '1.000000',
            'opacity_inactive_override': 'true', 'opacity_fullscreen': '1.000000',
            'opacity_fullscreen_override': 'true'})

    def test_opacity_that_does_not_take_is_set_again(self):
        self.write_state({'props_ignored': 1})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['props']['opacity_override'], 'true')

    def test_opacity_that_never_takes_is_reported(self):
        self.write_state({'props_ignored': 99})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.told(), [SITE], 'the window is on screen, so only its site is told')

    def test_the_link_never_reaches_hyprland(self):
        self.run_opener(LINK, 'reader@work.example')
        step = r'hl\.dispatch\(hl\.dsp\.(window\.(move|float|resize|center|set_prop)|focus)\(\{[ a-z0-9_=",:]*\}\)\)'
        allowed = re.compile(step + '(; ' + step + ')*')
        self.assertTrue(self.evals())
        for call in self.calls('hyprctl'):
            self.assertFalse(any('example' in part or 'jobs' in part for part in call), call)
        for chunk in self.evals():
            self.assertIsNotNone(allowed.fullmatch(chunk), chunk)

    def test_an_unknown_mailbox_uses_the_browser_default_profile(self):
        result = self.run_opener(LINK, 'nobody@example.com')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_page(self.handoffs()[0][3:])

    def test_no_mailbox_uses_the_browser_default_profile(self):
        result = self.run_opener(LINK)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_page(self.handoffs()[0][3:])

    def test_only_real_profile_folders_are_used(self):
        for folder in ('..', '../../outside', 'System Profile', 'Guest Profile', 'Profile 1/../..', 'Profile 3'):
            with self.subTest(folder=folder):
                self.log.write_text('')
                self.write_state({})
                self.write_local_state({folder: {'user_name': 'reader@work.example'}})
                result = self.run_opener(LINK, 'reader@work.example')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_page(self.handoffs()[0][3:])

    def test_a_broken_local_state_is_ignored(self):
        for text in ('not json', '[]', '{"profile": []}', '{"profile": {"info_cache": {"Default": "x"}}}',
                     '[' * 60000):
            with self.subTest(text=text[:20]):
                self.log.write_text('')
                self.write_state({})
                (self.profiles / 'Local State').write_text(text)
                result = self.run_opener(LINK, 'reader@work.example')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_page(self.handoffs()[0][3:])

    def test_links_that_are_not_web_links_open_nothing(self):
        for link in ('javascript:alert(1)', 'file:///etc/passwd', '--app=https://x.example', 'https://',
                     'https://example.com/\x01second', 'https://example.com/\x7f', 'chrome://settings',
                     'http\u017f://example.com/x', '\x1fhttps://example.com/', 'https://example.com/\x1f',
                     '\x85https://example.com/', 'https://a..example.com/',
                     'https://\\@example.com/', 'https:\\\\example.com/', 'https://[::1/', 'https://[::1]/',
                     'https://example.com:example.com/x', 'https://example.com:99999/', 'https://example.com:-1/'):
            with self.subTest(link=link[:40]):
                self.assert_refused(link)

    def test_links_to_private_or_local_hosts_open_nothing(self):
        # Invariant: the browser decodes no character references, so `&sol;` is not a slash to it,
        # and everything before the last @ is the user's name.
        for link in ('https://example.com&sol;@192.168.1.1/admin', 'https://example.com&SOL;@192.168.1.1/',
                     'https://example.com&sol@10.0.0.1/', 'https://www.google.com&sol;@localhost:631/',
                     'https://docs.example.com&sol;@router.lan/', 'https://example.com&amp;sol;@192.168.1.1/',
                     'https://192.168.1.1/', 'https://LOCALHOST/', 'https://printer.local/', 'https://127.1/',
                     'https://0x7f.0.0.1/', 'https://2130706433/', 'https://010.0.0.1/', 'https://example.com./',
                     'https://intranet/', 'https://exa­mple.com/', 'https://%31%39%32.168.1.1/',
                     'https://user@169.254.169.254/latest', 'https://100.64.0.1:8080/',
                     'https://good.example@other@192.168.1.1/', 'https://08.8.8.8/', 'https://127.0.0.1/',
                     'https://172.16.0.1/', 'https://172.31.255.255/', 'https://192.0.2.1/', 'https://198.18.0.1/',
                     'https://0.1.2.3/', 'https://224.0.0.1/', 'https://255.255.255.255/', 'https://256.1.1.1/'):
            with self.subTest(link=link):
                self.assert_refused(link)

    def test_the_host_is_read_as_the_browser_reads_it(self):
        for link, site in (('https://example.com/files\\report.pdf', 'example.com'),
                           ('https://example.com\\path', 'example.com'),
                           ('https://example.com\\@192.168.1.1/', 'example.com'),
                           ('https://www.example.com\\', 'www.example.com'),
                           ('https://example.com／@good.example/', 'good.example'),
                           ('https://paypal.example@evil.example/', 'evil.example'),
                           ('https://Jobs.Example.COM:8443/x', 'jobs.example.com'),
                           ('https://example.com:/x', 'example.com'),
                           ('https://93.184.216.34/', '93.184.216.34')):
            with self.subTest(link=link):
                self.log.write_text('')
                self.write_state({})
                result = self.run_opener(link, 'reader@work.example')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.client()['opened_link'], link)
                self.assertEqual(self.told(), [['-a', 'Magpie Mail', '-t', '5000', f'Opening {site}']])

    def test_line_breaks_inside_a_link_are_dropped(self):
        result = self.run_opener('https://jobs.example.com/view/\n42?trk=\tmail\r', 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['opened_link'], 'https://jobs.example.com/view/42?trk=mail')

    def test_a_link_too_long_for_the_running_browser_is_told_and_never_started_beside_it(self):
        # Invariant: the browser reads 32 KiB of a handoff, whatever names its lock or holds it.
        lock = self.profiles / 'SingletonLock'
        pid = os.readlink(lock).rpartition('-')[2]
        links = ('https://example.com/' + 'a' * 40000, 'https://example.com/' + 'a' * 31000,
                 'https://example.com/' + 'é' * 14500)
        for holder in (socket.gethostname(), 'old-name.example', 'closed'):
            for link in links:
                with self.subTest(holder=holder, length=len(link)):
                    self.log.write_text('')
                    self.write_state({'browser': 'hung'})
                    if holder == 'closed':
                        self.close_browser()
                    else:
                        lock.unlink()
                        self.lock_profiles(f'{holder}-{pid}')
                    self.assert_too_long(self.run_opener(link, 'reader@work.example'))

    def test_a_link_too_long_for_any_browser_is_told_without_a_chromium_browser_too(self):
        for link in ('https://example.com/' + 'a' * 32000, 'https://example.com/' + 'é' * 16000):
            with self.subTest(length=len(link)):
                self.log.write_text('')
                result = self.run_opener(link, 'reader@work.example', FAKE_DEFAULT_BROWSER='firefox.desktop')
                self.assert_too_long(result)

    def test_a_link_too_long_for_a_window_opens_in_a_tab(self):
        # Invariant: encoding the link into the page's fragment can triple its length.
        link = 'https://example.com/' + '/' * 11000
        result = self.run_opener(link, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_tab(link)

    def test_with_the_browser_closed_a_link_too_long_for_a_window_starts_it_in_a_tab(self):
        self.close_browser()
        link = 'https://example.com/' + '/' * 11000
        result = self.run_opener(link, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_started_with_tab(link)

    def test_a_link_whose_window_handoff_would_be_too_long_opens_in_a_tab(self):
        runtime = self.root.joinpath(*['r' * 200] * 15)
        runtime.mkdir(parents=True, mode=0o700)
        link = 'https://example.com/' + 'a' * 26000
        result = self.run_opener(link, 'reader@work.example', XDG_RUNTIME_DIR=str(runtime))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_tab(link)

    def test_a_long_link_that_fits_is_handed_over_whole(self):
        link = 'https://example.com/' + 'a' * 25000
        result = self.run_opener(link, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['opened_link'], link)

    def test_a_missing_page_opens_the_link_in_a_tab(self):
        (self.plugin / 'link-window.html').unlink()
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_tab()
        self.close_browser()
        self.log.write_text('')
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_started_with_tab()

    def test_a_link_the_handoff_rules_leave_to_the_launcher_is_never_handed_over_as_a_tab(self):
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=Something\n')
        (self.plugin / 'link-window.html').unlink()
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_started_with_tab()
        self.assertEqual([call[3:] for call in self.calls('handoff')], [['--profile-directory=Profile 1', LINK]])

    def test_a_link_the_launcher_could_not_hand_over_whole_is_told_and_never_launched(self):
        # Invariant: a running browser reads 32 KiB of a launcher's handoff, with its flags and working
        # folder, and the launcher kills a browser whose answer it cannot read. The launcher's browser
        # may run where Magpie does not look, so a closed browser here changes nothing.
        flags = self.root / 'config/chrome-flags.conf'
        cases = {
            'a long link': ('--disable-features=Something\n', 'https://example.com/' + 'a' * 31000),
            'long flags': ('--disable-features=' + 'x' * 10000 + '\n', 'https://example.com/' + 'a' * 20000),
            'an oversized flags file': ('--ozone-platform=wayland\n#' + 'x' * 70000 + '\n--disable-features=Late\n',
                                        LINK),
        }
        for case, (written, link) in cases.items():
            for browser in ('running', 'closed'):
                with self.subTest(case=case, browser=browser):
                    if browser == 'closed':
                        self.close_browser()
                    else:
                        self.close_browser()
                        self.start_browser()
                    flags.write_text(written)
                    self.log.write_text('')
                    self.assert_too_long(self.run_opener(link, 'reader@work.example'))

    def test_all_a_launcher_may_add_counts_toward_what_the_browser_reads(self):
        # Invariant: each of these alone, at 4,000 bytes or more, tips a link that otherwise fits over
        # what a running browser is sure to read whole, so none of them can be left out of the count.
        link = 'https://example.com/' + 'a' * 25500
        refused = '--disable-features=Something\n'
        flags, system_flags = self.root / 'config/chrome-flags.conf', self.etc / 'chrome-flags.conf'
        long_home = self.root.joinpath(*['h' * 250] * 14)
        long_home.mkdir(parents=True)
        linked_home = self.root / 'linked-home'
        linked_home.symlink_to(long_home)
        crowded = self.root / 'crowded'
        crowded.mkdir()
        for number in range(400):
            (crowded / f'name-{number:07}').write_text('')
        wide = self.root / 'wide'
        wide.mkdir()
        for number in range(33):
            (wide / (f'{number:02}' + '中' * 40)).write_text('')
        dotted = self.root / 'dotted'
        dotted.mkdir()
        for number in range(400):
            (dotted / f'.name-{number:07}').write_text('')
        make_command(self.bin, 'chromium', FAKE_CHROME)
        (self.root / 'data/applications/chromium.desktop').write_text('[Desktop Entry]\nExec=chromium %U\n')
        home_chromium_flags = self.home / 'chromium-flags.conf'
        no_patterns = self.root / 'no-patterns.sh'
        no_patterns.write_text('set -f\n')
        hidden_names = self.root / 'hidden-names.sh'
        hidden_names.write_text('shopt -s dotglob\n')
        echo_zero = {'BASH_FUNC_echo%%': '() { builtin echo 0; }'}
        # Invariant: Magpie may run from any folder; the launcher runs from the home folder.
        elsewhere = self.root / 'elsewhere/deeper'
        elsewhere.mkdir(parents=True)
        big = 'x' * 4000
        cases = {
            'system flags': ({system_flags: refused}, {system_flags: '--disable-features=' + big + '\n'}, {}, {}),
            'comment lines': ({flags: refused}, {flags: refused + ('#' + 'x' * 99 + '\n') * 40}, {}, {}),
            'a pattern matching names in the home folder': ({flags: refused + '*\n'}, {flags: refused + '*\n'}, {},
                                                            {'HOME': str(crowded)}),
            'a ? pattern': ({flags: refused + '?' * 12 + '\n'}, {flags: refused + '?' * 12 + '\n'}, {},
                            {'HOME': str(crowded)}),
            'a [ pattern': ({flags: refused + 'name-' + '[0-9]' * 7 + '\n'},
                            {flags: refused + 'name-' + '[0-9]' * 7 + '\n'}, {}, {'HOME': str(crowded)}),
            'an extended pattern': ({flags: refused + '!(x)\n'}, {flags: refused + '!(x)\n'}, {'BASHOPTS': 'extglob'},
                                    {'BASHOPTS': 'extglob', 'HOME': str(crowded)}),
            'names of several bytes a character': ({flags: refused + '*\n'}, {flags: refused + '*\n'},
                                                   {'LC_ALL': 'C.UTF-8'}, {'LC_ALL': 'C.UTF-8', 'HOME': str(wide)}),
            'spaces a launcher may pass on': ({flags: refused + '?\n'}, {flags: refused + '?' + ' ' * 4000 + '\n'},
                                              {}, {}),
            'a shell start-up file that turns patterns off': ({flags: refused + '*\n'}, {flags: refused + '*\n'},
                                                              {'BASH_ENV': str(no_patterns)},
                                                              {'BASH_ENV': str(no_patterns), 'HOME': str(crowded)}),
            'a shell start-up file that widens patterns': ({flags: refused + '*\n'}, {flags: refused + '*\n'},
                                                           {'BASH_ENV': str(hidden_names)},
                                                           {'BASH_ENV': str(hidden_names), 'HOME': str(dotted)}),
            'a shell function in place of one the count uses': ({flags: refused + '*\n'}, {flags: refused + '*\n'},
                                                                echo_zero, {**echo_zero, 'HOME': str(crowded)}),
            'flags in a relative config folder': ({flags: refused}, {flags: '--disable-features=' + big + '\n'},
                                                  {'XDG_CONFIG_HOME': '../config'}, {'XDG_CONFIG_HOME': '../config'}),
            'Chromium\'s flags in the home folder with an empty config folder variable':
                ({home_chromium_flags: refused}, {home_chromium_flags: '--disable-features=' + big + '\n'},
                 {'FAKE_DEFAULT_BROWSER': 'chromium.desktop', 'XDG_CONFIG_HOME': ''},
                 {'FAKE_DEFAULT_BROWSER': 'chromium.desktop', 'XDG_CONFIG_HOME': ''}),
            'the home folder': ({}, {}, {}, {'HOME': str(long_home)}),
            'a home folder reached through a link': ({}, {}, {}, {'HOME': str(linked_home)}),
            'an activation token': ({}, {}, {'XDG_ACTIVATION_TOKEN': 'x'}, {'XDG_ACTIVATION_TOKEN': big}),
            'a startup id': ({}, {}, {'DESKTOP_STARTUP_ID': 'x'}, {'DESKTOP_STARTUP_ID': big}),
            'launch flags in the environment': ({}, {}, {'EDGE_USER_FLAGS': 'x'}, {'EDGE_USER_FLAGS': big}),
            'the flags list Brave\'s launcher takes from the environment': ({}, {}, {'CONF_LIST': 'x'},
                                                                           {'CONF_LIST': big}),
            'a pattern in launch flags in the environment': ({}, {}, {'EDGE_USER_FLAGS': '*'},
                                                             {'EDGE_USER_FLAGS': '*', 'HOME': str(crowded)}),
            'a browser variable': ({}, {}, {'CHROME_EXTRA': 'x'}, {'CHROME_EXTRA': big}),
        }
        for case, (small_files, large_files, small_environment, large_environment) in cases.items():
            for files, environment, fits in ((small_files, small_environment, True),
                                             (large_files, large_environment, False)):
                with self.subTest(case=case, fits=fits):
                    self.log.write_text('')
                    self.write_state({})
                    for path, content in files.items():
                        path.write_text(content)
                    try:
                        # Invariant: a busy machine may take more than the usual wait to show the window.
                        result = self.run_opener(link, 'reader@work.example', cwd=elsewhere,
                                                 **{'MAGPIE_LINK_WINDOW_WAIT': '10', **environment})
                    finally:
                        for path in files:
                            path.unlink()
                    if fits:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [link])
                    else:
                        self.assert_too_long(result)

    def test_a_flags_file_chrome_would_read_by_a_name_it_splits_opens_nothing(self):
        # Invariant: Chrome's launcher reads its flags file by its name unquoted, so a space or a pattern
        # in the config folder's name leads it to files Magpie cannot know; it is told in its own words.
        refused = '--disable-features=Something\n'
        whole, split, pattern = self.root / 'ab', self.root / 'a b', self.root / 'p?q'
        others = {'a tab': (self.root / 'a\tb', {}), 'a line break': (self.root / 'a\nb', {}),
                  'a * pattern': (self.root / 'p*q', {}), 'a [ pattern': (self.root / 'p[x]q', {}),
                  'an extended pattern': (self.root / '@(pxq)', {'BASHOPTS': 'extglob'})}
        for folder in (whole, split, self.home / 'b', pattern, self.root / 'pxq', *(each for each, _ in others.values())):
            folder.mkdir()
        (whole / 'chrome-flags.conf').write_text(refused)
        (self.home / 'b/chrome-flags.conf').write_text('--disable-features=' + 'x' * 4000 + '\n')
        (self.root / 'pxq/chrome-flags.conf').write_text('--disable-features=' + 'x' * 4000 + '\n')
        result = self.run_opener(LINK, 'reader@work.example', XDG_CONFIG_HOME=str(whole))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])
        for name, (folder, environment) in {'a space': (split, {}), 'a ? pattern': (pattern, {}), **others}.items():
            with self.subTest(name=name):
                self.log.write_text('')
                (folder / 'chrome-flags.conf').write_text(refused)
                result = self.run_opener(LINK, 'reader@work.example', XDG_CONFIG_HOME=str(folder), **environment)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertEqual(self.told(), [['-a', 'Magpie Mail', SPLIT_NAME]])
                self.assertEqual(self.calls('systemd-run'), [])
                self.assertEqual(self.calls('xdg-open'), [])
                self.assertEqual(self.calls('connected'), [])
        # Invariant: the name is only read when the file it names is there, as Chrome's launcher checks.
        self.log.write_text('')
        (split / 'chrome-flags.conf').unlink()
        result = self.run_opener(LINK, 'reader@work.example', XDG_CONFIG_HOME=str(split))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.told(), [SITE])
        # Invariant: only Chrome's launcher reads its flags file by a name it splits.
        make_command(self.bin, 'chromium', FAKE_CHROME)
        (self.root / 'data/applications/chromium.desktop').write_text('[Desktop Entry]\nExec=chromium %U\n')
        self.log.write_text('')
        (split / 'chromium-flags.conf').write_text(refused)
        result = self.run_opener(LINK, 'reader@work.example', XDG_CONFIG_HOME=str(split),
                                 FAKE_DEFAULT_BROWSER='chromium.desktop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.told(), [SITE])

    def test_a_home_folder_nothing_can_run_from_gives_way_to_the_root_folder(self):
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=Something\n')
        self.home.chmod(0o600)
        self.addCleanup(self.home.chmod, 0o700)
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertEqual([call[1] for call in self.calls('handoff')], ['/'])
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])

    def test_relative_paths_are_read_from_the_home_folder_whatever_folder_magpie_runs_from(self):
        # Invariant: the browser's launcher and xdg-open run from the home folder, so the browser Magpie
        # looks up is the one they would find.
        applications = self.home / 'home-data/applications'
        applications.mkdir(parents=True)
        shutil.copy(self.root / 'data/applications/google-chrome.desktop', applications)
        elsewhere = self.root / 'elsewhere'
        (elsewhere / 'home-data').mkdir(parents=True)
        result = self.run_opener(LINK, 'reader@work.example', cwd=elsewhere, XDG_DATA_HOME='home-data')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])
        self.assertEqual(self.calls('xdg-open'), [])

    def test_a_home_folder_named_relative_to_magpies_folder_stays_the_one_the_launcher_runs_from(self):
        # Invariant: Magpie works from the home folder once it has found it, and still names the same one.
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=Something\n')
        result = self.run_opener(LINK, 'reader@work.example', cwd=self.root, HOME='home')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertEqual([call[1] for call in self.calls('handoff')], [str(self.home)])
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])

    def test_a_window_the_launcher_could_not_hand_over_whole_opens_in_a_tab(self):
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=' + 'x' * 14000 + '\n')
        # Invariant: encoding the link into the page's fragment doubles this one.
        link = 'https://example.com/' + 'a/' * 5000
        result = self.run_opener(link, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_started_with_tab(link)
        self.assertEqual(self.windows_opened(), [])
        self.assertEqual(self.calls('overflow'), [])

    def test_one_link_at_a_time(self):
        result = self.run_opener(LINK, 'reader@work.example', 'https://second.example/')
        self.assertEqual(result.returncode, 2)
        self.assertEqual([call for call in self.calls() if call[0] != 'notify-send'], [])

    def test_a_browser_on_another_data_folder_is_watched_where_it_runs(self):
        # Invariant: the launcher's browser takes the data folder its flags or environment name, a
        # relative one in the home folder it runs in. The click that started it ends its turn as soon as
        # it holds that folder, and the mailbox's profile is the one that folder knows.
        flags, chrome_system, chromium_system = (self.root / 'config/chrome-flags.conf', self.etc / 'chrome-flags.conf',
                                                 self.etc / 'chromium-flags.conf')
        make_command(self.bin, 'chromium', FAKE_CHROME)
        (self.root / 'data/applications/chromium.desktop').write_text('[Desktop Entry]\nExec=chromium %U\n')
        ways = {
            'a flag': ({}, {flags: '--user-data-dir=flag-data\n'}, self.home / 'flag-data'),
            'the last of two flags': ({}, {flags: '--user-data-dir=first-data\n--user-data-dir=last-data\n'},
                                      self.home / 'last-data'),
            'the data folder variable': ({'CHROME_USER_DATA_DIR': 'variable-data'}, {}, self.home / 'variable-data'),
            'a flag over the data folder variable': ({'CHROME_USER_DATA_DIR': 'variable-unused'},
                                                     {flags: '--user-data-dir=flag-over-variable\n'},
                                                     self.home / 'flag-over-variable'),
            'the config folder variable': ({'CHROME_CONFIG_HOME': 'config-data'}, {},
                                           self.home / 'config-data/google-chrome'),
            'a relative config folder': ({'XDG_CONFIG_HOME': 'config'},
                                         {self.home / 'config/chrome-flags.conf': '--disable-features=Something\n'},
                                         self.home / 'config/google-chrome'),
            'a system flag Chrome does not read': ({'CHROME_CONFIG_HOME': 'chrome-config'},
                                                   {chrome_system: '--user-data-dir=system-unused\n'},
                                                   self.home / 'chrome-config/google-chrome'),
            'a system flag Chromium reads': ({'FAKE_DEFAULT_BROWSER': 'chromium.desktop'},
                                             {chromium_system: '--user-data-dir=system-data\n'},
                                             self.home / 'system-data'),
            'a user flag over a system one in Chromium': ({'FAKE_DEFAULT_BROWSER': 'chromium.desktop'},
                                                          {chromium_system: '--user-data-dir=system-unused\n',
                                                           self.root / 'config/chromium-flags.conf':
                                                               '--user-data-dir=user-over-system\n'},
                                                          self.home / 'user-over-system'),
            'Chromium\'s flags in the home folder with an empty config folder variable':
                ({'FAKE_DEFAULT_BROWSER': 'chromium.desktop', 'XDG_CONFIG_HOME': ''},
                 {self.home / 'chromium-flags.conf': '--user-data-dir=home-flag-data\n'}, self.home / 'home-flag-data'),
            'Chromium\'s flags in the home folder\'s .config without a config folder variable':
                ({'FAKE_DEFAULT_BROWSER': 'chromium.desktop', 'XDG_CONFIG_HOME': None},
                 {self.home / '.config/chromium-flags.conf': '--user-data-dir=default-config-data\n'},
                 self.home / 'default-config-data'),
        }
        # Invariant: encoding the link into the page's fragment triples this one, so it opens in a tab.
        long_link = 'https://second.example/' + '/' * 11000
        command = [sys.executable, '-I', str(self.script)]
        # Invariant: Magpie may run from any folder; the launcher runs from the home folder.
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        (self.home / '.config').mkdir()
        for way, (variables, files, folder) in ways.items():
            with self.subTest(way=way):
                self.close_browser()
                self.log.write_text('')
                self.write_state({'start_delay': 0.5, 'lock_delay': 0.5})
                (folder / 'Profile 2').mkdir(parents=True)
                (folder / 'Local State').write_text(json.dumps(
                    {'profile': {'info_cache': {'Profile 2': {'user_name': 'reader@work.example'}}}}))
                for path, content in files.items():
                    path.write_text(content)
                environment = self.opener_environment(True, {'MAGPIE_LINK_WINDOW_WAIT': '3', **variables})
                began = time.monotonic()
                openers = []
                for link in (LINK, long_link):
                    openers.append(subprocess.Popen([*command, link, 'reader@work.example'], env=environment,
                                                    cwd=elsewhere, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                    text=True))
                    time.sleep(0.3)
                for opener in openers:
                    _, errors = opener.communicate(timeout=60)
                    self.assertEqual(opener.returncode, 0, errors)
                self.assertLess(time.monotonic() - began, 15, 'the turn ended when the browser held its folder')
                self.settle()
                for path in files:
                    path.unlink()
                self.assertTrue(os.path.lexists(folder / 'SingletonLock'))
                self.assertFalse(os.path.lexists(self.profiles / 'SingletonLock'))
                self.assertEqual(len(self.pids.read_text().split()), 1, 'one browser serves the folder')
                self.assertEqual(len(self.calls('systemd-run')), 2)
                self.assertEqual(self.handoffs(), [])
                self.assertEqual([call[1:] for call in self.calls('handoff')],
                                 [[str(self.home), 'chrome', '--profile-directory=Profile 2', long_link]])
                self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])
                self.assertTrue(self.client()['class'].endswith('-Profile_2'))
                self.assertTrue(self.client()['floating'])

    def test_a_pattern_the_launcher_shell_cannot_count_is_taken_as_too_long(self):
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=Something\n*\n')
        shells = {'failing': 'import sys\nsys.exit(1)\n', 'answering with too many digits': "print('1' + '0' * 5000)\n",
                  'missing': None}
        for shell, body in shells.items():
            with self.subTest(shell=shell):
                self.log.write_text('')
                (self.bin / 'bash').unlink(missing_ok=True)
                if body:
                    make_command(self.bin, 'bash', body)
                self.assert_too_long(self.run_opener(LINK, 'reader@work.example'))

    def test_another_default_browser_gets_the_link_as_before(self):
        result = self.run_opener(LINK, 'reader@work.example', FAKE_DEFAULT_BROWSER='firefox.desktop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('xdg-open'), [['xdg-open', LINK]])
        self.assertEqual(self.handoffs(), [])
        self.assertEqual(self.calls('hyprctl'), [])

    def test_a_desktop_entry_name_cannot_leave_the_applications_folder(self):
        result = self.run_opener(LINK, 'reader@work.example', FAKE_DEFAULT_BROWSER='../applications/google-chrome.desktop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('xdg-open'), [['xdg-open', LINK]])

    def test_without_hyprland_the_app_window_opens_unplaced(self):
        result = self.run_opener(LINK, 'reader@work.example', hyprland=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.calls('hyprctl'), [])
        self.assertEqual(self.told(), [SITE])

    def test_a_closed_browser_is_started_in_a_scope_named_without_the_link(self):
        self.close_browser()
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        started = self.calls('systemd-run')
        self.assertEqual(len(started), 1)
        command = started[0]
        split = command.index('--')
        self.assertEqual(command[split + 1:split + 3], [str(self.bin / 'google-chrome-stable'),
                                                        '--profile-directory=Profile 1'])
        self.assert_page(command[split + 3:])
        self.assertIn('--scope', command[:split])
        self.assertFalse(any('example' in part for part in command[:split]), command)
        self.assertEqual(self.client()['opened_link'], LINK)
        self.assertTrue(self.client()['floating'])

    def test_flags_omarchy_ships_still_use_the_handoff(self):
        (self.root / 'config/chrome-flags.conf').write_text(
            '# Omarchy\n--ozone-platform=wayland\n--ozone-platform-hint=wayland  # here\n'
            '--enable-features=TouchpadOverscrollHistoryNavigation\n--password-store=gnome-libsecret\n'
            '--load-extension=/usr/share/x\n--no-default-browser-check\n')
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.calls('systemd-run'), [])

    def test_a_link_the_handoff_rules_leave_to_the_launcher_starts_it_the_ordinary_way(self):
        wrappers = self.root / 'wrappers'
        wrappers.mkdir()
        make_command(wrappers, 'google-chrome-stable', FAKE_CHROME)
        cases = {
            'a launch flag': ({}, self.root / 'config/chrome-flags.conf'),
            'a system launch flag': ({}, self.etc / 'chrome-flags.conf'),
            'another data folder': ({'CHROME_CONFIG_HOME': str(self.root / 'elsewhere')}, None),
            'a wrapper': ({'PATH': f'{wrappers}:{self.bin}'}, None),
        }
        for case, (environment, flags) in cases.items():
            with self.subTest(case=case):
                self.log.write_text('')
                self.write_state({})
                if flags:
                    flags.write_text('--ozone-platform=wayland\n--disable-features=Something\n')
                result = self.run_opener(LINK, 'reader@work.example', **environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.handoffs(), [])
                self.assertEqual(len(self.calls('systemd-run')), 1)
                # Invariant: the launcher runs from the home folder, as Omarchy runs it.
                self.assertTrue(all(call[1] == str(self.home) for call in self.calls('handoff')), self.calls('handoff'))
                self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])
                self.assertTrue(self.client()['floating'])
                if flags:
                    flags.unlink()

    def test_a_flags_file_that_cannot_be_read_adds_no_flags_so_the_handoff_is_used(self):
        # Invariant: the launcher, like Omarchy's handoff, adds nothing from a file it cannot read.
        for flags in (self.root / 'config/chrome-flags.conf', self.etc / 'chrome-flags.conf'):
            with self.subTest(flags=flags.parent.name):
                self.log.write_text('')
                self.write_state({})
                flags.write_text('--disable-features=Something\n')
                flags.chmod(0)
                try:
                    result = self.run_opener(LINK, 'reader@work.example')
                finally:
                    flags.unlink()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.handoffs()), 1)
                self.assertEqual(self.calls('systemd-run'), [])

    def test_launcher_starts_while_the_browser_is_closed_take_turns(self):
        (self.root / 'config/chrome-flags.conf').write_text('--disable-features=Something\n')
        self.close_browser()
        self.write_state({'start_delay': 0.8, 'lock_delay': 1.0})
        command = [sys.executable, '-I', str(self.script)]
        environment = self.opener_environment(True, {'MAGPIE_LINK_WINDOW_WAIT': '5'})
        links = ['https://first.example/a', 'https://second.example/b', 'https://third.example/c']
        openers = []
        for link in links:
            openers.append(subprocess.Popen([*command, link, 'reader@work.example'], env=environment,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            time.sleep(0.3)
        for opener in openers:
            _, errors = opener.communicate(timeout=60)
            self.assertEqual(opener.returncode, 0, errors)
        self.settle()
        self.assertEqual(len(self.pids.read_text().split()), 1, 'one browser serves the profile')
        self.assertEqual(self.handoffs(), [])
        windows = self.windows_opened()
        self.assertEqual(sorted(window['opened_link'] for window in windows), links)

    def test_a_handoff_answered_late_does_not_open_the_link_twice(self):
        self.write_state({'browser': 'late'})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(len(self.windows_opened()), 1)
        self.assertTrue(self.client()['floating'])

    def test_a_running_browser_that_does_not_answer_is_left_running(self):
        self.write_state({'browser': 'hung'})
        for hyprland in (True, False):
            with self.subTest(hyprland=hyprland):
                self.log.write_text('')
                result = self.run_opener(LINK, 'reader@work.example', hyprland=hyprland, MAGPIE_LINK_WINDOW_WAIT='0.5')
                self.assertEqual(result.returncode, 3)
                self.assertIn(NOT_ANSWERED, result.stderr)
                self.assertEqual(self.calls('connected'), [['connected', 'hung']])
                self.assertEqual(self.calls('systemd-run'), [])
                self.assertEqual(self.calls('google-chrome-stable'), [])
                self.assertEqual(self.calls('xdg-open'), [])
                self.assertEqual(self.told(), [['-a', 'Magpie Mail', NOT_ANSWERED]])

    def test_a_browser_that_is_quitting_is_started_again_for_the_link(self):
        self.write_state({'browser': 'quitting'})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])

    def test_a_browser_that_holds_its_profile_before_it_listens_gets_the_link(self):
        self.close_browser()
        self.start_browser(listen_delay=1.0)
        result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='5')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.client()['opened_link'], LINK)

    def test_a_socket_at_a_long_path_still_gets_the_link(self):
        self.close_browser()
        deep = self.sockets / ('d' * 100) / ('e' * 100)
        deep.mkdir(parents=True, mode=0o700)
        self.start_browser(sockets=deep)
        self.assertGreater(len(os.readlink(self.profiles / 'SingletonSocket')), 108)
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.calls('systemd-run'), [])

    def test_a_lock_from_another_machine_counts_as_a_running_browser(self):
        self.close_browser()
        self.lock_profiles(f'elsewhere.example-{finished_pid()}')
        result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='0.5')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.told(), [['-a', 'Magpie Mail', NO_ANSWER]])

    def test_a_browser_whose_lock_names_another_host_name_still_gets_the_link(self):
        # Invariant: renaming the machine leaves the running browser's lock under the old name.
        lock = self.profiles / 'SingletonLock'
        pid = os.readlink(lock).rpartition('-')[2]
        lock.unlink()
        self.lock_profiles(f'old-name.example-{pid}')
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.client()['opened_link'], LINK)

    def test_a_browser_process_that_does_not_listen_is_asked_again_and_never_replaced(self):
        self.close_browser()
        holder = subprocess.Popen(['chrome', '-c', 'import time\nopen("/proc/self/comm", "w").write("chrome")\n'
                                   'time.sleep(60)'], executable=sys.executable)
        try:
            deadline = time.monotonic() + 10
            while Path(f'/proc/{holder.pid}/comm').read_text().strip() != 'chrome':
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            self.lock_profiles(f'{socket.gethostname()}-{holder.pid}')
            result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='1')
        finally:
            holder.kill()
            holder.wait()
        self.assertEqual(result.returncode, 3)
        self.assertIn(NO_ANSWER, result.stderr)
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.told(), [['-a', 'Magpie Mail', NO_ANSWER]])

    def test_a_lock_naming_a_browser_helper_does_not_stop_it_starting(self):
        self.close_browser()
        # Invariant: Chrome writes a helper's options into its first argument, --type first.
        helper = subprocess.Popen(['chrome --type=renderer --lang=en', '-c',
                                   'import time\nopen("/proc/self/comm", "w").write("chrome")\ntime.sleep(60)'],
                                  executable=sys.executable)
        try:
            deadline = time.monotonic() + 10
            while Path(f'/proc/{helper.pid}/comm').read_text().strip() != 'chrome':
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            self.lock_profiles(f'{socket.gethostname()}-{helper.pid}')
            result = self.run_opener(LINK, 'reader@work.example')
        finally:
            helper.kill()
            helper.wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertTrue(self.client()['floating'])

    def test_a_socket_the_lock_holder_does_not_serve_is_given_nothing(self):
        self.close_browser()
        holder = subprocess.Popen(['chrome', '-c', 'import time\nopen("/proc/self/comm", "w").write("chrome")\n'
                                   'time.sleep(60)'], executable=sys.executable)
        listening = tempfile.mkdtemp(dir=self.sockets)
        folder = os.open(listening, os.O_PATH | os.O_DIRECTORY)
        server = socket.socket(socket.AF_UNIX)
        try:
            server.bind(f'/proc/self/fd/{folder}/SingletonSocket')
            server.listen(16)
            server.settimeout(0.5)
            (self.profiles / 'SingletonSocket').symlink_to(os.path.join(listening, 'SingletonSocket'))
            deadline = time.monotonic() + 10
            while Path(f'/proc/{holder.pid}/comm').read_text().strip() != 'chrome':
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            # Invariant: a lock under another host name names no process here, and this test, which
            # serves the socket, is no browser.
            for host in (socket.gethostname(), 'old-name.example'):
                with self.subTest(host=host):
                    self.lock_profiles(f'{host}-{holder.pid}')
                    self.log.write_text('')
                    result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='1')
                    received = []
                    while True:
                        try:
                            channel, _ = server.accept()
                        except socket.timeout:
                            break
                        with channel:
                            channel.settimeout(1)
                            received.append(channel.recv(65536))
                    (self.profiles / 'SingletonLock').unlink()
                    self.assertTrue(received, 'the opener tried the socket')
                    self.assertEqual(set(received), {b''})
                    self.assertEqual(result.returncode, 3)
                    self.assertEqual(self.told(), [['-a', 'Magpie Mail', NO_ANSWER]])
                    self.assertEqual(self.calls('systemd-run'), [])
        finally:
            server.close()
            os.close(folder)
            holder.kill()
            holder.wait()

    def test_a_lock_left_by_a_closed_browser_does_not_stop_it_starting(self):
        sleeper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            for holder in (str(finished_pid()), '1', '0', str(sleeper.pid), 'x1', '99999999999'):
                with self.subTest(holder=holder):
                    self.close_browser()
                    self.log.write_text('')
                    self.write_state({})
                    self.lock_profiles(f'{socket.gethostname()}-{holder}')
                    result = self.run_opener(LINK, 'reader@work.example')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(self.calls('systemd-run')), 1)
                    self.assertTrue(self.client()['floating'])
        finally:
            sleeper.kill()
            sleeper.wait()

    def test_a_window_that_never_appears_is_reported_and_not_opened_twice(self):
        self.write_state({'no_window': True})
        result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='0.5')
        self.assertEqual(result.returncode, 3)
        self.assertIn(NO_WINDOW, result.stderr)
        self.assertNotIn('example', result.stderr)
        self.assertEqual(len(self.handoffs()), 1)
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.calls('systemd-run'), [])
        self.assertEqual(self.told(), [['-a', 'Magpie Mail', NO_WINDOW]])

    def test_a_start_that_fails_sends_the_link_to_the_default_opener(self):
        self.close_browser()
        for kind in ('window', 'tab'):
            with self.subTest(kind=kind):
                self.log.write_text('')
                self.write_state({'systemd_run_fails': True})
                if kind == 'tab':
                    (self.plugin / 'link-window.html').unlink()
                began = time.monotonic()
                result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='0.5')
                self.assertLess(time.monotonic() - began, 15, 'a start that has ended is not waited for')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls('systemd-run')), 1)
                self.assertEqual(self.calls('xdg-open'), [['xdg-open', LINK]])
                # Invariant: the default opener's launcher hands over the folder it runs in, as Magpie's does.
                self.assertEqual(self.calls('xdg-open-folder'), [['xdg-open-folder', str(self.home)]])
                self.assertEqual(self.told(), [])

    def test_another_window_opening_meanwhile_is_left_alone(self):
        self.write_state({'other_window_first': True})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        other = self.client('0x77aa')
        self.assertFalse(other['floating'])
        self.assertNotIn('props', other)
        self.assertFalse(any('0x77aa' in chunk for chunk in self.evals()))
        self.assertTrue(self.client()['floating'])

    def test_a_link_window_the_browser_restores_is_not_taken_for_the_new_one(self):
        self.close_browser()
        self.write_state({'restores_link_window': True})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        restored = self.client('0x88bb')
        self.assertFalse(restored['floating'])
        self.assertEqual(restored['workspace']['id'], 2)
        self.assertNotIn('props', restored)
        self.assertFalse(any('0x88bb' in chunk for chunk in self.evals()))
        self.assertTrue(self.client()['floating'])

    def test_clicks_while_the_browser_is_closed_start_it_once_and_all_open(self):
        self.close_browser()
        # Invariant: the started browser holds its profile before it listens, and a click whose turn
        # comes in between hands its link over rather than starting another.
        self.write_state({'start_delay': 0.8, 'listen_delay': 1.5})
        command = [sys.executable, '-I', str(self.script)]
        environment = self.opener_environment(True, {'MAGPIE_LINK_WINDOW_WAIT': '5'})
        links = ['https://first.example/a', 'https://second.example/b', 'https://third.example/c']
        openers = []
        for link in links:
            openers.append(subprocess.Popen([*command, link, 'reader@work.example'], env=environment,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            time.sleep(0.3)
        for opener in openers:
            _, errors = opener.communicate(timeout=60)
            self.assertEqual(opener.returncode, 0, errors)
        self.settle()
        self.assertEqual(len(self.calls('systemd-run')), 1)
        windows = self.windows_opened()
        self.assertEqual(sorted(window['opened_link'] for window in windows), links)
        self.assertTrue(all(window['floating'] for window in windows))

    def test_a_start_slower_than_a_click_is_never_joined_by_a_second_one(self):
        self.close_browser()
        self.write_state({'start_delay': 3, 'window_delay': 0.5})
        command = [sys.executable, '-I', str(self.script)]
        environment = self.opener_environment(True, {'MAGPIE_LINK_WINDOW_WAIT': '2'})
        links = ['https://first.example/a', 'https://second.example/b']
        openers = []
        for link in links:
            openers.append(subprocess.Popen([*command, link, 'reader@work.example'], env=environment,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            time.sleep(0.3)
        results = [(opener.communicate(timeout=60)[1], opener.wait()) for opener in openers]
        self.settle()
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertEqual(len(self.pids.read_text().split()), 1)
        self.assertEqual(results[0][1], 0, results[0][0])
        self.assertEqual(results[1][1], 3, results[1][0])
        self.assertIn(NO_ANSWER, results[1][0])
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], links[:1])
        self.assertTrue(self.client()['floating'])

    def test_a_link_with_no_window_of_its_own_waits_for_a_start_in_progress(self):
        self.close_browser()
        self.write_state({'start_delay': 0.8, 'listen_delay': 1.0})
        command = [sys.executable, '-I', str(self.script)]
        environment = self.opener_environment(True, {'MAGPIE_LINK_WINDOW_WAIT': '5'})
        # Invariant: encoding the link into the page's fragment triples this one, so it opens in a tab.
        long_link = 'https://second.example/' + '/' * 11000
        openers = []
        for link in (LINK, long_link):
            openers.append(subprocess.Popen([*command, link, 'reader@work.example'], env=environment,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            time.sleep(0.3)
        for opener in openers:
            _, errors = opener.communicate(timeout=60)
            self.assertEqual(opener.returncode, 0, errors)
        self.settle()
        self.assertEqual(len(self.calls('systemd-run')), 1)
        self.assertEqual(len(self.pids.read_text().split()), 1, 'one browser serves the profile')
        self.assertEqual(self.calls('xdg-open'), [])
        self.assertEqual(self.handoffs(), [['handoff', '/', 'browser', '--profile-directory=Profile 1', long_link]])
        self.assertEqual([window['opened_link'] for window in self.windows_opened()], [LINK])

    def test_a_link_window_already_open_is_left_where_it_is(self):
        earlier = {'address': '0x3', 'class': 'chrome-__plugin_scripts_link-window.html-Default', 'floating': True,
                   'size': [700, 500], 'workspace': {'id': 2, 'name': '2'}}
        self.change_state(lambda state: state['clients'].append(earlier))
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client('0x3'), earlier)
        self.assertFalse(any('address:0x3' in chunk for chunk in self.evals()))
        self.assertFalse(any('address:0x3' in part for call in self.calls('hyprctl') for part in call))
        self.assertTrue(self.client()['floating'])

    def test_a_window_sent_to_another_desk_comes_back_to_the_clicked_one(self):
        self.write_state({'opens_on': 3})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['workspace']['id'], 4)
        self.assertTrue(self.evals()[0].startswith(
            f'hl.dispatch(hl.dsp.window.move({{ workspace = "4", follow = false, window = "address:{APP_ADDRESS}" }}))'))

    def test_the_view_is_not_pulled_back_after_moving_to_another_desk(self):
        self.change_state(lambda state: state['answers'].update({'activeworkspace': {'id': 2, 'monitorID': 0}}))
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('hl.dsp.focus' in chunk for chunk in self.evals()))
        self.assertEqual(self.client()['workspace']['id'], 4)

    def test_a_browser_that_resizes_its_new_window_is_placed_again(self):
        self.write_state({'self_resizes': 2})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['size'], [1280, 922])
        self.assertGreaterEqual(len(self.evals()), 3)

    def test_a_window_that_will_not_stay_placed_is_reported(self):
        self.write_state({'self_resizes': 99})
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls('xdg-open'), [])

    def test_only_a_well_formed_window_address_is_used(self):
        self.write_state({'next_address': '0x9" }); os.exit() --'})
        result = self.run_opener(LINK, 'reader@work.example', MAGPIE_LINK_WINDOW_WAIT='0.5')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.evals(), [])
        for call in self.calls('hyprctl'):
            self.assertFalse(any('os.exit' in part for part in call), call)

    def test_an_unreadable_hyprland_still_opens_the_link_once(self):
        for answer in ('not json', '[' * 60000,
                       '[{"id": 0, "width": 5120, "height": 2880, "scale": NaN, "focused": true}]',
                       '[{"id": 0, "width": 5120, "height": 2880, "scale": Infinity, "focused": true}]',
                       '[{"id": 0, "width": 1' + '0' * 400 + ', "height": 2880, "scale": 2, "focused": true}]'):
            with self.subTest(answer=answer[:60]):
                self.log.write_text('')
                self.write_state({})
                self.change_state(lambda state: state['answers'].update({'monitors': answer}))
                result = self.run_opener(LINK, 'reader@work.example')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.handoffs()), 1)
                self.assertEqual(self.evals(), [])
                self.assertEqual(self.calls('xdg-open'), [])

    def test_a_small_screen_gets_a_usable_window(self):
        self.change_state(lambda state: state.update({'monitors': [
            {'id': 0, 'width': 3024, 'height': 1964, 'scale': 2, 'transform': 0, 'focused': True}]}))
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client()['size'], [1024, 720])

    def test_a_scratchpad_desk_is_never_a_destination(self):
        self.change_state(lambda state: state['answers']['activewindow'].update(
            {'workspace': {'id': -98, 'name': 'special:scratch'}}))
        result = self.run_opener(LINK, 'reader@work.example')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('window.move' in chunk for chunk in self.evals()))


class LinkPage(unittest.TestCase):
    def test_the_page_only_forwards_whole_web_links_from_its_fragment(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('requires node')
        page = (ROOT / 'scripts/link-window.html').read_text()
        script = re.search(r'<script>(.*?)</script>', page, re.S).group(1)
        harness = textwrap.dedent('''
            const vm = require('vm')
            const cases = JSON.parse(process.argv[2])
            const results = cases.map(hash => {
              const replaced = []
              const location = { hash, replace: target => replaced.push(target) }
              vm.runInNewContext(process.argv[1], { location, decodeURIComponent })
              return replaced
            })
            console.log(JSON.stringify(results))
        ''')
        whole = fragment(LINK)
        # Invariant: a link cut short on its way keeps its length but loses its end.
        cut = 'https://' + 'a' * 40 + '@192.168.1.1.example.com/'
        cases = [whole, whole[:-1], whole + 'x', '#' + urllib.parse.quote(LINK, safe=''), '', '#0:',
                 fragment('javascript:alert(1)'), fragment('https://\\evil.example/'), fragment('file:///etc/passwd'),
                 '#9:%E0%A4%A', fragment(cut)[:fragment(cut).index('192.168.1.1') + len('192.168.1.1')]]
        result = subprocess.run([node, '-e', harness, script, json.dumps(cases)], capture_output=True, text=True,
                                timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [[LINK]] + [[]] * (len(cases) - 1))


if __name__ == '__main__':
    unittest.main(verbosity=1)
