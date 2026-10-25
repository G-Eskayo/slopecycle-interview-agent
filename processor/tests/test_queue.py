import hashlib
import json
import subprocess
from pathlib import Path

import pytest

from slope_processor.queue import QueueRepo, QueueUnavailable
from slope_processor.sources import UnsupportedSource

SID = "2026-11-02T183005Z-3f9a1c2e"


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


@pytest.fixture
def remote(tmp_path):
    """A real bare repo standing in for GitHub, plus a working copy that plays the Send app."""
    bare = tmp_path / "queue.git"
    subprocess.run(["git", "init", "--quiet", "--bare", "-b", "main", str(bare)], check=True)
    work = tmp_path / "sender"
    subprocess.run(["git", "clone", "--quiet", str(bare), str(work)], check=True, capture_output=True)
    git(work, "config", "user.email", "t@example.com")
    git(work, "config", "user.name", "t")
    (work / "README.md").write_text("queue\n")
    git(work, "add", "-A")
    git(work, "commit", "--quiet", "-m", "init")
    git(work, "push", "--quiet", "origin", "main")
    return bare, work


def send(work, sid=SID, notes=b"SYNTHETIC TEST DATA. Two kids, 8 and 11.", recording=None, **meta_over):
    folder = work / "submissions" / sid
    folder.mkdir(parents=True)
    meta = {"format": 1, "submission_id": sid, "sent_at": "2026-11-02T18:30:05Z", "interviewer": "Alex",
            "respondent_label": "P-07", "interview_type": "parent", "interview_date": "2026-11-02",
            "notes_file": None, "recording_file": None, "notes_sha256": None, "recording_sha256": None, "app_version": "1.0.0"}
    if notes is not None:
        (folder / "notes.txt").write_bytes(notes)
        meta.update(notes_file="notes.txt", notes_sha256=hashlib.sha256(notes).hexdigest())
    if recording is not None:
        (folder / "recording.m4a").write_bytes(recording)
        meta.update(recording_file="recording.m4a", recording_sha256=hashlib.sha256(recording).hexdigest())
    meta.update(meta_over)
    (folder / "meta.json").write_text(json.dumps(meta))
    git(work, "add", "-A")
    git(work, "commit", "--quiet", "-m", f"Submission {sid}")
    git(work, "push", "--quiet", "origin", "main")


def repo(tmp_path, remote):
    return QueueRepo(tmp_path / "clone", str(remote[0]))


def test_first_sync_clones_and_lists_nothing(tmp_path, remote):
    q = repo(tmp_path, remote)
    assert len(q.sync()) == 40
    assert q.submissions() == []


def test_sync_sees_new_submissions_and_loads_them(tmp_path, remote):
    q = repo(tmp_path, remote)
    q.sync()
    send(remote[1], recording=b"fake-audio")
    q.sync()
    [ref] = q.submissions()
    assert ref.submission_id == SID and len(ref.tree_sha) == 40
    s = q.load(SID)
    assert s.notes.startswith(b"SYNTHETIC") and s.recording == b"fake-audio" and s.recording_name == "recording.m4a"
    assert s.meta["respondent_label"] == "P-07"


def test_tree_sha_is_a_stable_revision_key(tmp_path, remote):
    q = repo(tmp_path, remote)
    send(remote[1])
    q.sync()
    first = q.submissions()[0].tree_sha
    send(remote[1], sid="2026-11-02T190000Z-00000001")
    q.sync()
    assert {r.submission_id: r.tree_sha for r in q.submissions()}[SID] == first


def test_sync_discards_anything_changed_locally(tmp_path, remote):
    q = repo(tmp_path, remote)
    send(remote[1])
    q.sync()
    (q.dir / "submissions" / SID / "notes.txt").write_text("tampered")
    q.sync()
    assert q.load(SID).notes.startswith(b"SYNTHETIC")


def test_same_content_under_two_ids_has_the_same_content_hash(tmp_path, remote):
    q = repo(tmp_path, remote)
    send(remote[1])
    send(remote[1], sid="2026-11-02T190000Z-00000001", sent_at="2026-11-02T19:00:00Z")
    q.sync()
    a, b = (q.load(r.submission_id) for r in q.submissions())
    assert a.content_sha256 == b.content_sha256


@pytest.mark.parametrize("over,msg", [
    ({"format": 2}, "format"),
    ({"interview_type": "teacher"}, "interview_type"),
    ({"interview_date": "Nov 2"}, "YYYY-MM-DD"),
    ({"submission_id": "2026-11-02T183005Z-ffffffff"}, "does not match"),
    ({"notes_sha256": "0" * 64}, "checksum"),
    ({"notes_file": "../../etc/passwd"}, "not allowed"),
    ({"recording_file": "missing.m4a"}, "missing"),
])
def test_bad_submissions_are_rejected_with_a_readable_reason(tmp_path, remote, over, msg):
    q = repo(tmp_path, remote)
    send(remote[1], **over)
    q.sync()
    with pytest.raises(UnsupportedSource, match=msg):
        q.load(SID)


def test_empty_submission_is_rejected(tmp_path, remote):
    q = repo(tmp_path, remote)
    send(remote[1], notes=None)
    q.sync()
    with pytest.raises(UnsupportedSource, match="neither"):
        q.load(SID)


def test_unreachable_remote_is_retryable_and_hides_the_token(tmp_path):
    q = QueueRepo(tmp_path / "clone", "https://127.0.0.1:9/nobody/queue.git", token="ghp_SECRET123")
    with pytest.raises(QueueUnavailable) as exc:
        q.sync()
    assert "ghp_SECRET123" not in str(exc.value)


def test_folder_names_that_are_not_submission_ids_are_refused(tmp_path, remote):
    q = repo(tmp_path, remote)
    q.sync()
    with pytest.raises(UnsupportedSource, match="not a valid"):
        q.load("../../outside")


def remote_log(bare):
    return subprocess.run(["git", "--git-dir", str(bare), "log", "--format=%s", "main"], capture_output=True, text=True).stdout.split("\n")


def test_purge_removes_only_that_submission_and_marks_skip_ci(tmp_path, remote):
    other = "2026-11-02T190000Z-00000001"
    send(remote[1])
    send(remote[1], sid=other, notes=b"SYNTHETIC TEST DATA other")
    q = repo(tmp_path, remote)
    q.sync()
    assert q.purge(SID) is True
    q.sync()
    assert [r.submission_id for r in q.submissions()] == [other]
    assert "[skip ci]" in remote_log(remote[0])[0]


def test_purge_is_idempotent(tmp_path, remote):
    send(remote[1])
    q = repo(tmp_path, remote)
    assert q.purge(SID) and q.purge(SID)


def test_purge_survives_a_send_landing_at_the_same_moment(tmp_path, remote, monkeypatch):
    send(remote[1])
    q = repo(tmp_path, remote)
    q.sync()
    real_git, pushed = q._git, {"n": 0}

    def racing_git(*args, **kw):
        if args and args[0] == "push" and pushed["n"] == 0:
            pushed["n"] += 1
            subprocess.run(["git", "-C", str(remote[1]), "pull", "--quiet", "--rebase"], check=True, capture_output=True)
            send(remote[1], sid="2026-11-02T190000Z-00000002", notes=b"SYNTHETIC TEST DATA racer")
        return real_git(*args, **kw)

    monkeypatch.setattr(q, "_git", racing_git)
    assert q.purge(SID) is True
    q.sync()
    assert [r.submission_id for r in q.submissions()] == ["2026-11-02T190000Z-00000002"]


def test_purge_refuses_paths_that_are_not_submission_ids(tmp_path, remote):
    q = repo(tmp_path, remote)
    with pytest.raises(ValueError):
        q.purge("../README.md")


def test_compact_rewrites_history_to_one_commit_when_empty(tmp_path, remote):
    send(remote[1], recording=b"x" * 50_000)
    q = repo(tmp_path, remote)
    q.purge(SID)
    assert len([l for l in remote_log(remote[0]) if l]) >= 3
    assert q.compact() is True
    assert [l for l in remote_log(remote[0]) if l] == ["Queue compacted: processed interviews removed [skip ci]"]
    assert (q.dir / "README.md").exists()
    objs = subprocess.run(["git", "-C", str(q.dir), "count-objects", "-v"], capture_output=True, text=True).stdout
    assert "count: 0" in objs  # local clone pruned too


def test_compact_does_nothing_while_submissions_remain(tmp_path, remote):
    send(remote[1])
    q = repo(tmp_path, remote)
    assert q.compact() is False
    q.sync()
    assert [r.submission_id for r in q.submissions()] == [SID]


def test_compact_loses_nothing_if_a_submission_arrives_mid_compaction(tmp_path, remote, monkeypatch):
    send(remote[1])
    q = repo(tmp_path, remote)
    q.purge(SID)
    real_git = q._git

    def racing_git(*args, **kw):
        if args and args[0] == "push" and any(a.startswith("--force-with-lease") for a in args):
            subprocess.run(["git", "-C", str(remote[1]), "pull", "--quiet", "--rebase"], check=True, capture_output=True)
            send(remote[1], sid="2026-11-02T190000Z-00000003", notes=b"SYNTHETIC TEST DATA late")
        return real_git(*args, **kw)

    monkeypatch.setattr(q, "_git", racing_git)
    assert q.compact() is False
    q._git = real_git
    q.sync()
    assert [r.submission_id for r in q.submissions()] == ["2026-11-02T190000Z-00000003"]
