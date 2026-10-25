"""HTTP surface n8n calls. Every response carries ready-to-write rows so n8n never decides anything.

Lifecycle (ADR 0006): sync → process → n8n writes → n8n reads the rows back → verify → purge → compact."""

from __future__ import annotations

import html
import os
import threading
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

from . import pipeline
from .extract import ModelOutputInvalid, ModelUnavailable
from .ledger import Ledger, sanitize
from .queue import QueueRepo, QueueUnavailable
from .sources import SUBMISSION_MIME, UnsupportedSource
from .validate import NothingExtracted, escape_cell, interview_id, sheet_interview_row
from .verify import verify

RUN_LOG_COLUMNS = ["run_id", "source_file_id", "source_name", "source_revision", "status", "attempt_count",
                   "started_at", "completed_at", "output_record_key", "error_category", "error_message"]

FAILURES = {
    UnsupportedSource: ("unsupported_or_unreadable", False),
    NothingExtracted: ("nothing_extracted", False),
    ModelUnavailable: ("model_unavailable", True),
    ModelOutputInvalid: ("model_output_invalid", True),
    pipeline.TranscriptionFailed: ("transcription_failed", True),
    QueueUnavailable: ("queue_unavailable", True),
}
STATUS_LABEL = {"claimed": "running", "awaiting_write": "completed", "completed": "completed", "retry": "failed (will retry)",
                "failed": "failed (needs a person)", "duplicate": "duplicate (skipped)"}


def load_env_file(path: Path | None = None) -> None:
    """Read ~/.slopecycle.env (mode 600) so the GitHub key never sits in a world-readable launchd plist.
    Real environment variables win."""
    path = path or Path(os.environ.get("SLOPE_ENV_FILE", Path.home() / ".slopecycle.env"))
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def data_dir() -> Path:
    d = Path(os.environ.get("SLOPE_DATA_DIR", Path.home() / "Library/Application Support/slope-processor"))
    d.mkdir(parents=True, exist_ok=True)
    return d


if not os.environ.get("PYTEST_CURRENT_TEST"):
    load_env_file()
app = FastAPI(title="SlopeCycle interview processor")
_ledger: Ledger | None = None
_queue: QueueRepo | None = None
_sync_lock = threading.Lock()
_last_queue_error: str | None = None


def ledger() -> Ledger:
    global _ledger
    if _ledger is None:
        _ledger = Ledger(data_dir() / "runs.sqlite3")
    return _ledger


def queue() -> QueueRepo:
    global _queue
    if _queue is None:
        repo = os.environ.get("SLOPE_QUEUE_REPO", "")
        url = os.environ.get("SLOPE_QUEUE_URL") or (f"https://github.com/{repo}.git" if repo else "")
        if not url:
            raise HTTPException(503, "SLOPE_QUEUE_REPO is not set (owner/name of the private queue repo)")
        _queue = QueueRepo(data_dir() / "queue", url, os.environ.get("SLOPE_QUEUE_TOKEN"))
    return _queue


def run_log_row(run_id: str, final_status: str | None = None) -> dict:
    r = ledger().get(run_id)
    row = {
        "run_id": r["run_id"], "source_file_id": r["source_file_id"], "source_name": r["source_name"],
        "source_revision": r["revision_key"], "status": final_status or STATUS_LABEL.get(r["status"], r["status"]),
        "attempt_count": r["attempt_count"], "started_at": r["started_at"],
        "completed_at": r["completed_at"] or (r["updated_at"] if final_status == "completed" else None),
        "output_record_key": r["output_record_key"],
        "error_category": r["error_category"] or ("duplicate" if r["status"] == "duplicate" else None),
        "error_message": r["error_message"] or (f"same content as {r['duplicate_of']}" if r["duplicate_of"] else None),
    }
    return {k: "" if row[k] is None else escape_cell(row[k]) for k in RUN_LOG_COLUMNS}


def _cells(rows: list[dict]) -> list[dict]:
    # n8n's append-or-update skips null values, which would leave a stale answer in place. Never send nulls.
    return [{k: "" if v is None else v for k, v in r.items()} for r in rows]


def respond(run_id: str, rows: dict | None = None, final_status: str | None = None) -> dict:
    """Build the rows for n8n and remember exactly what was sent, so verification compares like with like."""
    rows = rows or {}
    out = {
        "interview_rows": [sheet_interview_row(r) for r in rows.get("interview_rows", [])],
        "evidence_rows": _cells(rows.get("evidence_rows", [])),
        "run_log_rows": [run_log_row(run_id, final_status)],
    }
    ledger().cache(run_id, out)
    return {"run_id": run_id, "write": bool(out["interview_rows"]), **out}


@app.post("/queue/sync")
def queue_sync():
    """Every trigger lands here: bring the clone up to date, tidy what's verified, and say what to do next."""
    global _last_queue_error
    with _sync_lock:
        led, q = ledger(), queue()
        try:
            q.sync()
            refs = q.submissions()
            purged = []
            for ref in refs:
                if led.purgeable(ref.submission_id, f"v:{ref.tree_sha}") and q.purge(ref.submission_id):
                    led.mark_purged(ref.submission_id, now())
                    purged.append(ref.submission_id)
            remaining = [r for r in refs if r.submission_id not in purged]
            compacted = not remaining and not led.in_flight() and q.compact()
            _last_queue_error = None
        except QueueUnavailable as exc:
            _last_queue_error = sanitize(str(exc))
            raise HTTPException(503, f"queue repo unavailable: {_last_queue_error}") from exc
        files = [{"id": r.submission_id, "name": r.submission_id, "mimeType": SUBMISSION_MIME, "version": r.tree_sha}
                 for r in remaining]
        return {"todo": led.plan(files, now()), "purged": purged, "compacted": bool(compacted)}


class ProcessRequest(BaseModel):
    action: str = "process"


@app.post("/submissions/{submission_id}/process")
def process_submission(submission_id: str, req: ProcessRequest = Body(default_factory=ProcessRequest)):
    led, q = ledger(), queue()
    ref = next((r for r in q.submissions() if r.submission_id == submission_id), None)
    if ref is None:
        raise HTTPException(404, "no such submission in the queue (already processed and removed?)")
    rev = f"v:{ref.tree_sha}"

    if req.action == "rewrite":
        todo = led.plan([{"id": submission_id, "name": submission_id, "mimeType": SUBMISSION_MIME, "version": ref.tree_sha}], now())
        run_id = next((t["run_id"] for t in todo if t["action"] == "rewrite"), None)
        cached = led.cached_result(run_id) if run_id else None
        if not cached or not cached.get("interview_rows"):
            raise HTTPException(409, "nothing cached to rewrite")
        led.touch(run_id, now())
        return {"run_id": run_id, "write": True, **cached}

    try:
        sub = q.load(submission_id)
        sha = sub.content_sha256
    except UnsupportedSource as exc:
        sub, sha = None, f"unreadable:{submission_id}:{ref.tree_sha}"
        load_error = exc
    claim = led.claim(submission_id, rev, sha, submission_id, now())
    if claim.action == "duplicate":
        return respond(claim.run_id)
    try:
        if sub is None:
            raise load_error
        result = pipeline.run_submission(sub, now().isoformat())
    except tuple(FAILURES) as exc:
        category, retryable = next(v for k, v in FAILURES.items() if isinstance(exc, k))
        led.fail(claim.run_id, category, str(exc), retryable, now())
        return respond(claim.run_id)
    except Exception as exc:  # unknown bugs: retry, but never leak internals into the sheet
        led.fail(claim.run_id, "internal_error", type(exc).__name__, True, now())
        return respond(claim.run_id)

    a = result.analysis
    rows = {"interview_rows": [a.interview_row], "evidence_rows": a.evidence_rows}
    led.awaiting_write(claim.run_id, rows, interview_id(submission_id), now())
    return respond(claim.run_id, rows, "completed")


@app.post("/runs/{run_id}/verify")
def verify_run(run_id: str, readback: dict = Body(...)):
    """n8n read these rows back FROM THE SHEET. Only an exact match lets the Submission be deleted."""
    led = ledger()
    run = led.get(run_id)
    if run is None:
        raise HTTPException(404, "unknown run")
    expected = led.cached_result(run_id)
    if expected is None:
        return {"run_id": run_id, "verified": run["verified_at"] is not None, "problems": [], "note": "already verified"}
    result = verify(expected, readback)
    if not result.ok:
        if expected.get("interview_rows"):
            led.write_failed(run_id, "sheet check failed: " + "; ".join(result.problems[:3]), now())
        return {"run_id": run_id, "verified": False, "problems": result.problems[:20]}
    led.verified(run_id, now())
    purged = False
    if led.purgeable(run["source_file_id"], run["revision_key"]):
        try:
            with _sync_lock:
                purged = queue().purge(run["source_file_id"])
            if purged:
                led.mark_purged(run["source_file_id"], now())
        except QueueUnavailable:
            purged = False  # next trigger's sync retries the purge
    return {"run_id": run_id, "verified": True, "problems": [], "purged": purged}


class WriteFailure(BaseModel):
    message: str = "sheet write failed"


@app.post("/runs/{run_id}/write-failed")
def write_failed(run_id: str, body: WriteFailure):
    if ledger().get(run_id) is None:
        raise HTTPException(404, "unknown run")
    ledger().write_failed(run_id, body.message, now())
    return {"run_id": run_id, "status": ledger().get(run_id)["status"]}


@app.get("/health")
def health():
    return {"ok": True, "model": os.environ.get("SLOPE_MODEL", "qwen3:8b"), "queue_error": _last_queue_error}


@app.post("/run-now")
def run_now():
    hook = os.environ.get("SLOPE_RUN_NOW_URL")
    if not hook:
        raise HTTPException(503, "SLOPE_RUN_NOW_URL is not set (the n8n Run now webhook)")
    try:
        httpx.post(hook, timeout=10)
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"n8n did not answer: {type(exc).__name__}") from exc
    return RedirectResponse("/", status_code=303)


@app.get("/", response_class=HTMLResponse)
def status_page():
    rows = "".join(
        "<tr>" + "".join(f"<td>{html.escape(str(r.get(c) or ''))}</td>" for c in
                         ("updated_at", "source_name", "status", "attempt_count", "verified_at", "purged_at", "error_message"))
        + "</tr>" for r in ledger().recent())
    warn = f"<p><b>Queue problem:</b> {html.escape(_last_queue_error)}</p>" if _last_queue_error else ""
    return f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>SlopeCycle interview agent</title>
<style>body{{font:15px system-ui;margin:16px;background:#fff;color:#111}}table{{border-collapse:collapse;width:100%}}
td,th{{border-bottom:1px solid #ddd;padding:6px;text-align:left;font-size:13px}}button{{font-size:15px;padding:8px 14px}}
@media (prefers-color-scheme:dark){{body{{background:#111;color:#eee}}td,th{{border-color:#333}}}}</style>
<h1>SlopeCycle interview agent</h1>
<form method=post action=/run-now><button>Run now</button></form>{warn}
<p>Recent runs on this Mac. "Verified" means the sheet was read back and matched; "Removed" means the interview's files were then deleted from the queue.</p>
<table><tr><th>Updated</th><th>Submission</th><th>Status</th><th>Attempts</th><th>Verified</th><th>Removed</th><th>Detail</th></tr>{rows}</table>"""
