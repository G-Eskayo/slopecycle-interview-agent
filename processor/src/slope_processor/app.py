"""HTTP surface n8n calls. Every response carries ready-to-upsert rows so n8n never decides anything."""

from __future__ import annotations

import hashlib
import html
import os
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

from . import pipeline
from .extract import ModelOutputInvalid, ModelUnavailable
from .ledger import Ledger, sanitize
from .sources import UnsupportedSource, classify
from .validate import NothingExtracted, SourceMeta, _short, escape_cell, interview_id

RUN_LOG_COLUMNS = ["run_id", "source_file_id", "source_name", "source_revision", "status", "attempt_count",
                   "started_at", "completed_at", "output_record_key", "error_category", "error_message"]
TRANSCRIPT_COLUMNS = ["line_id", "interview_id", "source_revision", "line", "timestamp", "text"]

FAILURES = {
    UnsupportedSource: ("unsupported_or_unreadable", False),
    NothingExtracted: ("nothing_extracted", False),
    ModelUnavailable: ("model_unavailable", True),
    ModelOutputInvalid: ("model_output_invalid", True),
    pipeline.TranscriptionFailed: ("transcription_failed", True),
}
STATUS_LABEL = {"claimed": "running", "awaiting_write": "completed", "completed": "completed", "retry": "failed (will retry)",
                "failed": "failed", "duplicate": "duplicate (skipped)"}


def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def data_dir() -> Path:
    d = Path(os.environ.get("SLOPE_DATA_DIR", Path.home() / "Library/Application Support/slope-processor"))
    d.mkdir(parents=True, exist_ok=True)
    return d


app = FastAPI(title="SlopeCycle interview processor")
_ledger: Ledger | None = None


def ledger() -> Ledger:
    global _ledger
    if _ledger is None:
        _ledger = Ledger(data_dir() / "runs.sqlite3")
    return _ledger


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
    return {k: escape_cell(row[k]) for k in RUN_LOG_COLUMNS}


def _cells(rows: list[dict]) -> list[dict]:
    # n8n's append-or-update skips null values, which would leave a stale answer in place when a revised Source no
    # longer states it. An empty string clears the cell.
    return [{k: "" if v is None else v for k, v in r.items()} for r in rows]


def response(run_id: str, result: dict | None = None, final_status: str | None = None) -> dict:
    result = {k: _cells(v) for k, v in (result or {}).items()}
    return {
        "run_id": run_id,
        "write": bool(result.get("interview_rows")),
        "interview_rows": result.get("interview_rows", []),
        "evidence_rows": result.get("evidence_rows", []),
        "transcript_rows": result.get("transcript_rows", []),
        "run_log_rows": _cells([run_log_row(run_id, final_status)]),
    }


class PlanRequest(BaseModel):
    files: list[dict]


@app.post("/plan")
def plan(req: PlanRequest):
    return {"todo": ledger().plan(req.files, now())}


@app.post("/process")
def process(
    file_id: str = Form(...), name: str = Form(...), mime_type: str = Form(...), revision_key: str = Form(...),
    action: str = Form("process"), url: str = Form(""), submitted_by: str = Form(""),
    file: UploadFile | None = File(None),
):
    led = ledger()
    if action == "rewrite":
        rid = led.plan([{"id": file_id, "name": name, "mimeType": mime_type, **_rev_fields(revision_key)}], now())
        run_id = next((t["run_id"] for t in rid if t["action"] == "rewrite"), None)
        cached = led.cached_result(run_id) if run_id else None
        if not cached:
            raise HTTPException(409, "nothing cached to rewrite")
        led.touch(run_id, now())
        return response(run_id, cached, "completed")

    data = file.file.read() if file is not None else b""
    sha = hashlib.sha256(data or f"{file_id}|{revision_key}".encode()).hexdigest()
    claim = led.claim(file_id, revision_key, sha, name, now())
    if claim.action == "duplicate":
        return response(claim.run_id)

    kind = classify(name, mime_type)
    meta = SourceMeta(file_id=file_id, file_name=name, url=url, revision_key=revision_key, submitted_by=submitted_by or None)
    try:
        if action == "reject":
            raise UnsupportedSource(f"{kind.value} files are not supported (supported: Google Docs, .txt, .md, .docx, audio)")
        if not data:
            raise UnsupportedSource("file was empty or could not be downloaded")
        result = pipeline.run(data, kind, meta, now().isoformat())
    except tuple(FAILURES) as exc:
        category, retryable = next(v for k, v in FAILURES.items() if isinstance(exc, k))
        led.fail(claim.run_id, category, str(exc), retryable, now())
        return response(claim.run_id)
    except Exception as exc:  # unknown bugs: retry, but never leak internals into the sheet
        led.fail(claim.run_id, "internal_error", type(exc).__name__, True, now())
        return response(claim.run_id)

    a = result.analysis
    iid = interview_id(file_id)
    rows = {
        "interview_rows": [a.interview_row],
        "evidence_rows": a.evidence_rows,
        "transcript_rows": [
            {k: escape_cell(v) for k, v in {
                "line_id": f"{iid}-{_short(revision_key)}-L{l.number:04d}", "interview_id": iid,
                "source_revision": revision_key, "line": l.number, "timestamp": l.timestamp, "text": l.text}.items()}
            for l in result.transcript_lines or []
        ],
    }
    led.awaiting_write(claim.run_id, rows, iid, now())
    return response(claim.run_id, rows, "completed")


def _rev_fields(rev: str) -> dict:
    kind, _, value = rev.partition(":")
    return {"md5": {"md5Checksum": value}, "v": {"version": value}}.get(kind, {"modifiedTime": value})


class WriteFailure(BaseModel):
    message: str = "sheet write failed"


@app.post("/runs/{run_id}/complete")
def complete(run_id: str):
    if ledger().get(run_id) is None:
        raise HTTPException(404, "unknown run")
    return {"run_id": run_id, "completed": ledger().complete(run_id, now())}


@app.post("/runs/{run_id}/write-failed")
def write_failed(run_id: str, body: WriteFailure):
    ledger().write_failed(run_id, body.message, now())
    return {"run_id": run_id, "status": ledger().get(run_id)["status"]}


@app.get("/health")
def health():
    return {"ok": True, "model": os.environ.get("SLOPE_MODEL", "qwen3:8b")}


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
                         ("updated_at", "source_name", "status", "attempt_count", "output_record_key", "error_category", "error_message"))
        + "</tr>" for r in ledger().recent())
    return f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>SlopeCycle interview agent</title>
<style>body{{font:15px system-ui;margin:16px;background:#fff;color:#111}}table{{border-collapse:collapse;width:100%}}
td,th{{border-bottom:1px solid #ddd;padding:6px;text-align:left;font-size:13px}}button{{font-size:15px;padding:8px 14px}}
@media (prefers-color-scheme:dark){{body{{background:#111;color:#eee}}td,th{{border-color:#333}}}}</style>
<h1>SlopeCycle interview agent</h1>
<form method=post action=/run-now><button>Run now</button></form>
<p>Recent runs on this Mac (the Run Log tab in the sheet has the same information).</p>
<table><tr><th>Updated</th><th>Source</th><th>Status</th><th>Attempts</th><th>Interview</th><th>Error</th><th>Detail</th></tr>{rows}</table>"""
