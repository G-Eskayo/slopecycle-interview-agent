from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from slope_processor import app as app_module
from slope_processor import pipeline
from slope_processor.extract import ModelUnavailable, OllamaClient

FIXTURES = Path(__file__).parents[2] / "fixtures"

GOOD = {
    "evidence": [{"ref": 1, "field_or_claim": "rental", "exact_excerpt": "I would consider renting if swaps for a bigger size are free mid-season.",
                  "line": 18, "evidence_type": "respondent_statement", "interpretation_note": None}],
    "interview_type": "parent", "overview": "Parent of two.", "key_findings": [{"finding": "Conditional interest", "evidence_refs": [1]}],
    "willingness_to_rent": "conditional", "rental_conditions": ["free swaps"], "conflicting_statements": [],
    "number_of_kids_who_ski": 2, "spend_raw_text": "About $300 for both kids, jackets and pants only.",
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("SLOPE_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(app_module, "_ledger", None)
    calls = {"n": 0}

    def fake_extract(self, messages):
        calls["n"] += 1
        return GOOD

    monkeypatch.setattr(OllamaClient, "extract", fake_extract)
    c = TestClient(app_module.app)
    c.calls = calls
    return c


def post(client, name="happy-path.txt", file_id="f1", rev="md5:aaa", action="process", data=None, mime="text/plain"):
    files = None
    if action == "process":
        files = {"file": (name, data if data is not None else (FIXTURES / name).read_bytes())}
    return client.post("/process", data={"file_id": file_id, "name": name, "mime_type": mime, "revision_key": rev,
                                         "action": action, "url": "https://drive/x"}, files=files).json()


def test_happy_path_returns_rows_and_completes_only_after_callback(client):
    r = post(client)
    assert r["write"] and len(r["interview_rows"]) == 1 and len(r["evidence_rows"]) == 1
    assert r["run_log_rows"][0]["status"] == "completed"
    assert client.app and app_module.ledger().get(r["run_id"])["status"] == "awaiting_write"
    assert client.post(f"/runs/{r['run_id']}/complete").json()["completed"] is True
    assert app_module.ledger().get(r["run_id"])["status"] == "completed"


def test_duplicate_trigger_runs_the_model_once_and_logs_the_duplicate(client):
    first = post(client)
    second = post(client)
    assert client.calls["n"] == 1
    assert second["write"] is False and second["interview_rows"] == []
    assert second["run_log_rows"][0]["status"] == "duplicate (skipped)"
    assert first["run_id"] in second["run_log_rows"][0]["error_message"]


def test_plan_after_completion_is_empty(client):
    r = post(client)
    client.post(f"/runs/{r['run_id']}/complete")
    plan = client.post("/plan", json={"files": [{"id": "f1", "name": "happy-path.txt", "mimeType": "text/plain", "md5Checksum": "aaa"}]}).json()
    assert plan == {"todo": []}


def test_unsupported_file_is_a_visible_failure_with_no_interview(client):
    r = post(client, name="scan.pdf", mime="application/pdf", action="reject")
    assert r["write"] is False
    log = r["run_log_rows"][0]
    assert log["status"] == "failed"
    assert log["error_category"] == "unsupported_or_unreadable"
    assert "not supported" in log["error_message"]
    assert client.calls["n"] == 0


def test_empty_file_fails_without_calling_the_model(client):
    r = post(client, name="empty.txt")
    assert r["write"] is False and r["run_log_rows"][0]["status"] == "failed"
    assert client.calls["n"] == 0


def test_model_down_is_retryable_and_not_a_false_completion(client, monkeypatch):
    def down(self, messages):
        raise ModelUnavailable("Ollama not reachable")

    monkeypatch.setattr(OllamaClient, "extract", down)
    r = post(client)
    assert r["write"] is False
    assert r["run_log_rows"][0]["status"] == "failed (will retry)"
    assert client.post(f"/runs/{r['run_id']}/complete").json()["completed"] is False


def test_lost_write_confirmation_is_rewritten_from_cache(client, monkeypatch):
    r = post(client)
    led = app_module.ledger()
    led.write_failed(r["run_id"], "timeout", app_module.now().replace(year=2000))  # backoff long expired
    again = post(client, action="rewrite")
    assert again["interview_rows"] == r["interview_rows"]
    assert client.calls["n"] == 1  # not re-extracted
    assert client.post(f"/runs/{r['run_id']}/complete").json()["completed"] is True


def test_unknown_bug_does_not_leak_details(client, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("secret path /Users/noah/token.json")

    monkeypatch.setattr(pipeline, "run", boom)
    r = post(client)
    assert "token.json" not in str(r) and r["run_log_rows"][0]["error_message"] == "RuntimeError"


def test_audio_returns_transcript_rows(client, monkeypatch):
    monkeypatch.setattr(pipeline, "transcribe", lambda data, name: {"segments": [
        {"speaker": "S1", "start": 1, "end": 2, "text": "Would you rent?"},
        {"speaker": "S2", "start": 2, "end": 9, "text": "I would consider renting if swaps for a bigger size are free mid-season."}]})
    r = post(client, name="call.m4a", mime="audio/x-m4a", data=b"fake-audio")
    assert [t["line"] for t in r["transcript_rows"]] == [1, 2]
    assert r["transcript_rows"][1]["timestamp"] == "00:00:02"
    assert r["evidence_rows"][0]["source_locator"] == "line 2 (00:00:02)"


def test_status_page_renders(client):
    post(client)
    page = client.get("/").text
    assert "Run now" in page and "happy-path.txt" in page


def test_no_nulls_reach_the_sheet_so_revisions_clear_stale_cells(client):
    r = post(client)
    for key in ("interview_rows", "evidence_rows", "run_log_rows"):
        for row in r[key]:
            assert None not in row.values(), key
    assert r["interview_rows"][0]["interview_date"] == ""
