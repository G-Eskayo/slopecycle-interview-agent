import pytest

from slope_processor.verify import verify

EXPECTED = {
    "interview_rows": [{"interview_id": "INT-1", "number_of_kids_who_ski": 2, "amount_min": 300.5, "kids_ages": "7; 10",
                        "exclude_from_parent_stats": False, "interview_date": "2026-11-02",
                        "concise_summary": "Overview: two kids.\nNot collected in interview: spending.",
                        "respondent_label": "'+1 555", "days_skied_per_season": "Not collected in interview"}],
    "evidence_rows": [{"evidence_id": "INT-1-a-E01", "interview_id": "INT-1", "exact_excerpt": "Two kids."},
                      {"evidence_id": "INT-1-a-E02", "interview_id": "INT-1", "exact_excerpt": "About $300"}],
    "run_log_rows": [{"run_id": "RUN-1", "status": "completed", "attempt_count": 1}],
}


def sheet(**over):
    """What n8n read back from the sheet: everything as text, as the Sheets API returns formatted values."""
    rows = {
        "interviews": [{"interview_id": "INT-1", "number_of_kids_who_ski": "2", "amount_min": "300.5", "kids_ages": "7; 10",
                        "exclude_from_parent_stats": "FALSE", "interview_date": "2026-11-02",
                        "concise_summary": "Overview: two kids.\nNot collected in interview: spending.",
                        "respondent_label": "+1 555", "days_skied_per_season": "Not collected in interview",
                        "founder_notes": "added by a person"}],
        "evidence": [{"evidence_id": "INT-1-a-E01", "interview_id": "INT-1", "exact_excerpt": "Two kids."},
                     {"evidence_id": "INT-1-a-E02", "interview_id": "INT-1", "exact_excerpt": "About $300"},
                     {"evidence_id": "INT-1-OLD-E01", "interview_id": "INT-1", "exact_excerpt": "older revision"}],
        "run_log": [{"run_id": "RUN-1", "status": "completed", "attempt_count": "1"}],
    }
    rows.update(over)
    return rows


def test_exact_readback_verifies():
    r = verify(EXPECTED, sheet())
    assert r.ok, r.problems


def test_extra_human_columns_and_extra_rows_are_fine():
    assert verify(EXPECTED, sheet()).ok  # founder_notes and an old-revision evidence row present


def test_missing_interview_row_fails():
    r = verify(EXPECTED, sheet(interviews=[]))
    assert not r.ok and "INT-1" in r.problems[0]


def test_one_missing_evidence_quote_fails():
    rows = sheet()
    rows["evidence"] = rows["evidence"][:1]
    r = verify(EXPECTED, rows)
    assert not r.ok and "INT-1-a-E02" in " ".join(r.problems)


def test_a_cell_that_did_not_save_fails():
    rows = sheet()
    rows["interviews"][0]["concise_summary"] = ""
    r = verify(EXPECTED, rows)
    assert not r.ok and "concise_summary" in " ".join(r.problems)


def test_a_missing_column_fails():
    rows = sheet()
    del rows["interviews"][0]["kids_ages"]
    r = verify(EXPECTED, rows)
    assert not r.ok and "kids_ages" in " ".join(r.problems)


def test_a_changed_value_fails():
    rows = sheet()
    rows["interviews"][0]["number_of_kids_who_ski"] = "3"
    assert not verify(EXPECTED, rows).ok


def test_truncated_long_text_fails():
    exp = {"interview_rows": [{"interview_id": "INT-1", "concise_summary": "x" * 60_000}], "evidence_rows": [], "run_log_rows": []}
    got = {"interviews": [{"interview_id": "INT-1", "concise_summary": "x" * 50_000}], "evidence": [], "run_log": []}
    assert not verify(exp, got).ok


def test_duplicate_rows_for_one_key_fail():
    rows = sheet()
    rows["interviews"] = rows["interviews"] * 2
    r = verify(EXPECTED, rows)
    assert not r.ok and "more than once" in " ".join(r.problems)


@pytest.mark.parametrize("sent,read", [(150, "150"), (150, "150.00"), (0.5, "0.5"), (True, "TRUE"), (False, "false"),
                                       ("'=1+1", "=1+1"), ("'=1+1", "'=1+1"), ("a\nb", "a\r\nb"), ("", ""), (None, "")])
def test_cell_normalisation(sent, read):
    exp = {"interview_rows": [{"interview_id": "I", "c": sent}], "evidence_rows": [], "run_log_rows": []}
    assert verify(exp, {"interviews": [{"interview_id": "I", "c": read}], "evidence": [], "run_log": []}).ok


def test_nothing_read_back_at_all_fails():
    assert not verify(EXPECTED, {}).ok


def test_garbage_readback_does_not_crash():
    r = verify(EXPECTED, {"interviews": "nope", "evidence": [None, 3], "run_log": [{"x": 1}]})
    assert not r.ok
