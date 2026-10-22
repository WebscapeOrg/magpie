#!/usr/bin/env python3
"""Exercise saved-search reads through the real Linux backend and owner socket."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
OWNER = "search-owner@example.test"
OTHER = "search-other@example.test"
SECRET = "Synthetic-private-search-合成-987654"
AS_OF = 1_792_584_000_000


def mail_directory(state, account):
    return state / "omamail/mail" / hashlib.sha256(account.encode()).hexdigest()


def seed(state, account, subject, unique_id):
    directory = mail_directory(state, account)
    directory.mkdir(parents=True, mode=0o700)
    for parent in (directory.parent, directory.parent.parent):
        parent.chmod(0o700)
    database = directory / "mail.sqlite"
    with sqlite3.connect(database) as connection:
        connection.executescript((ROOT / "src/local_mail/schema.sql").read_text())
        for message_id in ("shared", unique_id):
            summary = {"id": message_id, "subject": subject, "date": AS_OF - 1000,
                       "from": {"email": account, "name": "Synthetic"}}
            connection.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                message_id, "thread", AS_OF - 1000, json.dumps(summary),
                "intentionally-missing-resource-blob", '["INBOX","UNREAD"]', account,
                OWNER, "", subject, "", 0, 1, 1))
            connection.executemany("INSERT INTO labels VALUES(?,?)",
                                   [(message_id, "INBOX"), (message_id, "UNREAD")])
            connection.execute("INSERT INTO search VALUES(?,?,?,?,?,?,?)", (
                message_id, subject, account, OWNER, "", "", SECRET))
    database.chmod(0o600)
    return directory


class Backend:
    def __init__(self, temporary, env):
        self.trace = temporary / "network.trace"
        binary = Path(os.environ.get("OMAMAIL_TEST_BACKEND", ROOT / "target/debug/omamail")).resolve()
        if not binary.is_file():
            raise AssertionError("Build the backend before running tests/test_search_backend.py")
        command = [shutil.which("bwrap"), "--unshare-net", "--die-with-parent", "--ro-bind", "/", "/",
                   "--tmpfs", "/tmp", "--chmod", "0700", "/tmp",
                   "--bind", str(temporary), str(temporary), "--proc", "/proc", "--dev", "/dev",
                   shutil.which("strace"), "-f", "-qq", "-e", "trace=connect,sendto,sendmsg,sendmmsg",
                   "-o", str(self.trace), str(binary), "serve"]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.sequence = 0
        self.stderr = ""

    def call(self, method, params):
        self.sequence += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.sequence,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        with selectors.DefaultSelector() as reader:
            reader.register(self.process.stdout, selectors.EVENT_READ)
            while reader.select(10):
                line = self.process.stdout.readline()
                if not line:
                    break
                reply = json.loads(line)
                if reply.get("id") == self.sequence:
                    return reply
        raise AssertionError("Search backend response deadline exceeded")

    def close(self):
        if self.process.poll() is None:
            try:
                reply = self.call("system.quit", {})
                assert reply.get("result", {}).get("quitReady"), reply
                self.process.wait(timeout=10)
            finally:
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait()
        self.stderr = self.process.stderr.read()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()
        assert self.process.returncode == 0, self.stderr


def owner_request(directory, method, params):
    request = json.dumps({"method": method, "params": params}).encode()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            connection.connect(f"/proc/self/fd/{descriptor}/outbox.sock")
        finally:
            os.close(descriptor)
        connection.sendall(struct.pack(">I", len(request)) + request)
        size = struct.unpack(">I", connection.recv(4, socket.MSG_WAITALL))[0]
        assert size < 16 * 1024 * 1024
        return json.loads(connection.recv(size, socket.MSG_WAITALL))


@unittest.skipUnless(sys.platform == "linux" and shutil.which("bwrap") and shutil.which("strace"),
                     "Linux bubblewrap and strace are required for network-effect verification")
class SearchBackend(unittest.TestCase):
    def test_account_owned_projection_query_safety_and_private_logs(self):
        with tempfile.TemporaryDirectory(prefix="magpie-search-backend-") as name:
            temporary = Path(name)
            env = dict(os.environ)
            for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"):
                folder = temporary / key.lower()
                folder.mkdir(mode=0o700)
                env[key] = str(folder)
            env.pop("DBUS_SESSION_BUS_ADDRESS", None)
            config = Path(env["XDG_CONFIG_HOME"]) / "omamail"
            config.mkdir(mode=0o700)
            registry = config / "accounts.json"
            registry.write_text(json.dumps({"version": 1, "activeId": OWNER, "accounts": [
                {"provider": "gmail", "email": OWNER}, {"provider": "gmail", "email": OTHER}]}))
            registry.chmod(0o600)
            original_registry = registry.read_bytes()
            state = Path(env["XDG_STATE_HOME"])
            owner_dir = seed(state, OWNER, "Owner " + SECRET, "owner-only")
            seed(state, OTHER, "Other private subject", "other-only")
            backend = Backend(temporary, env)
            try:
                def read(account, ids, **extra):
                    return backend.call("local.summaries", dict(accountId=account, ids=ids,
                                                                query="is:unread", asOf=AS_OF, **extra))

                own_reply = read(OWNER, ["shared", "other-only"])
                self.assertIn("result", own_reply)
                own = own_reply["result"]
                self.assertEqual([row["id"] for row in own["summaries"]], ["shared"])
                self.assertEqual(own["missingIds"], ["other-only"])
                self.assertEqual(own["summaries"][0]["subject"], "Owner " + SECRET)
                self.assertTrue(own["summaries"][0]["matchesQuery"])
                self.assertNotIn("Other private subject", json.dumps(own))
                other = read(OTHER, ["shared", "owner-only"])["result"]
                self.assertEqual(other["summaries"][0]["subject"], "Other private subject")
                self.assertEqual(other["missingIds"], ["owner-only"])
                self.assertNotIn(SECRET, json.dumps(other, ensure_ascii=False))
                unknown = "unknown-private-account@example.test"
                denied = read(unknown, ["shared"])
                self.assertEqual(denied["error"]["message"], "local_account_unknown")
                self.assertFalse(mail_directory(state, unknown).exists())
                self.assertNotIn(SECRET, json.dumps(denied, ensure_ascii=False))

                for query in ["subject:\"' OR 1=1 --\"", "subject:\"%_\\\\\""]:
                    reply = backend.call("local.list", {"accountId": OWNER, "query": query,
                                                       "asOf": AS_OF, "limit": 50, "pageToken": ""})
                    self.assertEqual(reply["result"]["summaries"], [], reply)
                for value in ["shared\r", "shared\n", "shared\r\n", "shared\0"]:
                    refused = read(OWNER, [value])
                    self.assertIn("error", refused)
                    self.assertNotIn(SECRET, json.dumps(refused, ensure_ascii=False))

                foreign = owner_request(owner_dir, "local.summaries", {
                    "accountId": OTHER, "ids": ["shared"], "query": "", "asOf": AS_OF})
                self.assertEqual(foreign, {"error": "local_account_unknown"})
                same = owner_request(owner_dir, "local.summaries", {
                    "accountId": OWNER, "ids": ["shared"], "query": "", "asOf": AS_OF})
                self.assertEqual(same["result"]["summaries"][0]["subject"], "Owner " + SECRET)
                self.assertNotIn("Other private subject", json.dumps(same))
                forbidden = temporary / "forbidden-output"
                malformed = backend.call("local.summaries", {
                    "accountId": OWNER, "ids": ["shared"], "path": str(forbidden)})
                self.assertIn("error", malformed)
                self.assertFalse(forbidden.exists())
                secret_query = "subject:\"" + SECRET + "\""
                found = backend.call("local.list", {"accountId": OWNER, "query": secret_query,
                                                    "asOf": AS_OF, "limit": 50, "pageToken": ""})
                self.assertEqual(len(found["result"]["summaries"]), 2)
            finally:
                backend.close()

            self.assertEqual(registry.read_bytes(), original_registry)
            logs = state / "omamail/diagnostics"
            rpc = logs / "rpc.json"
            self.assertTrue(rpc.is_file(), "The privacy check requires real persisted diagnostics")
            events = json.loads(rpc.read_text())
            self.assertTrue(any(event["method"] == "local.summaries" for event in events))
            for path in logs.iterdir():
                if not path.is_file():
                    continue
                content = path.read_text()
                for private in (SECRET, OWNER, OTHER, "Other private subject", "unknown-private-account"):
                    self.assertNotIn(private, content)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(SECRET, backend.stderr)
            trace = backend.trace.read_text()
            self.assertNotRegex(trace, r"AF_INET6?\b", "Saved-search reads must issue no network request")
            self.assertFalse(list(owner_dir.glob("intentionally-missing*")),
                             "Summary projection must not materialize a message resource")


if __name__ == "__main__":
    unittest.main()
