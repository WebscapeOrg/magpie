#!/usr/bin/env python3
"""Retained-file ownership through real backend processes and durable outbox state."""
import base64
import email
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
OWNER = "owner@example.test"
FOREIGN = "foreign@example.test"


class Backend:
    def __init__(self, env):
        self.process = subprocess.Popen([str(ROOT / "target/debug/omamail"), "serve"], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True)
        self.replies = queue.Queue()
        self.serial = 0
        def read():
            for line in self.process.stdout:
                self.replies.put(json.loads(line))
        threading.Thread(target=read, daemon=True).start()

    def call(self, method, params, error=None):
        self.serial += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.serial,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            reply = self.replies.get(timeout=15)
            if reply.get("id") == self.serial: break
        if error:
            assert reply.get("error", {}).get("message") == error, reply
            return reply
        assert "error" not in reply, reply
        return reply["result"]

    def close(self):
        if self.process.poll() is not None: return
        self.process.stdin.close()
        try: self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise


def main():
    with tempfile.TemporaryDirectory(prefix="magpie-retained-rpc-") as name:
        root = Path(name)
        env = dict(os.environ)
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            path = root / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        config = Path(env["XDG_CONFIG_HOME"]) / "omamail"
        config.mkdir(mode=0o700)
        registry = config / "accounts.json"
        registry.write_text(json.dumps({"version": 1, "activeId": OWNER,
                                       "accounts": [{"email": account, "provider": "gmail"} for account in (OWNER, FOREIGN)]}))
        registry.chmod(0o600)
        original = root / "retained.txt"
        sentinel = b"synthetic retained attachment bytes"
        original.write_bytes(sentinel)
        backend = Backend(env)
        try:
            retained = backend.call("attachment.import", {"accountId": OWNER, "draftKey": "draft-a", "path": str(original)})
            assert "handle" in retained and "data" not in retained
        finally:
            backend.close()
        original.unlink()
        backend = Backend(env)
        try:
            def compose(account, draft, identity, error=None):
                return backend.call("outbox.compose", {"accountId": account, "provider": "gmail", "sendId": identity,
                    "order": 1, "delaySeconds": 60, "resumeUnsent": True, "fields": {
                        "from": account, "to": "recipient@example.test", "subject": "Synthetic restored draft",
                        "body": "Synthetic body", "draftKey": draft, "attachments": [retained]}}, error)
            for account, draft, identity in ((FOREIGN, "draft-a", "foreign-account"), (OWNER, "draft-b", "foreign-draft")):
                refused = compose(account, draft, identity, "attachment_handle_unavailable")
                assert sentinel.decode() not in json.dumps(refused)
                snapshot = backend.call("outbox.snapshot", {"accountId": account})
                assert snapshot["entries"] == [], "foreign handles must not reach the outbox"
            accepted = compose(OWNER, "draft-a", "restored-owner")
            snapshot = backend.call("outbox.snapshot", {"accountId": OWNER, "sendId": accepted["id"], "includePayloads": True})
            entries = snapshot["entries"]
            assert len(entries) == 1 and entries[0]["state"] in ("waiting", "queued")
            raw = entries[0]["payload"]["raw"]
            message = email.message_from_bytes(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
            assert [part.get_payload(decode=True) for part in message.walk() if part.get_filename()] == [sentinel]
            backend.call("outbox.undo", {"accountId": OWNER, "sendId": accepted["id"]})
            cancelled = backend.call("outbox.snapshot", {"accountId": OWNER})
            assert cancelled["entries"][0]["state"] == "cancelled"
        finally:
            backend.close()
    print("PASS: restored handle survives process restart and source removal; foreign account/draft enqueue nothing; owner MIME retains exact bytes; synthetic send cancelled before dispatch")


if __name__ == "__main__":
    main()
