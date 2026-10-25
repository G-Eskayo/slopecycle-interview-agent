import threading
from datetime import datetime, timedelta, timezone

import pytest

from slope_processor.ledger import Ledger, revision_key

T0 = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)


def at(minutes):
    return T0 + timedelta(minutes=minutes)


@pytest.fixture
def ledger(tmp_path):
    return Ledger(tmp_path / "runs.sqlite3")


def f(fid="f1", name="a.txt", mime="text/plain", md5="aaa", version="3"):
    return {"id": fid, "name": name, "mimeType": mime, "md5Checksum": md5, "version": version}


def actions(todo):
    return {t["file_id"]: t["action"] for t in todo}


def test_revision_key_prefers_md5_then_version():
    assert revision_key(f()) == "md5:aaa"
    assert revision_key(f(md5=None)) == "v:3"
    assert revision_key({"id": "x", "modifiedTime": "2026-10-25T10:00:00Z"}) == "mod:2026-10-25T10:00:00Z"


def test_new_files_are_planned_folders_ignored_unsupported_rejected(ledger):
    todo = ledger.plan([f("a"), f("b", "x.pdf", "application/pdf"), f("c", "sub", "application/vnd.google-apps.folder")], at(0))
    assert actions(todo) == {"a": "process", "b": "reject"}


def test_completed_revision_is_not_planned_again(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.awaiting_write(c.run_id, {"rows": 1}, "INT-1", at(1))
    ledger.complete(c.run_id, at(2))
    assert ledger.plan([f()], at(10)) == []


def test_a_new_revision_of_the_same_file_is_planned(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.awaiting_write(c.run_id, {}, "INT-1", at(1))
    ledger.complete(c.run_id, at(2))
    assert actions(ledger.plan([f(md5="bbb")], at(10))) == {"f1": "process"}


def test_same_revision_claimed_twice_gives_one_process_and_one_duplicate(ledger):
    first = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    second = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    assert first.action == "process"
    assert second.action == "duplicate" and second.duplicate_of == first.run_id
    assert second.run_id != first.run_id


def test_simultaneous_claims_from_threads_yield_exactly_one_process(tmp_path):
    path = tmp_path / "runs.sqlite3"
    Ledger(path)
    results, barrier = [], threading.Barrier(8)

    def go():
        barrier.wait()
        results.append(Ledger(path).claim("f1", "md5:aaa", "sha1", "a.txt", at(0)).action)

    threads = [threading.Thread(target=go) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert sorted(results) == ["duplicate"] * 7 + ["process"]


def test_identical_bytes_uploaded_as_a_different_file_is_a_duplicate(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha-same", "a.txt", at(0))
    ledger.awaiting_write(c.run_id, {}, "INT-1", at(1))
    ledger.complete(c.run_id, at(2))
    again = ledger.claim("f2", "md5:aaa", "sha-same", "a copy.txt", at(5))
    assert again.action == "duplicate" and again.duplicate_of == c.run_id


def test_in_progress_claim_is_left_alone_until_its_lease_expires(ledger):
    ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    assert ledger.plan([f()], at(10)) == []
    assert actions(ledger.plan([f()], at(31))) == {"f1": "process"}
    retry = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(31))
    assert retry.action == "process" and retry.attempt == 2


def test_write_whose_confirmation_was_lost_is_rewritten_from_cache_not_reextracted(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.awaiting_write(c.run_id, {"interview_rows": [{"interview_id": "INT-1"}]}, "INT-1", at(1))
    assert ledger.plan([f()], at(2)) == []  # n8n may still be writing
    todo = ledger.plan([f()], at(5))
    assert actions(todo) == {"f1": "rewrite"} and todo[0]["run_id"] == c.run_id
    assert ledger.cached_result(c.run_id) == {"interview_rows": [{"interview_id": "INT-1"}]}


def test_failed_sheet_write_is_retried_with_backoff_from_cache(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.awaiting_write(c.run_id, {"interview_rows": [{"interview_id": "INT-1"}]}, "INT-1", at(1))
    ledger.write_failed(c.run_id, "403 permission denied", at(1))
    assert ledger.plan([f()], at(3)) == []  # backing off
    assert actions(ledger.plan([f()], at(7))) == {"f1": "rewrite"}
    ledger.write_failed(c.run_id, "403 again", at(7))
    assert ledger.plan([f()], at(13)) == []  # backoff doubled
    assert actions(ledger.plan([f()], at(18))) == {"f1": "rewrite"}


def test_retryable_failures_stop_after_three_attempts(ledger):
    for i in range(3):
        c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(i * 100))
        assert c.action == "process", i
        ledger.fail(c.run_id, "model_unavailable", "Ollama down", retryable=True, now=at(i * 100 + 1))
    assert ledger.plan([f()], at(1000)) == []
    assert ledger.get(c.run_id)["status"] == "failed"


def test_permanent_failure_is_not_retried(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.fail(c.run_id, "unsupported", "PDF", retryable=False, now=at(1))
    assert ledger.plan([f()], at(500)) == []


def test_complete_is_idempotent_and_only_from_awaiting_write(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    assert ledger.complete(c.run_id, at(1)) is False  # nothing written yet
    ledger.awaiting_write(c.run_id, {}, "INT-1", at(1))
    assert ledger.complete(c.run_id, at(2)) is True
    assert ledger.complete(c.run_id, at(3)) is True
    assert ledger.get(c.run_id)["status"] == "completed"


def test_error_messages_are_truncated_and_never_hold_secrets(ledger):
    c = ledger.claim("f1", "md5:aaa", "sha1", "a.txt", at(0))
    ledger.fail(c.run_id, "internal", "token=ya29.SECRETSECRET Bearer abc.def " + "x" * 1000, retryable=True, now=at(1))
    msg = ledger.get(c.run_id)["error_message"]
    assert "SECRETSECRET" not in msg and "abc.def" not in msg and len(msg) <= 300



def rows(iid="INT-1"):
    return {"interview_rows": [{"interview_id": iid}], "evidence_rows": [], "run_log_rows": []}


def test_verified_run_forgets_its_interview_content_and_becomes_purgeable(ledger):
    c = ledger.claim("f1", "v:tree1", "sha1", "s", at(0))
    ledger.awaiting_write(c.run_id, rows(), "INT-1", at(1))
    assert ledger.purgeable("f1", "v:tree1") is False  # written is not enough
    ledger.verified(c.run_id, at(2))
    r = ledger.get(c.run_id)
    assert r["status"] == "completed" and r["result_json"] is None and r["content_sha256"] == "sha1"
    assert ledger.purgeable("f1", "v:tree1") is True


def test_failed_runs_are_never_purgeable_even_when_their_log_row_is_verified(ledger):
    c = ledger.claim("f1", "v:tree1", "sha1", "s", at(0))
    ledger.fail(c.run_id, "unsupported_or_unreadable", "bad audio", retryable=False, now=at(1))
    ledger.cache(c.run_id, {"run_log_rows": [{"run_id": c.run_id}]})
    ledger.verified(c.run_id, at(2))
    assert ledger.get(c.run_id)["status"] == "failed"
    assert ledger.purgeable("f1", "v:tree1") is False


def test_copy_of_another_submission_is_purgeable_once_its_log_row_is_verified(ledger):
    a = ledger.claim("f1", "v:t1", "same", "s", at(0))
    ledger.awaiting_write(a.run_id, rows(), "INT-1", at(1))
    dup = ledger.claim("f2", "v:t2", "same", "s", at(2))
    assert dup.action == "duplicate"
    assert ledger.purgeable("f2", "v:t2") is False
    ledger.cache(dup.run_id, {"run_log_rows": [{"run_id": dup.run_id}]})
    ledger.verified(dup.run_id, at(3))
    assert ledger.purgeable("f2", "v:t2") is True
    assert ledger.purgeable("f1", "v:t1") is False  # the original still waits for its own verification


def test_a_concurrent_trigger_duplicate_never_makes_the_original_purgeable(ledger):
    a = ledger.claim("f1", "v:t1", "sha", "s", at(0))
    dup = ledger.claim("f1", "v:t1", "sha", "s", at(0))
    ledger.cache(dup.run_id, {"run_log_rows": []})
    ledger.verified(dup.run_id, at(1))
    assert ledger.purgeable("f1", "v:t1") is False  # the original is still being processed
    assert ledger.get(a.run_id)["status"] == "claimed"


def test_retryable_failure_without_rows_reprocesses_instead_of_rewriting(ledger):
    c = ledger.claim("f1", "v:t1", "sha", "s", at(0))
    ledger.fail(c.run_id, "model_unavailable", "down", retryable=True, now=at(1))
    ledger.cache(c.run_id, {"run_log_rows": [{"run_id": c.run_id}]})
    assert actions(ledger.plan([{"id": "f1", "name": "s", "mimeType": "application/x-slopecycle-submission", "version": "t1"}], at(30))) == {"f1": "process"}


def test_in_flight_tracks_unverified_work(ledger):
    assert ledger.in_flight() is False
    c = ledger.claim("f1", "v:t1", "sha", "s", at(0))
    assert ledger.in_flight() is True
    ledger.awaiting_write(c.run_id, rows(), "INT-1", at(1))
    assert ledger.in_flight() is True
    ledger.verified(c.run_id, at(2))
    assert ledger.in_flight() is False


def test_old_database_without_new_columns_is_upgraded(tmp_path):
    import sqlite3
    path = tmp_path / "old.sqlite3"
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE runs (run_id TEXT PRIMARY KEY, source_file_id TEXT NOT NULL, revision_key TEXT NOT NULL, "
               "content_sha256 TEXT, source_name TEXT, status TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, "
               "write_failures INTEGER NOT NULL DEFAULT 0, started_at TEXT, updated_at TEXT, completed_at TEXT, "
               "next_attempt_at TEXT, output_record_key TEXT, error_category TEXT, error_message TEXT, duplicate_of TEXT, result_json TEXT)")
    db.commit(); db.close()
    led = Ledger(path)
    c = led.claim("f1", "v:t", "s", "n", at(0))
    led.verified(c.run_id, at(1))
