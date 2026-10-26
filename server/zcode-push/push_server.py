#!/usr/bin/env python3
"""ZCode App external push relay (v1.8.0).

Desktop ZCode hooks POST here when a permission request appears or a task
stops; the phone app long-polls and raises local notifications. This channel
deliberately does NOT touch the ZCode relay terminal slot, so it can never
fight with the WebView session or the headless monitor over ZCode's
single-controller constraint.

Design constraints:
  * stdlib only (no third-party web framework assumed on the host);
  * one small process, own SQLite file, own systemd unit - zero coupling
    with the existing kaogong-api service on :8787;
  * every data endpoint is token-authenticated; the token is minted by an
    explicit CLI call (no default token baked in);
  * bounded storage: delivered rows are dropped, plus MAX_AGE / MAX_ROWS caps;
  * logs never contain bodies or tokens.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("ZPUSH_DB", "/var/lib/zcode-push/push.db")
TOKEN_FILE = os.environ.get("ZPUSH_TOKEN_FILE", "/etc/zcode-push/token")
MAX_AGE_SECONDS = 7 * 24 * 3600
MAX_ROWS = 2000
LONG_POLL_SECONDS = 25.0
MAX_BODY = 64 * 1024
MAX_TITLE = 200
MAX_BODY_TEXT = 600

_db_lock = threading.Lock()


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def init_db() -> None:
    directory = os.path.dirname(DB_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with _db_lock, _connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                body TEXT NOT NULL DEFAULT '',
                session_id TEXT NOT NULL DEFAULT '',
                device TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                delivered INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_pending ON messages(account, delivered, id)"
        )


def _token() -> str:
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _clean(value: object, limit: int) -> str:
    text = str(value or "").replace("\x00", " ").strip()
    return text[:limit]


def _constant_time_eq(a: str, b: str) -> bool:
    if len(a) != len(b):
        return False
    result = 0
    for x, y in zip(a.encode("utf-8"), b.encode("utf-8")):
        result |= x ^ y
    return result == 0


def _account_of(token: str) -> str | None:
    """Map a token to an account bucket.

    v1 uses one shared token per install; the bucket is a constant so that a
    second phone/account can be added later without a schema change.
    """
    expected = _token()
    if not expected or len(token) < 16:
        return None
    if not _constant_time_eq(token, expected):
        return None
    return "default"


class Handler(BaseHTTPRequestHandler):
    server_version = "zcode-push/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # Deliberately terse: never log bodies or tokens.
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # ---- plumbing ----

    def _send(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def _auth(self) -> str | None:
        return _account_of(self.headers.get("X-ZP-Token", ""))

    def _read_json(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            raw = self.rfile.read(length)
            parsed = json.loads(raw.decode("utf-8"))
        except (OSError, ValueError):
            return None
        return parsed if isinstance(parsed, dict) else None

    # ---- routing ----

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        parsed = urlparse(self.path)
        if parsed.path == "/zpush/healthz":
            self._send(200, {"ok": True, "pending": self._pending_count()})
            return
        if parsed.path == "/zpush/poll":
            self._poll(parsed)
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        parsed = urlparse(self.path)
        if parsed.path == "/zpush/publish":
            self._publish()
            return
        if parsed.path == "/zpush/ack":
            self._ack()
            return
        self._send(404, {"error": "not_found"})

    # ---- handlers ----

    def _pending_count(self) -> int:
        try:
            with _db_lock, _connect() as conn:
                row = conn.execute(
                    "SELECT COUNT(*) AS n FROM messages WHERE delivered=0"
                ).fetchone()
                return int(row["n"]) if row else 0
        except sqlite3.Error:
            return -1

    def _publish(self) -> None:
        account = self._auth()
        if account is None:
            self._send(401, {"error": "unauthorized"})
            return
        body = self._read_json()
        if body is None:
            self._send(400, {"error": "bad_json"})
            return
        kind = _clean(body.get("kind"), 40) or "info"
        title = _clean(body.get("title"), MAX_TITLE)
        text = _clean(body.get("body"), MAX_BODY_TEXT)
        session_id = _clean(body.get("sessionId"), 120)
        device = _clean(body.get("device"), 120)
        if not title and not text:
            self._send(400, {"error": "empty"})
            return
        now = time.time()
        with _db_lock, _connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO messages
                  (account, kind, title, body, session_id, device, created_at, delivered)
                VALUES (?,?,?,?,?,?,?,0)
                """,
                (account, kind, title, text, session_id, device, now),
            )
            new_id = cur.lastrowid
            conn.execute("DELETE FROM messages WHERE delivered=1")
            conn.execute(
                "DELETE FROM messages WHERE created_at < ?", (now - MAX_AGE_SECONDS,)
            )
            conn.execute(
                """
                DELETE FROM messages WHERE id IN (
                  SELECT id FROM messages ORDER BY id DESC LIMIT -1 OFFSET ?
                )
                """,
                (MAX_ROWS,),
            )
        self._send(200, {"ok": True, "id": new_id})

    def _poll(self, parsed) -> None:
        account = self._auth()
        if account is None:
            self._send(401, {"error": "unauthorized"})
            return
        query = parse_qs(parsed.query)
        try:
            after = int(query.get("after", ["0"])[0])
        except ValueError:
            after = 0
        deadline = time.time() + LONG_POLL_SECONDS
        while True:
            rows = self._fetch_pending(account, after)
            if rows or time.time() >= deadline:
                self._send(
                    200, {"ok": True, "messages": rows, "now": int(time.time())}
                )
                return
            time.sleep(0.75)

    def _fetch_pending(self, account: str, after: int) -> list[dict]:
        with _db_lock, _connect() as conn:
            rows = conn.execute(
                """
                SELECT id, kind, title, body, session_id, device, created_at
                FROM messages
                WHERE account=? AND delivered=0 AND id>?
                ORDER BY id ASC LIMIT 50
                """,
                (account, after),
            ).fetchall()
        return [
            {
                "id": row["id"],
                "kind": row["kind"],
                "title": row["title"],
                "body": row["body"],
                "sessionId": row["session_id"],
                "device": row["device"],
                "ts": int(row["created_at"] * 1000),
            }
            for row in rows
        ]

    def _ack(self) -> None:
        account = self._auth()
        if account is None:
            self._send(401, {"error": "unauthorized"})
            return
        body = self._read_json()
        if body is None:
            self._send(400, {"error": "bad_json"})
            return
        ids = body.get("ids")
        if not isinstance(ids, list) or not ids:
            self._send(400, {"error": "no_ids"})
            return
        clean_ids: list[int] = []
        for item in ids:
            try:
                clean_ids.append(int(item))
            except (TypeError, ValueError):
                continue
        if not clean_ids:
            self._send(400, {"error": "no_ids"})
            return
        with _db_lock, _connect() as conn:
            conn.executemany(
                "UPDATE messages SET delivered=1 WHERE id=? AND account=?",
                [(i, account) for i in clean_ids],
            )
        self._send(200, {"ok": True, "acked": len(clean_ids)})


def _mint_token() -> int:
    import secrets

    directory = os.path.dirname(TOKEN_FILE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    token = secrets.token_urlsafe(32)
    with open(TOKEN_FILE, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    os.chmod(TOKEN_FILE, 0o600)
    print(token)
    return 0


def main() -> int:
    init_db()
    if not _token():
        sys.stderr.write(
            "FATAL: no token at %s - run with --mint-token first\n" % TOKEN_FILE
        )
        return 2
    host = os.environ.get("ZPUSH_HOST", "127.0.0.1")
    port = int(os.environ.get("ZPUSH_PORT", "8788"))
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    sys.stderr.write("zcode-push listening on %s:%d db=%s\n" % (host, port, DB_PATH))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    if "--mint-token" in sys.argv:
        sys.exit(_mint_token())
    sys.exit(main())
