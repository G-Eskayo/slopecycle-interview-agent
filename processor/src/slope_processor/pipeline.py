"""One Source revision in, one Analysis out. No ledger or HTTP here so it can be run and tested on its own."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .extract import OllamaClient, build_messages
from .sources import (Line, SourceKind, UnsupportedSource, classify, lines_from_text, lines_from_transcript,
                      text_from_bytes)
from .validate import Analysis, SourceMeta, analyze

MIN_SOURCE_CHARS = 40


class TranscriptionFailed(Exception):
    """The audio tool failed. Retryable unless the audio itself is unreadable."""


@dataclass
class Result:
    analysis: Analysis
    lines: list[Line]
    transcript_lines: list[Line] | None  # the recording's lines; never stored (ADR 0006)


def transcribe(data: bytes, name: str) -> dict:
    tool = os.environ.get("SLOPE_TRANSCRIBE_BIN", "slope-transcribe")
    extra = ["--asr-dir", os.environ["SLOPE_ASR_DIR"]] if os.environ.get("SLOPE_ASR_DIR") else []
    with tempfile.TemporaryDirectory(prefix="slope-") as tmp:
        src = Path(tmp) / ("audio" + Path(name).suffix.lower())
        src.write_bytes(data)
        out = Path(tmp) / "transcript.json"
        try:
            proc = subprocess.run([tool, str(src), "--out", str(out), *extra], capture_output=True, text=True,
                                  timeout=float(os.environ.get("SLOPE_TRANSCRIBE_TIMEOUT_S", "3600")))
        except FileNotFoundError as exc:
            raise TranscriptionFailed(f"transcriber not installed ({tool})") from exc
        except subprocess.TimeoutExpired as exc:
            raise TranscriptionFailed("transcription timed out") from exc
        if proc.returncode != 0:
            msg = (proc.stderr.strip().splitlines() or ["unknown error"])[-1][:300]
            raise TranscriptionFailed(msg)
        return json.loads(out.read_text())


def source_lines(data: bytes, kind: SourceKind, name: str) -> tuple[list[Line], bool]:
    if kind is SourceKind.AUDIO:
        lines = lines_from_transcript(transcribe(data, name))
        if not lines:
            raise UnsupportedSource("no speech found in the audio")
        return lines, True
    if kind in (SourceKind.TEXT, SourceKind.DOCX):
        lines = lines_from_text(text_from_bytes(data, kind))
        if sum(len(l.text) for l in lines) < MIN_SOURCE_CHARS:
            raise UnsupportedSource("file is empty or too short to be an interview")
        return lines, False
    raise UnsupportedSource(f"{kind.value} files are not supported (supported: Google Docs, .txt, .md, .docx, audio)")


def run(data: bytes, kind: SourceKind, meta: SourceMeta, processed_at: str, client: OllamaClient | None = None,
        hypotheses: list[str] | None = None) -> Result:
    lines, is_audio = source_lines(data, kind, meta.file_name)
    client = client or OllamaClient()
    hyps = hypotheses if hypotheses is not None else load_hypotheses()
    extraction = client.extract(build_messages(lines, meta.file_name, hyps))
    analysis = analyze(extraction, lines, meta, hyps, processed_at)
    return Result(analysis, lines, lines if is_audio else None)


def run_submission(sub, processed_at: str, client: OllamaClient | None = None,
                   hypotheses: list[str] | None = None) -> Result:
    """One Send-app Submission: dictated notes and/or a recording of the same interview, plus the details the
    interviewer typed in (docs/submission-format.md)."""
    from .queue import Submission  # noqa: F401  (type only)

    lines: list[Line] = []
    recording_lines: list[Line] = []
    if sub.notes is not None:
        text = text_from_bytes(sub.notes, SourceKind.TEXT)
        lines += lines_from_text(text, section="notes")
    if sub.recording is not None:
        if classify(sub.recording_name or "", "") is not SourceKind.AUDIO:
            raise UnsupportedSource(f"recording type not supported: {sub.recording_name}")
        transcript = transcribe(sub.recording, sub.recording_name or "recording.m4a")
        recording_lines = lines_from_transcript(transcript, section="recording", start=len(lines) + 1)
        if not recording_lines and not lines:
            raise UnsupportedSource("no speech found in the recording")
        lines += recording_lines
    if sum(len(l.text) for l in lines) < MIN_SOURCE_CHARS:
        raise UnsupportedSource("notes are empty or too short to be an interview")

    m = sub.meta
    facts = {"interview_type": m.get("interview_type"), "interview_date": m.get("interview_date"),
             "interviewer": m.get("interviewer"), "respondent_label": m.get("respondent_label")}
    meta = SourceMeta(file_id=sub.submission_id, file_name=sub.submission_id, url="",
                      revision_key=f"tree:{sub.submission_id}", submitted_by=m.get("interviewer"))
    client = client or OllamaClient()
    hyps = hypotheses if hypotheses is not None else load_hypotheses()
    extraction = client.extract(build_messages(lines, sub.submission_id, hyps, facts))
    analysis = analyze(extraction, lines, meta, hyps, processed_at, facts=facts)
    return Result(analysis, lines, recording_lines or None)


def load_hypotheses() -> list[str]:
    path = os.environ.get("SLOPE_HYPOTHESES_FILE")
    if not path or not Path(path).exists():
        return []
    return [l.strip().lstrip("-* ").strip() for l in Path(path).read_text().splitlines() if l.strip() and not l.startswith("#")]
