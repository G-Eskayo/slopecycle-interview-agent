"""Durable run ledger (SQLite). Decides what to process, hands out exactly one claim per Source revision, and
remembers results until n8n confirms they were written."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from .sources import SourceKind, classify

LEASE = timedelta(minutes=30)
WRITE_GRACE = timedelta(minutes=3)
MAX_ATTEMPTS = 3
BACKOFF_BASE = timedelta(minutes=5)
BACKOFF_MAX = timedelta(hours=6)

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    run_id TEXT PRIMARY KEY,
    source_file_id TEXT NOT NULL,
    revision_key TEXT NOT NULL,
    content_sha256 TEXT,
    source_name TEXT,
    status TEXT NOT NULL,            -- claimed | awaiting_write | completed | retry | failed | duplicate
    attempt_count INTEGER NOT NULL DEFAULT 0,
    write_failures INTEGER NOT NULL DEFAULT 0,
    started_at TEXT, updated_at TEXT, completed_at TEXT, next_attempt_at TEXT,
    output_record_key TEXT, error_category TEXT, error_message TEXT,
    duplicate_of TEXT,
    result_json TEXT,                -- rows waiting to be verified in the sheet; cleared once verified
    verified_at TEXT, purged_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS one_run_per_revision ON runs(source_file_id, revision_key) WHERE status != 'duplicate';
CREATE INDEX IF NOT EXISTS by_sha ON runs(content_sha256);
"""

SECRETS = re.compile(r"(ya29\.[\w-]+|bearer\s+\S+|token=\S+|key=\S+|password=\S+)", re.I)


def revision_key(file: dict) -> str:
    if file.get("md5Checksum"):
        return f"md5:{file['md5Checksum']}"
    if file.get("version"):
        return f"v:{file['version']}"
    return f"mod:{file.get('modifiedTime', '')}"


def _has_rows(result_json: str | None) -> bool:
    return bool(result_json) and bool(json.loads(result_json).get("interview_rows"))


def run_id_for(file_id: str, rev: str) -> str:
    return "RUN-" + hashlib.sha1(f"{file_id}|{rev}".encode()).hexdigest()[:10]


def sanitize(msg: str) -> str:
    return SECRETS.sub("[redacted]", " ".join(str(msg).split()))[:300]


@dataclass(frozen=True)
class Claim:
    action: str  # process | duplicate
    run_id: str
    attempt: int
    duplicate_of: str | None = None


class Ledger:
    def __init__(self, path: Path | str):
        self.path = str(path)
        with self._db() as db:
            db.executescript(SCHEMA)
            cols = {r["name"] for r in db.execute("PRAGMA table_info(runs)")}
            for col in ("verified_at", "purged_at"):
                if col not in cols:
                    db.execute(f"ALTER TABLE runs ADD COLUMN {col} TEXT")

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        return db

    def get(self, run_id: str) -> dict | None:
        with self._db() as db:
            row = db.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        return dict(row) if row else None

    def recent(self, limit: int = 50) -> list[dict]:
        with self._db() as db:
            rows = db.execute("SELECT * FROM runs ORDER BY updated_at DESC LIMIT ?", (limit,)).fetchall()
        return [{k: r[k] for k in r.keys() if k != "result_json"} for r in rows]

    def plan(self, files: list[dict], now: datetime) -> list[dict]:
        todo = []
        with self._db() as db:
            for file in files:
                kind = classify(file.get("name", ""), file.get("mimeType", ""))
                if kind is SourceKind.FOLDER:
                    continue
                rev = revision_key(file)
                row = db.execute(
                    "SELECT * FROM runs WHERE source_file_id = ? AND revision_key = ? AND status != 'duplicate'",
                    (file["id"], rev)).fetchone()
                action = self._next_action(row, now)
                if action is None:
                    continue
                if action == "process" and kind is SourceKind.UNSUPPORTED:
                    action = "reject"
                todo.append({"file_id": file["id"], "name": file.get("name"), "mime_type": file.get("mimeType"),
                             "revision_key": rev, "action": action,
                             "run_id": row["run_id"] if row else run_id_for(file["id"], rev)})
        return todo

    @staticmethod
    def _next_action(row, now: datetime) -> str | None:
        if row is None:
            return "process"
        status, updated = row["status"], datetime.fromisoformat(row["updated_at"])
        due = row["next_attempt_at"] is None or datetime.fromisoformat(row["next_attempt_at"]) <= now
        if status == "claimed":
            return "process" if now - updated > LEASE else None
        if status == "awaiting_write":
            return "rewrite" if now - updated > WRITE_GRACE else None
        if status == "retry" and due:
            return "rewrite" if _has_rows(row["result_json"]) else "process"
        return None

    def claim(self, file_id: str, rev: str, sha: str, name: str, now: datetime) -> Claim:
        rid = run_id_for(file_id, rev)
        ts = now.isoformat()
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                row = db.execute("SELECT * FROM runs WHERE run_id = ?", (rid,)).fetchone()
                same_bytes = db.execute(
                    "SELECT run_id FROM runs WHERE content_sha256 = ? AND source_file_id != ? "
                    "AND status IN ('awaiting_write', 'completed') LIMIT 1", (sha, file_id)).fetchone()
                busy = row is not None and self._next_action(row, now) != "process"
                if busy or same_bytes:
                    dup = Claim("duplicate", "DUP-" + uuid.uuid4().hex[:10], 0, row["run_id"] if busy else same_bytes["run_id"])
                    db.execute(
                        "INSERT INTO runs (run_id, source_file_id, revision_key, content_sha256, source_name, status, "
                        "started_at, updated_at, completed_at, duplicate_of) VALUES (?,?,?,?,?, 'duplicate', ?,?,?,?)",
                        (dup.run_id, file_id, rev, sha, name, ts, ts, ts, dup.duplicate_of))
                    db.execute("COMMIT")
                    return dup
                attempt = (row["attempt_count"] if row else 0) + 1
                if row is None:
                    db.execute(
                        "INSERT INTO runs (run_id, source_file_id, revision_key, content_sha256, source_name, status, "
                        "attempt_count, started_at, updated_at) VALUES (?,?,?,?,?, 'claimed', 1, ?, ?)",
                        (rid, file_id, rev, sha, name, ts, ts))
                else:
                    db.execute(
                        "UPDATE runs SET status='claimed', attempt_count=?, content_sha256=?, updated_at=?, "
                        "error_category=NULL, error_message=NULL, next_attempt_at=NULL WHERE run_id=?",
                        (attempt, sha, ts, rid))
                db.execute("COMMIT")
                return Claim("process", rid, attempt)
            except BaseException:
                db.execute("ROLLBACK")
                raise

    def awaiting_write(self, run_id: str, result: dict, record_key: str | None, now: datetime) -> None:
        with self._db() as db:
            db.execute("UPDATE runs SET status='awaiting_write', result_json=?, output_record_key=?, updated_at=? "
                       "WHERE run_id=?", (json.dumps(result), record_key, now.isoformat(), run_id))

    def cached_result(self, run_id: str) -> dict | None:
        row = self.get(run_id)
        return json.loads(row["result_json"]) if row and row["result_json"] else None

    def cache(self, run_id: str, result: dict) -> None:
        """Remember the exact rows handed to n8n, so verification compares against what was sent."""
        with self._db() as db:
            db.execute("UPDATE runs SET result_json=? WHERE run_id=?", (json.dumps(result), run_id))

    def verified(self, run_id: str, now: datetime) -> None:
        """The sheet holds this run's rows. Forget the cached interview content; keep only fingerprints."""
        with self._db() as db:
            row = db.execute("SELECT status, result_json FROM runs WHERE run_id=?", (run_id,)).fetchone()
            if row is None:
                return
            status = "completed" if _has_rows(row["result_json"]) and row["status"] in ("awaiting_write", "retry") else row["status"]
            db.execute("UPDATE runs SET status=?, verified_at=?, completed_at=COALESCE(completed_at, ?), result_json=NULL, "
                       "error_category=CASE WHEN ?='completed' THEN NULL ELSE error_category END, updated_at=? WHERE run_id=?",
                       (status, now.isoformat(), now.isoformat(), status, now.isoformat(), run_id))

    def purgeable(self, source_file_id: str, rev: str) -> bool:
        """True only if the sheet was verified for this exact Submission (or it is a verified copy of another one)."""
        with self._db() as db:
            done = db.execute("SELECT 1 FROM runs WHERE source_file_id=? AND revision_key=? AND status='completed' "
                              "AND verified_at IS NOT NULL", (source_file_id, rev)).fetchone()
            copy = db.execute(
                "SELECT 1 FROM runs d JOIN runs o ON o.run_id = d.duplicate_of WHERE d.source_file_id=? AND d.revision_key=? "
                "AND d.status='duplicate' AND d.verified_at IS NOT NULL AND o.source_file_id != d.source_file_id",
                (source_file_id, rev)).fetchone()
        return bool(done or copy)

    def mark_purged(self, source_file_id: str, now: datetime) -> None:
        with self._db() as db:
            db.execute("UPDATE runs SET purged_at=? WHERE source_file_id=?", (now.isoformat(), source_file_id))

    def in_flight(self) -> bool:
        with self._db() as db:
            return db.execute("SELECT 1 FROM runs WHERE status IN ('claimed','awaiting_write') "
                              "OR (status='retry' AND result_json IS NOT NULL AND result_json LIKE '%interview_rows%')").fetchone() is not None

    def touch(self, run_id: str, now: datetime) -> None:
        with self._db() as db:
            db.execute("UPDATE runs SET status='awaiting_write', updated_at=? WHERE run_id=? AND status='retry'",
                       (now.isoformat(), run_id))

    def complete(self, run_id: str, now: datetime) -> bool:
        with self._db() as db:
            db.execute("UPDATE runs SET status='completed', completed_at=?, updated_at=?, error_category=NULL, "
                       "error_message=NULL WHERE run_id=? AND status IN ('awaiting_write', 'retry') AND result_json IS NOT NULL",
                       (now.isoformat(), now.isoformat(), run_id))
            row = db.execute("SELECT status FROM runs WHERE run_id=?", (run_id,)).fetchone()
        return bool(row and row["status"] == "completed")

    def write_failed(self, run_id: str, message: str, now: datetime) -> None:
        with self._db() as db:
            row = db.execute("SELECT write_failures FROM runs WHERE run_id=?", (run_id,)).fetchone()
            if row is None:
                return
            n = row["write_failures"] + 1
            wait = min(BACKOFF_BASE * (2 ** (n - 1)), BACKOFF_MAX)
            db.execute("UPDATE runs SET status='retry', write_failures=?, error_category='sheet_write', error_message=?, "
                       "updated_at=?, next_attempt_at=? WHERE run_id=? AND status != 'completed'",
                       (n, sanitize(message), now.isoformat(), (now + wait).isoformat(), run_id))

    def fail(self, run_id: str, category: str, message: str, retryable: bool, now: datetime) -> str:
        with self._db() as db:
            row = db.execute("SELECT attempt_count FROM runs WHERE run_id=?", (run_id,)).fetchone()
            attempts = row["attempt_count"] if row else MAX_ATTEMPTS
            status = "retry" if retryable and attempts < MAX_ATTEMPTS else "failed"
            wait = min(BACKOFF_BASE * (2 ** (attempts - 1)), BACKOFF_MAX)
            db.execute("UPDATE runs SET status=?, error_category=?, error_message=?, updated_at=?, next_attempt_at=?, "
                       "completed_at=? WHERE run_id=?",
                       (status, category, sanitize(message), now.isoformat(),
                        (now + wait).isoformat() if status == "retry" else None,
                        now.isoformat() if status == "failed" else None, run_id))
        return status
