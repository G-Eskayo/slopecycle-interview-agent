"""The private queue repo, as the Processor Mac sees it: a clone it fetches on every trigger and never commits to.
Layout and meta.json rules: docs/submission-format.md."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .sources import UnsupportedSource

ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{6}Z-[0-9a-f]{8}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MAX_BYTES = 100 * 1024 * 1024


class QueueUnavailable(Exception):
    """GitHub or the clone could not be reached/updated. Retryable; the message is safe to show."""


@dataclass(frozen=True)
class SubmissionRef:
    submission_id: str
    tree_sha: str


@dataclass(frozen=True)
class Submission:
    submission_id: str
    meta: dict
    notes: bytes | None
    recording: bytes | None
    recording_name: str | None

    @property
    def content_sha256(self) -> str:
        h = hashlib.sha256()
        h.update(hashlib.sha256(self.notes or b"").digest())
        h.update(hashlib.sha256(self.recording or b"").digest())
        return h.hexdigest()


class QueueRepo:
    def __init__(self, clone_dir: Path, remote_url: str, token: str | None = None):
        self.dir = Path(clone_dir)
        self.remote = remote_url
        self.token = token

    def _git(self, *args: str, cwd: Path | None = None) -> str:
        auth = []
        if self.token and self.remote.startswith("https://"):
            basic = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
            auth = ["-c", f"http.extraHeader=Authorization: Basic {basic}"]  # per command; never stored in .git/config
        try:
            proc = subprocess.run(["git", *auth, *args], cwd=cwd or self.dir, capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise QueueUnavailable(f"git {args[0]} failed: {type(exc).__name__}") from exc
        if proc.returncode != 0:
            last = (proc.stderr.strip().splitlines() or ["unknown error"])[-1]
            raise QueueUnavailable(f"git {args[0]} failed: {last.replace(self.token or '\0', '[redacted]')[:200]}")
        return proc.stdout

    def sync(self) -> str:
        """Bring the clone exactly to the remote's main. Returns the commit id."""
        if not (self.dir / ".git").exists():
            self.dir.parent.mkdir(parents=True, exist_ok=True)
            self._git("clone", "--quiet", "--branch", "main", self.remote, str(self.dir), cwd=self.dir.parent)
        else:
            self._git("fetch", "--quiet", "origin", "main")
            self._git("reset", "--quiet", "--hard", "origin/main")
        return self._git("rev-parse", "HEAD").strip()

    def _commit_env(self) -> list[str]:
        return ["-c", "user.name=SlopeCycle processor", "-c", "user.email=processor@slopecycle.invalid"]

    def purge(self, submission_id: str, attempts: int = 5) -> bool:
        """Delete one Submission folder from main. Call ONLY after the sheet was verified. True once it's gone."""
        if not ID_RE.match(submission_id):
            raise ValueError("refusing to purge a path that is not a submission id")
        for _ in range(attempts):
            self.sync()
            if not (self.dir / "submissions" / submission_id).exists():
                return True
            self._git("rm", "-r", "--quiet", f"submissions/{submission_id}")
            self._git(*self._commit_env(), "commit", "--quiet", "-m", f"Purge {submission_id} after sheet verified [skip ci]")
            try:
                self._git("push", "--quiet", "origin", "HEAD:main")
                return True
            except QueueUnavailable:
                continue  # someone sent at the same moment; start again from the new main
        return False

    def compact(self) -> bool:
        """Replace history with one commit holding the current tree, so purged recordings stop taking space.
        Only when no Submissions remain. --force-with-lease: a Submission sent meanwhile makes this a no-op."""
        head = self.sync()
        if self.submissions():
            return False
        if self._git("rev-list", "--count", "HEAD").strip() == "1":
            return True  # already a single commit
        tree = self._git("rev-parse", "HEAD^{tree}").strip()
        new = self._git(*self._commit_env(), "commit-tree", tree, "-m", "Queue compacted: processed interviews removed [skip ci]").strip()
        try:
            self._git("push", "--quiet", f"--force-with-lease=main:{head}", "origin", f"{new}:main")
        except QueueUnavailable:
            return False
        self._git("reset", "--quiet", "--hard", new)
        self._git("fetch", "--quiet", "origin", "main")
        self._git("reflog", "expire", "--expire=now", "--all")
        self._git("gc", "--quiet", "--prune=now")
        return True

    def submissions(self) -> list[SubmissionRef]:
        try:
            out = self._git("ls-tree", "HEAD", "submissions/")
        except QueueUnavailable:
            return []  # empty repo or no submissions folder yet
        refs = []
        for line in out.splitlines():
            info, _, path = line.partition("\t")
            mode, kind, sha = info.split()
            name = path.rsplit("/", 1)[-1]
            if kind == "tree":
                refs.append(SubmissionRef(name, sha))
        return sorted(refs, key=lambda r: r.submission_id)

    def load(self, submission_id: str) -> Submission:
        if not ID_RE.match(submission_id):
            raise UnsupportedSource(f"not a valid submission folder name: {submission_id[:60]}")
        folder = self.dir / "submissions" / submission_id
        meta = _read_meta(folder)
        notes = _read_named(folder, meta.get("notes_file"), meta.get("notes_sha256"), "notes")
        recording = _read_named(folder, meta.get("recording_file"), meta.get("recording_sha256"), "recording")
        if notes is None and recording is None:
            raise UnsupportedSource("submission has neither notes nor a recording")
        return Submission(submission_id, meta, notes, recording, meta.get("recording_file") if recording else None)


def _read_meta(folder: Path) -> dict:
    path = folder / "meta.json"
    if not path.exists():
        raise UnsupportedSource("submission is missing meta.json")
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise UnsupportedSource("meta.json is not valid JSON") from exc
    if not isinstance(meta, dict) or meta.get("format") != 1:
        raise UnsupportedSource(f"unsupported submission format {meta.get('format') if isinstance(meta, dict) else '?'}")
    if meta.get("interview_type") not in ("parent", "expert"):
        raise UnsupportedSource("meta.json interview_type must be parent or expert")
    if meta.get("interview_date") is not None and not DATE_RE.match(str(meta["interview_date"])):
        raise UnsupportedSource("meta.json interview_date must be YYYY-MM-DD")
    if folder.name != meta.get("submission_id"):
        raise UnsupportedSource("meta.json submission_id does not match its folder")
    return meta


def _read_named(folder: Path, name, expected_sha, what: str) -> bytes | None:
    if not name:
        return None
    if "/" in str(name) or str(name).startswith("."):
        raise UnsupportedSource(f"{what} file name is not allowed: {str(name)[:60]}")
    path = folder / str(name)
    if not path.is_file():
        raise UnsupportedSource(f"{what} file {name} listed in meta.json is missing")
    if path.stat().st_size > MAX_BYTES:
        raise UnsupportedSource(f"{what} file is over 100 MB")
    data = path.read_bytes()
    if expected_sha and hashlib.sha256(data).hexdigest() != expected_sha:
        raise UnsupportedSource(f"{what} file does not match its checksum (incomplete upload?)")
    return data
