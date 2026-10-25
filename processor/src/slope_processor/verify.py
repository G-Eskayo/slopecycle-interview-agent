"""The guardrail before anything is deleted: every cell we sent must be in the sheet, read back from the sheet."""

from __future__ import annotations

from dataclasses import dataclass, field

TABS = (("interview_rows", "interviews", "interview_id"), ("evidence_rows", "evidence", "evidence_id"),
        ("run_log_rows", "run_log", "run_id"))


@dataclass
class Verification:
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems


def _norm(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v))
    s = str(v).replace("\r\n", "\n").strip()
    if s.lower() in ("true", "false"):
        return s.lower()
    try:
        return repr(float(s.replace(",", ""))) if s and s.lstrip("-+").replace(".", "", 1).replace(",", "").isdigit() else s
    except ValueError:
        return s


def _same(sent, read) -> bool:
    a, b = _norm(sent), _norm(read)
    if a == b:
        return True
    # USER_ENTERED hides the apostrophe that stops text being read as a formula; RAW keeps it.
    return isinstance(sent, str) and sent.startswith("'") and _norm(sent[1:]) == b


def verify(expected: dict, readback: dict) -> Verification:
    v = Verification()
    readback = readback if isinstance(readback, dict) else {}
    for sent_key, read_key, id_col in TABS:
        rows = readback.get(read_key)
        rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
        by_id: dict[str, list[dict]] = {}
        for r in rows:
            by_id.setdefault(str(r.get(id_col, "")), []).append(r)
        for want in expected.get(sent_key, []):
            key = str(want[id_col])
            found = by_id.get(key, [])
            if not found:
                v.problems.append(f"{read_key}: row {key} not found in the sheet")
                continue
            if len(found) > 1:
                v.problems.append(f"{read_key}: row {key} appears more than once")
                continue
            got = found[0]
            for col, value in want.items():
                if col not in got:
                    v.problems.append(f"{read_key} {key}: column {col} missing in the sheet")
                elif not _same(value, got[col]):
                    v.problems.append(f"{read_key} {key}: {col} did not save correctly")
    return v
