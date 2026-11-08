#!/usr/bin/env python3
"""Open a message's web link in a browser app window floating over the desk Magpie is on.

Usage: open-link-window.py <http(s) link> [mailbox address]

The window has no tabs or address bar (Chromium's --app). It uses the browser profile signed in
as the mailbox, so the sites the mailbox's owner is signed in to stay signed in. On Hyprland it
floats, centred and solid, on the desk that had focus when the link was clicked. Without a
Chromium-based default browser the link goes to xdg-open as before.

Each click opens its own copy of link-window.html, in a folder of its own, so this opener knows its
window by that folder's name and never takes another link window for it. A running browser gets the
link over its own socket, and a browser is started only when none holds the profile. When Omarchy's
handoff rules leave the link to the browser's launcher, the browser is started as any app starts it.
A link that cannot have a window of its own opens in a tab, handed over or started the same way. No
link goes anywhere that a running browser would read only part of.
"""
import fcntl
import functools
import json
import math
import os
import re
import secrets
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import NamedTuple

# Invariant: the browser reads at most 32 KiB of a handoff, so the whole message stays inside it.
MAX_HANDOFF_BYTES = 32000
# Invariant: room in a launcher's handoff for its program's name, what a wrapper adds of its own and
# the activation token the browser adds as a flag.
LAUNCHER_MARGIN = 4096
MAX_LOCAL_STATE_BYTES = 32 * 1024 * 1024
MAX_DESKTOP_ENTRY_BYTES = 65536
MAX_FLAGS_BYTES = 65536
MAX_COMMAND_BYTES = 65536
WIDTH_SHARE = 0.5
HEIGHT_SHARE = 0.64
SMALL_SCREEN_SHARE = 0.92
MIN_WIDTH = 1024
MIN_HEIGHT = 720
SIZE_TOLERANCE = 2
MAX_PAGE_BYTES = 65536
STALE_PAGE_SECONDS = 600
SITE_NOTICE_MILLISECONDS = 5000
REPLY_SECONDS = 5
RETRY_SECONDS = 0.25
# Invariant: longer than a browser that is already running waits for a second one's handoff to be
# answered (20 seconds), so a start in progress is never taken for no browser at all.
START_SECONDS = 30
# Invariant: where the browsers themselves are installed and where their system-wide flags live;
# a launcher anywhere else may add flags or pick a profile that only running it honours.
SYSTEM_BIN = '/usr/bin'
SYSTEM_CONFIG = '/etc'
# Invariant: the shell the browsers' own launchers run in. Chrome's and Edge's read their flags file
# and flags variable unquoted, so it splits them into words and expands each pattern into the names
# it matches. Chrome's runs it as bash, which first reads the file BASH_ENV names; Edge's runs it as
# sh, which does not.
LAUNCHER_SHELL = '/bin/bash'
SHELL_STARTUP = ('BASH_ENV', 'ENV')
EXPORTED_FUNCTION = 'BASH_FUNC_'
PATTERN = re.compile(rb'[*?[(]')
# Invariant: what that shell splits a name it reads unquoted at, or expands it by.
SPLIT_OR_PATTERN = re.compile(rb'[ \t\n*?[(]')
EXPANDED_SIZE = 'set -- $1; LC_ALL=C; size=0; for word; do size=$((size + ${#word} + 1)); done; echo "$size"'
# Invariant: the variables a launcher takes flags from without FLAG or CHROME in their names (Brave's
# CONF_LIST), and those the browser hands over as a flag.
FLAG_VARIABLES = ('CONF_LIST', 'XDG_ACTIVATION_TOKEN', 'DESKTOP_STARTUP_ID')
USER_DATA_FLAG = '--user-data-dir='
LINK_PAGE = Path(__file__).resolve().with_name('link-window.html')
# Invariant: the browser names an app window `<browser>-<host>_<path>-<profile>` after the page
# it opened, and every link window opens a copy of LINK_PAGE named like it, so this is in the class
# of each of them and of nothing else.
LINK_WINDOW_MARK = '_' + LINK_PAGE.name + '-'
PAGE_FOLDER = re.compile(r'[0-9a-f]{16}')
WEB_LINK = re.compile(r'(https?)://([^/\\?#]*)', re.IGNORECASE | re.ASCII)
# Invariant: the white space the reader trims from a link (JavaScript's), so both read the same link.
TRIMMED = '\t\n\v\f\r \xa0\u1680' + ''.join(map(chr, range(0x2000, 0x200b))) + '\u2028\u2029\u202f\u205f\u3000\ufeff'
# Invariant: the same public-host rule as the reader's link check (isPublicHost in Html.js).
DOTTED_QUAD = re.compile(r'([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})')
HOST_NAME = re.compile(r'[a-z0-9.-]+')
PRIVATE_SUFFIX = re.compile(r'(^|\.)(localhost|home\.arpa)\Z|\.(local|localdomain|internal|intranet|lan|home|corp|test)\Z')
PUBLIC_TLD = re.compile(r'\.(xn--[a-z0-9-]+|[a-z]{2,})\Z')
# Invariant: the flags Omarchy's handoff accepts in a flags file. The running browser already has
# them; any other flag may be meant for each launch, which only the launcher honours.
HANDOFF_FLAG = re.compile(
    r'--(ozone-platform|ozone-platform-hint|password-store|enable-features|load-extension)=\S*|--no-default-browser-check')
LOCK_HOLDER = re.compile(r'[0-9]{1,10}')
ELSEWHERE = -1
PORT = re.compile(r'[0-9]{0,5}')
# Invariant: solid whether focused, unfocused or full screen, whatever the desktop's own opacity is.
SOLID = ('opacity', 'opacity_inactive', 'opacity_fullscreen')
PROFILE_DIRECTORY = re.compile(r'Default|Profile [0-9]{1,4}')
WINDOW_ADDRESS = re.compile(r'0x[0-9a-f]{1,16}')
DESKTOP_ENTRY = re.compile(r'[A-Za-z0-9._-]{1,200}\.desktop')
MAILBOX = re.compile(r'[^@\s]{1,64}@[^@\s]{1,255}')
NOT_PUBLIC = 'Magpie Mail did not open the link, because it is not a public web address.'
NO_ANSWER = 'The browser did not answer, so the link did not open.'
NOT_ANSWERED = 'The browser has not answered, so the link may not open.'
NO_WINDOW = 'The link window is slow to open, so it may still appear.'
TOO_LONG = 'Magpie Mail did not open the link, because it is too long for the browser.'
SPLIT_NAME = ("Magpie Mail did not open the link, because the config folder Chrome reads its flags from has a space "
              "or one of * ? [ ( in its name.")
NO_BROWSER = 'Magpie Mail could not open the link. Check that a browser is installed.'


class Browser(NamedTuple):
    path: str
    name: str
    profiles: str
    flags: str
    processes: tuple
    launcher: str


# Invariant: only browsers whose --app window has no tabs or address bar, keyed by the executable
# their desktop entry runs: the folder under ~/.config that holds their profiles, the flags file
# their launcher reads, the names their running browser process goes by, and whose launcher it is.
# What each launcher adds to the browser's command line besides the link:
# - Chrome's (bash): chrome-flags.conf without the lines that start with '#', read by its name
#   unquoted, else CHROME_USER_FLAGS; either split into words and each pattern expanded.
# - Edge's (sh): the whole of its flags file, else EDGE_USER_FLAGS; either split and expanded.
# - Brave's (bash): FLAG_LIST, then brave-flags.conf a line a flag, else CONF_LIST.
# - Chromium's (built): /etc/chromium-flags.conf, then the user's, each line split as a shell
#   splits it but not expanded. It takes an empty XDG_CONFIG_HOME as set, and so reads the folder it
#   runs in; the others take an empty one as unset.
# Each reads the user's flags file from XDG_CONFIG_HOME, else from HOME's .config. The browser then
# adds XDG_ACTIVATION_TOKEN or DESKTOP_STARTUP_ID as a flag.
BROWSERS = {
    'google-chrome-stable': ('google-chrome', 'chrome-flags.conf', ('chrome',), 'chrome'),
    'chromium': ('chromium', 'chromium-flags.conf', ('chromium', 'chrome'), 'chromium'),
    'brave': ('BraveSoftware/Brave-Browser', 'brave-flags.conf', ('brave',), 'brave'),
    'microsoft-edge-stable': ('microsoft-edge', 'microsoft-edge-stable-flags.conf', ('msedge',), 'edge'),
}


class Unplaced(Exception):
    pass


def public_ipv4(host):
    parts = DOTTED_QUAD.fullmatch(host)
    if not parts:
        return False
    # Invariant: leading-zero parts read as octal to some resolvers and as decimal to others.
    if any(len(part) > 1 and part[0] == '0' for part in parts.groups()):
        return False
    octets = [int(part) for part in parts.groups()]
    if any(octet > 255 for octet in octets):
        return False
    first, second = octets[0], octets[1]
    return not (first in (0, 10, 127) or first >= 224 or (first == 169 and second == 254)
                or (first == 172 and 16 <= second <= 31) or (first == 192 and second in (0, 168))
                or (first == 198 and second in (18, 19)) or (first == 100 and 64 <= second <= 127))


def public_host(host):
    if not host or len(host) > 253:
        return False
    if public_ipv4(host):
        return True
    if not HOST_NAME.fullmatch(host) or '..' in host or PRIVATE_SUFFIX.search(host):
        return False
    return PUBLIC_TLD.search(host) is not None


def host_of(authority):
    """The host a browser opens for this authority: after the last @, without the port."""
    host = authority.rpartition('@')[2]
    # Invariant: a bracketed IPv6 address is never a public name here.
    if host.startswith('['):
        return ''
    name, _, port = host.partition(':')
    # Invariant: the browser opens nothing for a port that is not a number up to 65535.
    if not PORT.fullmatch(port) or (port and int(port) > 65535):
        return ''
    return name.lower()


def web_link(value):
    text = re.sub(r'[\t\n\r]', '', value.strip(TRIMMED))
    if any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise ValueError('This is not a web link.')
    # Invariant: the host checked is the one the browser opens, whose http(s) authority ends at the
    # first slash, backslash, question mark or hash, and which decodes no character references.
    start = WEB_LINK.match(text)
    host = host_of(start.group(2)) if start else ''
    if not public_host(host):
        raise ValueError('This is not a link to a public web address.')
    return text, host


def mailbox(value):
    text = value.strip()
    return text.lower() if len(text) <= 320 and MAILBOX.fullmatch(text) else ''


def output(command):
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ''
    return result.stdout.strip() if result.returncode == 0 else ''


def default_browser_entry():
    entry = output(['omarchy-cmd-default-browser']) if shutil.which('omarchy-cmd-default-browser') else ''
    return entry or output(['xdg-settings', 'get', 'default-web-browser'])


def desktop_command(entry):
    if not DESKTOP_ENTRY.fullmatch(entry):
        return ''
    home = Path.home()
    folders = [os.environ.get('XDG_DATA_HOME') or str(home / '.local/share'), str(home / '.nix-profile/share')]
    folders += (os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share').split(':')
    for folder in folders:
        if not folder:
            continue
        try:
            with open(Path(folder, 'applications', entry), 'rb') as stream:
                text = stream.read(MAX_DESKTOP_ENTRY_BYTES).decode(errors='replace')
        except OSError:
            continue
        for line in text.splitlines():
            if line.startswith('Exec='):
                return line[5:].split(' ', 1)[0]
        return ''
    return ''


def chromium_browser():
    command = desktop_command(default_browser_entry())
    name = os.path.basename(command)
    if name not in BROWSERS:
        return None
    path = shutil.which(command)
    return Browser(path, name, *BROWSERS[name]) if path else None


def configured_home():
    """The config folder as the launchers' shells name it: XDG_CONFIG_HOME, unset or empty HOME's .config."""
    return os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.path.expanduser('~'), '.config')


def config_home():
    """The folder the browser takes its default data folder from, and the shell launchers their flags file."""
    # Invariant: a relative one is read from the folder the launcher runs in, not from Magpie's.
    return os.path.join(launcher_home(), configured_home())


@functools.cache
def launcher_home():
    """The folder the browser's launcher runs in: the home folder, as Omarchy runs it."""
    # Invariant: as the browser itself names it, with no link left in the way, and the same each time it
    # is asked, since Magpie then works from it and a relative home would name another folder. A home
    # folder nothing can run from gives way to the root folder.
    home = os.path.realpath(os.path.expanduser('~'))
    return home if os.path.isdir(home) and os.access(home, os.X_OK) else '/'


def flags_folders(browser):
    """The folders the browser's launcher reads its flags files from, in the order it reads them."""
    if browser.launcher != 'chromium':
        return (config_home(),)
    return (SYSTEM_CONFIG, launcher_home() if os.environ.get('XDG_CONFIG_HOME') == '' else config_home())


def counted_flags_files(browser):
    """Every flags file a launcher of the browser's may read; the count and the handoff rules read them all."""
    folders = dict.fromkeys((SYSTEM_CONFIG, config_home(), *flags_folders(browser)))
    return [os.path.join(folder, browser.flags) for folder in folders]


def flags_name_split(browser):
    """Whether the browser's launcher reads its flags file by a name its shell splits or expands."""
    # Invariant: Chrome's checks the file by its whole name but reads it by the name unquoted, so a config
    # folder with a space or a pattern in its name has it read files no count can know.
    name = os.path.join(configured_home(), browser.flags)
    return (browser.launcher == 'chrome' and os.path.isfile(os.path.join(launcher_home(), name))
            and bool(SPLIT_OR_PATTERN.search(os.fsencode(name))))


def data_folder(browser):
    """The folder whose profiles and lock the browser the launcher starts uses."""
    # Invariant: the browser takes the last --user-data-dir among its flags, then CHROME_USER_DATA_DIR,
    # then CHROME_CONFIG_HOME, and reads a relative one from the folder it runs in. The flags files are
    # split as Chrome's launcher splits them; a folder a launcher takes another way (from a flags
    # variable, a whole line or quotes) is missed, which costs a wait of up to START_SECONDS and never
    # a second browser.
    chosen = ''
    for folder in flags_folders(browser):
        for flag in launch_flags(os.path.join(folder, browser.flags)) or []:
            if flag.startswith(USER_DATA_FLAG):
                chosen = flag[len(USER_DATA_FLAG):]
    chosen = chosen or os.environ.get('CHROME_USER_DATA_DIR', '')
    if chosen:
        return Path(launcher_home(), chosen)
    configured = os.environ.get('CHROME_CONFIG_HOME', '')
    if configured:
        return Path(launcher_home(), configured, browser.profiles)
    return Path(config_home(), browser.profiles)


def profile_for(root, address):
    if not address:
        return ''
    try:
        with open(root / 'Local State', 'rb') as stream:
            raw = stream.read(MAX_LOCAL_STATE_BYTES + 1)
        if len(raw) > MAX_LOCAL_STATE_BYTES:
            return ''
        profiles = json.loads(raw).get('profile', {}).get('info_cache', {})
    except (OSError, ValueError, AttributeError, RecursionError):
        return ''
    if not isinstance(profiles, dict):
        return ''
    for folder in sorted(profiles):
        info = profiles[folder]
        if not PROFILE_DIRECTORY.fullmatch(folder) or not isinstance(info, dict):
            continue
        signed_in = info.get('user_name')
        # Invariant: a profile folder that does not exist would make Chromium create an empty one.
        if isinstance(signed_in, str) and signed_in.strip().lower() == address and (root / folder).is_dir():
            return folder
    return ''


def open_folder(name, folder=None):
    """A folder of this user's, opened where it is and never through a link."""
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=folder)


def pages_folder():
    """The path of the private folder that holds page copies, and that folder, opened."""
    runtime = os.environ.get('XDG_RUNTIME_DIR', '')
    if os.path.isabs(runtime):
        path = os.path.join(runtime, 'magpie-links')
    else:
        path = os.path.join(tempfile.gettempdir(), f'magpie-links-{os.getuid()}')
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    folder = open_folder(path)
    info = os.fstat(folder)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(folder)
        raise OSError('The link page folder is not private.')
    return path, folder


def sweep(pages):
    # Invariant: only this opener's own page folders, untouched for ten minutes, are removed, each
    # reached through the folder already opened, so nothing is followed out of it. A page holds no link.
    now = time.time()
    try:
        names = os.listdir(pages)
    except OSError:
        return
    for name in names:
        if not PAGE_FOLDER.fullmatch(name):
            continue
        try:
            entry = open_folder(name, pages)
        except OSError:
            continue
        try:
            info = os.fstat(entry)
            if info.st_uid != os.getuid() or now - info.st_mtime < STALE_PAGE_SECONDS:
                continue
            try:
                if stat.S_ISREG(os.stat(LINK_PAGE.name, dir_fd=entry, follow_symlinks=False).st_mode):
                    os.unlink(LINK_PAGE.name, dir_fd=entry)
            except FileNotFoundError:
                pass
            os.rmdir(name, dir_fd=pages)
        except OSError:
            continue
        finally:
            os.close(entry)


def launch_page(path, pages):
    """A copy of the page for this click alone, and the mark in the class of the window it opens."""
    try:
        with open(LINK_PAGE, 'rb') as stream:
            content = stream.read(MAX_PAGE_BYTES + 1)
        if len(content) > MAX_PAGE_BYTES:
            return None
        name = secrets.token_hex(8)
        os.mkdir(name, 0o700, dir_fd=pages)
        folder = open_folder(name, pages)
        try:
            descriptor = os.open(LINK_PAGE.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=folder)
        finally:
            os.close(folder)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
    except OSError:
        return None
    return Path(path, name, LINK_PAGE.name), '_' + name + LINK_WINDOW_MARK


def browser_arguments(profile, page, link):
    # Invariant: the link rides in the page's fragment, inside the value of --app, so it can never
    # be read as an option, and the window's name comes from the page. Its length goes first, so the
    # page forwards only a link that reached it whole.
    encoded = urllib.parse.quote(link, safe='')
    target = page.as_uri() + f'#{len(encoded)}:{encoded}'
    return ([f'--profile-directory={profile}'] if profile else []) + [f'--app={target}']


def handoff_message(arguments):
    # Invariant: the page is an absolute path, so the browser needs no working folder of ours.
    return b'\0'.join(part.encode() for part in ('START', '/', 'browser', *arguments))


def start_detached(command):
    subprocess.Popen(command, cwd=launcher_home(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def launch_flags(path):
    """The flags in a launcher's flags file, None when it is too long to check."""
    # Invariant: the launcher adds no flags from a file it cannot read, and neither does Omarchy's handoff.
    try:
        with open(path, 'rb') as stream:
            raw = stream.read(MAX_FLAGS_BYTES + 1)
    except OSError:
        return []
    if len(raw) > MAX_FLAGS_BYTES:
        return None
    return [flag for line in raw.decode(errors='replace').split('\n') for flag in line.split('#', 1)[0].split()]


def expanded_size(flags, home):
    """At most how much flags a launcher reads add to its handoff, more than it can hold if unknown."""
    # Invariant: a launcher may pass every line, comments too, or its shell may split them into words
    # and expand each pattern into every name it matches. The same shell, environment and folder as
    # the launcher's count what it makes of them, once with the start-up file and functions bash takes
    # from the environment and once without, and the larger counts.
    size = len(flags) + flags.count(b'\n') + 1
    if size > MAX_HANDOFF_BYTES or not PATTERN.search(flags):
        return size
    plain = {name: value for name, value in os.environ.items()
             if name not in SHELL_STARTUP and not name.startswith(EXPORTED_FUNCTION)}
    return max(size, shell_size(flags, home, None), shell_size(flags, home, plain))


def shell_size(flags, home, environment):
    """What the launchers' shell makes of flags, in this environment, more than it can hold if unknown."""
    try:
        result = subprocess.run([LAUNCHER_SHELL, '-c', EXPANDED_SIZE, 'flags', flags.replace(b'\0', b'')],
                                cwd=home, env=environment, stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=5)
    except (OSError, subprocess.SubprocessError):
        return MAX_HANDOFF_BYTES + 1
    last = result.stdout.split()[-1:]
    # Invariant: an answer with more digits than the bound is over it, and is never parsed.
    if result.returncode != 0 or not last or not last[0].isdigit() or len(last[0]) > len(str(MAX_HANDOFF_BYTES)):
        return MAX_HANDOFF_BYTES + 1
    return int(last[0])


def flags_size(path, home):
    """At most how much a launcher's flags file adds to its handoff."""
    try:
        with open(path, 'rb') as stream:
            flags = stream.read(MAX_HANDOFF_BYTES + 1)
    except OSError:
        return 0
    return expanded_size(flags, home)


def handoff_fits(browser, arguments):
    """Whether a running browser reads the whole of what Magpie, or the browser's launcher, hands it."""
    # Invariant: the launcher hands over its folder, its program's name, the flags its flags files and
    # the environment add, and the arguments; Magpie's own handoff is shorter. A running browser reads
    # 32 KiB of it and opens what it read, cut short, or the launcher takes the cut for no answer and
    # kills it. The bound holds whether or not a browser runs, because one may start meanwhile. It
    # counts every input of the launchers' listed at BROWSERS, each in the way that adds most: what a
    # launcher reads as data is counted. What it cannot count is code of the user's own that runs in the
    # launcher's chain, such as a wrapper of their own, a program earlier in PATH than the one a launcher
    # runs (bash, sh, grep or cat), an exported shell function of that name, a BASH_ENV start-up file
    # (which may both change how patterns expand and replace the commands the count runs), a trace
    # prompt the shell runs, or a library preloaded into the launcher.
    if flags_name_split(browser):
        return False
    home = launcher_home()
    size = len(b'START') + 1 + LAUNCHER_MARGIN + len(os.fsencode(home)) + 1
    for path in counted_flags_files(browser):
        size += flags_size(path, home)
    size += sum(expanded_size(os.fsencode(value), home) for name, value in os.environ.items()
                if 'FLAG' in name or name.startswith('CHROME') or name in FLAG_VARIABLES)
    size += sum(len(argument.encode()) + 1 for argument in arguments)
    return size <= MAX_HANDOFF_BYTES


def handoff_allowed(browser):
    # Invariant: the rules of Omarchy's own handoff. A wrapper in the browser's place, a flag meant
    # for each launch, or another data folder is honoured only by running the browser's launcher.
    if os.environ.get('CHROME_USER_DATA_DIR') or os.environ.get('CHROME_CONFIG_HOME'):
        return False
    if browser.path != os.path.join(SYSTEM_BIN, browser.name):
        return False
    for path in counted_flags_files(browser):
        flags = launch_flags(path)
        if flags is None or not all(HANDOFF_FLAG.fullmatch(flag) for flag in flags):
            return False
    return True


def hand_over(root, arguments, processes, deadline):
    """'ack' or 'sent' once the running browser has read the link, or 'absent' when nothing took it."""
    message = handoff_message(arguments)
    # Invariant: the browser locks its profile before it listens, so only the process the lock names
    # gets the link.
    holder = lock_holder(root)
    if holder == 0:
        return 'absent'
    link = os.path.join(root, 'SingletonSocket')
    try:
        target = os.path.join(root, os.readlink(link))
    except OSError:
        target = link
    folder, name = os.path.split(target)
    try:
        descriptor = os.open(folder, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError:
        return 'absent'
    try:
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        # Invariant: the socket's folder can be recreated by anyone once a crashed browser's is
        # cleared away, so only a socket of this user's, served by the browser holding the profile,
        # gets the link.
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            return 'absent'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC) as channel:
            channel.settimeout(max(0.1, min(REPLY_SECONDS, deadline - time.monotonic())))
            try:
                # Invariant: through the folder's descriptor, a socket at a path of any length connects.
                channel.connect(f'/proc/self/fd/{descriptor}/{name}')
                credentials = channel.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i'))
                server, owner, _ = struct.unpack('3i', credentials)
                # Invariant: a lock written under another host name, as after the machine is renamed,
                # names no process here, so the browser serving the socket must prove itself one.
                if holder == ELSEWHERE and server > 1 and browser_process(server, processes):
                    holder = server
                if server <= 1 or server != holder or owner != os.getuid():
                    return 'absent'
                channel.sendall(message)
                channel.shutdown(socket.SHUT_WR)
            except OSError:
                return 'absent'
            reply = b''
            try:
                while len(reply) < 16 and reply != b'ACK':
                    chunk = channel.recv(16 - len(reply))
                    if not chunk:
                        break
                    reply += chunk
            except OSError:
                pass
    except OSError:
        return 'absent'
    finally:
        os.close(descriptor)
    # Invariant: a browser that is quitting says so and handles nothing more.
    if reply.startswith(b'SHUTDOWN'):
        return 'absent'
    return 'ack' if reply == b'ACK' else 'sent'


def lock_holder(root):
    """The process the profile's lock names: ELSEWHERE for another machine's, 0 for none."""
    try:
        holder = os.readlink(os.path.join(root, 'SingletonLock'))
    except OSError:
        return 0
    host, _, pid = holder.rpartition('-')
    if host != socket.gethostname():
        return ELSEWHERE
    return int(pid) if LOCK_HOLDER.fullmatch(pid) and int(pid) > 1 else 0


def browser_process(pid, processes):
    # Invariant: after a crash or a restart the lock can name any process, even a helper of some
    # browser's; only a browser process of this user's, whose first option is not its --type, holds it.
    try:
        if os.stat(f'/proc/{pid}').st_uid != os.getuid():
            return False
        with open(f'/proc/{pid}/comm', 'rb') as stream:
            name = stream.read(64).strip().decode(errors='replace')
        with open(f'/proc/{pid}/cmdline', 'rb') as stream:
            command = re.split(rb'[\0 ]', stream.read(MAX_COMMAND_BYTES), maxsplit=2)
    except OSError:
        return False
    return name in processes and not (len(command) > 1 and command[1].startswith(b'--type='))


def browser_running(root, processes):
    # Invariant: a browser started beside a running one that is slow to answer waits 20 seconds and
    # then kills it, windows and all, so a profile lock held by a running browser of this user's
    # means the link waits for that browser.
    holder = lock_holder(root)
    # Invariant: a browser started on a profile another machine holds only asks to take it over.
    return holder == ELSEWHERE or (holder > 0 and browser_process(holder, processes))


def start(browser, arguments):
    """The browser's launcher, started; None when it could not be."""
    # Invariant: a browser started here outlives Magpie in a scope of its own, named without the link.
    command = [browser.path, *arguments]
    if shutil.which('systemd-run'):
        command = ['systemd-run', '--user', '--scope', '--quiet', '--collect', '--slice=app-graphical.slice',
                   f'--unit=magpie-link-{secrets.token_hex(4)}', f'--description={browser.name}', '--', *command]
    try:
        return subprocess.Popen(command, cwd=launcher_home(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return None


def take_turn(pages, deadline):
    """Lock the private pages folder, which each click opens for itself; False if the time ran out."""
    # Invariant: a click without its private folder has nothing to take turns on, and goes ahead.
    if pages is None:
        return True
    while True:
        try:
            fcntl.flock(pages, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)


def start_once(browser, root, arguments, pages, deadline, allowed):
    """Start the browser unless another click's start got there first; 'absent' means ask it."""
    # Invariant: clicks while the browser is closed take turns, so only one of them starts it and the
    # rest hand their links to it.
    if not take_turn(pages, deadline):
        return 'silent'
    try:
        if allowed:
            handed = hand_over(root, arguments, browser.processes, deadline)
            if handed != 'absent' or browser_running(root, browser.processes):
                return handed
        started = start(browser, arguments)
        if started is None:
            return 'failed'
        # Invariant: a turn lasts until the started browser holds its profile or its start ends,
        # however soon this click stops waiting, so no later click starts another beside it.
        cap = time.monotonic() + START_SECONDS
        while started.poll() is None and not browser_running(root, browser.processes):
            if time.monotonic() >= cap:
                break
            time.sleep(0.05)
        if started.poll() not in (None, 0) and not browser_running(root, browser.processes):
            return 'failed'
        return 'started' if allowed else 'launched'
    finally:
        if pages is not None:
            fcntl.flock(pages, fcntl.LOCK_UN)


def ask(browser, root, arguments, deadline):
    """'ack' or 'sent' once the running browser has read the link, 'absent' when none holds the
    profile, or 'silent' when the one that does never took it."""
    while True:
        handed = hand_over(root, arguments, browser.processes, deadline)
        if handed != 'absent' or not browser_running(root, browser.processes):
            return handed
        # Invariant: a browser that holds its profile but does not take the link yet is starting or
        # busy; it is asked again, never replaced.
        if time.monotonic() >= deadline:
            return 'silent'
        time.sleep(RETRY_SECONDS)


def deliver(browser, root, arguments, pages, deadline):
    """How the link went: 'ack', 'sent', 'started' or 'launched', 'silent' when nothing took it,
    'long' when the browser would read only part of it, or 'failed' when it could not be started."""
    if not handoff_fits(browser, arguments):
        return 'long'
    allowed = handoff_allowed(browser)
    while True:
        if allowed:
            handed = ask(browser, root, arguments, deadline)
        elif browser_running(root, browser.processes):
            # Invariant: what the handoff rules leave to the launcher only the launcher honours, and it
            # hands the link to the running browser itself, as any app's launch does.
            return 'launched' if start(browser, arguments) is not None else 'failed'
        else:
            handed = 'absent'
        if handed == 'absent':
            handed = start_once(browser, root, arguments, pages, deadline, allowed)
        if handed != 'absent':
            return handed


def on_hyprland():
    return bool(os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')) and bool(shutil.which('hyprctl'))


def hyprctl(*arguments):
    try:
        result = subprocess.run(['hyprctl', *arguments], stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        raise Unplaced('Hyprland did not answer.') from error
    if result.returncode != 0:
        raise Unplaced('Hyprland refused the request.')
    return result.stdout


def hyprland(query):
    try:
        return json.loads(hyprctl('-j', query))
    except (ValueError, RecursionError) as error:
        raise Unplaced('Hyprland gave an answer Magpie Mail could not read.') from error


def whole(value):
    return value if type(value) is int else None


def desk_of(client):
    workspace = client.get('workspace')
    return whole(workspace.get('id')) if isinstance(workspace, dict) else None


def windows():
    found = {}
    clients = hyprland('clients')
    for client in clients if isinstance(clients, list) else []:
        address = client.get('address') if isinstance(client, dict) else None
        if isinstance(address, str) and WINDOW_ADDRESS.fullmatch(address):
            found[address] = client
    return found


def logical_size(monitor):
    width, height, scale = monitor.get('width'), monitor.get('height'), monitor.get('scale')
    if (whole(width) is None or whole(height) is None or not isinstance(scale, (int, float))
            or not math.isfinite(scale) or scale <= 0):
        raise Unplaced('Hyprland did not report the screen size.')
    if whole(monitor.get('transform')) in (1, 3, 5, 7):
        width, height = height, width
    return width / scale, height / scale


def window_size(width, height):
    return (round(max(width * WIDTH_SHARE, min(MIN_WIDTH, width * SMALL_SCREEN_SHARE))),
            round(max(height * HEIGHT_SHARE, min(MIN_HEIGHT, height * SMALL_SCREEN_SHARE))))


def active_desk():
    workspace = hyprland('activeworkspace')
    return whole(workspace.get('id')) if isinstance(workspace, dict) else None


def origin():
    active = hyprland('activewindow')
    active = active if isinstance(active, dict) else {}
    workspace = active.get('workspace') if isinstance(active.get('workspace'), dict) else hyprland('activeworkspace')
    desk = whole(workspace.get('id')) if isinstance(workspace, dict) else None
    monitor_id = whole(active.get('monitor'))
    if monitor_id is None and isinstance(workspace, dict):
        monitor_id = whole(workspace.get('monitorID'))
    monitors = hyprland('monitors')
    monitors = [monitor for monitor in monitors if isinstance(monitor, dict)] if isinstance(monitors, list) else []
    screen = next((monitor for monitor in monitors if whole(monitor.get('id')) == monitor_id), None)
    screen = screen or next((monitor for monitor in monitors if monitor.get('focused') is True), None)
    if screen is None:
        raise Unplaced('Hyprland did not report a screen.')
    try:
        size = window_size(*logical_size(screen))
    except (ValueError, OverflowError) as error:
        raise Unplaced('Hyprland did not report the screen size.') from error
    # Invariant: a special (scratchpad) desk has a negative id and is never a destination here.
    return (desk if desk is not None and desk > 0 else None), size


def link_windows(before, mark, deadline):
    while True:
        time.sleep(0.05)
        opened = [address for address, client in windows().items()
                  if address not in before and mark in str(client.get('class', ''))]
        if opened or time.monotonic() >= deadline:
            return opened


def placement(address, desk, size, client, focus):
    target = f'"address:{address}"'
    steps = []
    if desk is not None and desk_of(client) != desk:
        steps.append(f'hl.dsp.window.move({{ workspace = "{desk}", follow = false, window = {target} }})')
    if client.get('floating') is not True:
        steps.append(f'hl.dsp.window.float({{ action = "enable", window = {target} }})')
    steps.append(f'hl.dsp.window.resize({{ x = {size[0]}, y = {size[1]}, exact = true, window = {target} }})')
    steps.append(f'hl.dsp.window.center({{ window = {target} }})')
    for prop in SOLID:
        steps.append(f'hl.dsp.window.set_prop({{ prop = "{prop}", value = "1", window = {target} }})')
        steps.append(f'hl.dsp.window.set_prop({{ prop = "{prop}_override", value = "1", window = {target} }})')
    if focus:
        steps.append(f'hl.dsp.focus({{ window = {target} }})')
    return '; '.join(f'hl.dispatch({step})' for step in steps)


def placed(client, desk, size):
    drawn = client.get('size')
    if not isinstance(drawn, list) or len(drawn) != 2 or whole(drawn[0]) is None or whole(drawn[1]) is None:
        return False
    return (client.get('floating') is True
            and abs(drawn[0] - size[0]) <= SIZE_TOLERANCE and abs(drawn[1] - size[1]) <= SIZE_TOLERANCE
            and (desk is None or desk_of(client) == desk))


def solid(address):
    for prop in SOLID:
        try:
            if float(hyprctl('getprop', f'address:{address}', prop).strip()) != 1.0:
                return False
        except ValueError:
            return False
        if hyprctl('getprop', f'address:{address}', f'{prop}_override').strip() != 'true':
            return False
    return True


def place(addresses, desk, size):
    clients = windows()
    # Invariant: focus follows only while the clicked desk is still in front, so a late window
    # never pulls the view back to it.
    focus = desk is None or active_desk() == desk
    pending = [address for address in addresses if address in clients]
    for address in pending:
        # Invariant: the URL never reaches Lua; only a checked window address and whole numbers do.
        hyprctl('eval', placement(address, desk, size, clients[address], focus=focus))
    steady = {address: 0 for address in pending}
    for _ in range(16):
        if not steady:
            return
        time.sleep(0.25)
        clients = windows()
        for address in list(steady):
            client = clients.get(address)
            if client is None:
                del steady[address]
            elif placed(client, desk, size) and solid(address):
                steady[address] += 1
                if steady[address] == 3:
                    del steady[address]
            else:
                steady[address] = 0
                # Invariant: a browser may resize its new window once its page has loaded; placing
                # it again wins.
                hyprctl('eval', placement(address, desk, size, client, focus=False))
    if steady:
        raise Unplaced('The link window did not stay where Magpie Mail put it.')


def wait_seconds():
    try:
        return min(15.0, max(0.5, float(os.environ.get('MAGPIE_LINK_WINDOW_WAIT', '15'))))
    except ValueError:
        return 15.0


def tell(text):
    # Invariant: Magpie starts this opener without reading what it says, so a link that did not open
    # is told on the desktop, in fixed words that never carry the link.
    print(text, file=sys.stderr)
    if shutil.which('notify-send'):
        try:
            start_detached(['notify-send', '-a', 'Magpie Mail', text])
        except OSError:
            pass


def show_site(host):
    # Invariant: the link window has no address bar, so the site it opens is shown for a few seconds
    # as it opens (Q-014): the host the reader and the browser agree on, never the rest of the link.
    if shutil.which('notify-send'):
        try:
            start_detached(['notify-send', '-a', 'Magpie Mail', '-t', str(SITE_NOTICE_MILLISECONDS), f'Opening {host}'])
        except OSError:
            pass


def open_plainly(browser, link, address, pages=None):
    """Open a link that cannot have a window of its own in a tab, handed to the browser or started
    with it as a window's link is, or with xdg-open without a Chromium-based browser."""
    if browser is None:
        start_detached(['xdg-open', link])
        return 0
    root = data_folder(browser)
    profile = profile_for(root, address)
    # Invariant: the link starts with http, so the browser reads it as a link and never as an option.
    arguments = ([f'--profile-directory={profile}'] if profile else []) + [link]
    went = deliver(browser, root, arguments, pages, time.monotonic() + wait_seconds())
    if went in ('ack', 'started', 'launched'):
        return 0
    if went == 'failed':
        return open_after_failure(link)
    if went == 'long':
        tell(TOO_LONG)
    else:
        tell(NOT_ANSWERED if went == 'sent' else NO_ANSWER)
    return 3


def open_after_failure(link):
    # Invariant: the browser's start failed, and it was tried only for a link the launcher hands over
    # whole, so the default opener's launch of the link alone is no worse.
    start_detached(['xdg-open', link])
    return 0


def open_in_window(browser, link, host, address, pages_path, pages):
    sweep(pages)
    launch = launch_page(pages_path, pages)
    if launch is None:
        return open_plainly(browser, link, address, pages)
    page, mark = launch
    root = data_folder(browser)
    command = browser_arguments(profile_for(root, address), page, link)
    desk = size = before = None
    if on_hyprland():
        try:
            desk, size = origin()
            before = set(windows())
        except Unplaced:
            before = None
    deadline = time.monotonic() + wait_seconds()
    went = deliver(browser, root, command, pages, deadline)
    if went == 'failed':
        return open_after_failure(link)
    if went == 'long':
        return open_plainly(browser, link, address, pages)
    if went == 'silent':
        tell(NO_ANSWER)
        return 3
    if went in ('started', 'launched'):
        # Invariant: a browser that has just started gets the whole wait for its window.
        deadline = max(deadline, time.monotonic() + wait_seconds())
    if before is None:
        if went == 'sent':
            tell(NOT_ANSWERED)
            return 3
        show_site(host)
        return 0
    try:
        opened = link_windows(before, mark, deadline)
        if not opened:
            tell(NOT_ANSWERED if went == 'sent' else NO_WINDOW)
            return 3
        show_site(host)
        place(opened, desk, size)
    except Unplaced as problem:
        print(f'Magpie Mail could not float the link window: {problem}', file=sys.stderr)
        return 3
    return 0


def main(arguments):
    # Invariant: Magpie works from the folder the browser's launcher runs in, so every relative path it
    # reads is the one the launcher and xdg-open read. A launcher without HOME would read its flags
    # from /.config, so it is given the home folder Magpie counts.
    os.environ.setdefault('HOME', os.path.expanduser('~'))
    os.chdir(launcher_home())
    if not 1 <= len(arguments) <= 2:
        raise ValueError('Open one link at a time.')
    link, host = web_link(arguments[0])
    # Invariant: a running browser reads 32 KiB of a handoff, whichever way the link reaches it.
    if len(link.encode()) > MAX_HANDOFF_BYTES:
        tell(TOO_LONG)
        return 3
    address = mailbox(arguments[1]) if len(arguments) == 2 else ''
    browser = chromium_browser()
    if browser is None:
        return open_plainly(None, link, address)
    # Invariant: no link is handed over when the launcher could read flags from any file (handoff_fits),
    # and this is said in its own words.
    if flags_name_split(browser):
        tell(SPLIT_NAME)
        return 3
    try:
        pages_path, pages = pages_folder()
    except OSError:
        return open_plainly(browser, link, address)
    try:
        return open_in_window(browser, link, host, address, pages_path, pages)
    finally:
        os.close(pages)


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except ValueError:
        tell(NOT_PUBLIC)
        sys.exit(2)
    except OSError:
        tell(NO_BROWSER)
        sys.exit(1)
