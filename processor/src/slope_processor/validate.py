"""Check the model's extraction against the source and build sheet rows. Every rule the spec makes enforceable lives here."""

from __future__ import annotations

import hashlib
import re
import unicodedata
from dataclasses import dataclass, field

from .extract import EXTRACTOR_VERSION, INJECTION
from .sources import Line

WORD_NUMBERS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "both": 2, "a couple": 2,
}


HOUSEHOLD_WORDS = re.compile(r"\b(both|total|altogether|combined|all (of )?(the |my |our )?(kids|children)|for the (kids|two|three))\b", re.I)
PER_CHILD_WORDS = re.compile(r"\b(each|per (kid|child)|a (kid|child)|apiece)\b", re.I)

KEY_FIELDS = ("number_of_kids_who_ski", "spend_raw_text", "willingness_to_rent")
CORE_FIELDS = (
    "interview_date", "interviewer", "number_of_kids_who_ski", "kids_ages", "days_skied_per_season", "gear_sources",
    "replacement_frequency", "main_pain_points", "spend_raw_text", "amount_min", "willingness_to_rent",
)
ENUMS = {
    "interview_type": ({"parent", "expert", "unknown"}, "unknown"),
    "spend_basis": ({"per_child", "household", "unknown"}, None),
    "period": ({"per_season", "per_purchase", "per_year", "unknown"}, None),
    "willingness_to_rent": ({"yes", "conditional", "no", "undecided"}, None),
}
EVIDENCE_TYPES = {"respondent_statement", "interviewer_note", "expert_opinion", "interviewer_statement"}
STR_FIELDS = (
    "interview_date", "interviewer", "respondent_label", "city_state", "days_skied_per_season", "family_skiing_context",
    "secondhand_or_hand_me_downs", "replacement_frequency", "replacement_cause", "hardest_part", "spend_raw_text",
    "currency", "price_reaction", "overview", "possible_implication",
)
LIST_FIELDS = (
    "gear_sources", "purchase_priorities", "main_pain_points", "current_approach_likes", "current_approach_dislikes",
    "included_items", "rental_conditions", "objections", "supported_hypotheses", "challenged_hypotheses",
    "unanswered_questions", "suggested_followups", "conflicting_statements",
)

INTERVIEW_COLUMNS = [
    "interview_id", "source_file_id", "source_name", "source_url", "source_version_or_hash", "interview_date",
    "processed_at", "interviewer", "submitted_by", "interview_type", "exclude_from_parent_stats", "respondent_label",
    "city_state", "parent_age", "number_of_kids_who_ski", "kids_ages", "days_skied_per_season", "family_skiing_context",
    "gear_sources", "secondhand_or_hand_me_downs", "replacement_frequency", "replacement_cause", "purchase_priorities",
    "hardest_part", "main_pain_points", "current_approach_likes", "current_approach_dislikes", "spend_raw_text",
    "amount_min", "amount_max", "currency", "spend_basis", "period", "included_items", "derived_per_child_amount",
    "derivation_note", "willingness_to_rent", "rental_conditions", "objections", "price_reaction",
    "concept_exposure_context", "concise_summary", "supported_hypotheses", "challenged_hypotheses",
    "unanswered_questions", "suggested_followups", "possible_implication", "missing_fields", "conflicting_statements",
    "review_reasons", "review_status", "extractor_version",
]
EVIDENCE_COLUMNS = [
    "evidence_id", "interview_id", "source_revision", "field_or_claim", "exact_excerpt", "source_locator",
    "evidence_type", "interpretation_note",
]


class NothingExtracted(Exception):
    """The model found no interview content. The run fails instead of writing an empty-looking interview."""


@dataclass(frozen=True)
class SourceMeta:
    file_id: str
    file_name: str
    url: str
    revision_key: str
    submitted_by: str | None = None


@dataclass
class Analysis:
    interview_row: dict
    evidence_rows: list[dict]
    review_reasons: list[str] = field(default_factory=list)

    @property
    def status(self) -> str:
        return self.interview_row["review_status"]


def interview_id(file_id: str) -> str:
    return "INT-" + hashlib.sha1(file_id.encode()).hexdigest()[:10]


def escape_cell(value):
    if isinstance(value, str) and value[:1] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + value
    return value


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = s.translate(str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-"}))
    return " ".join(s.lower().split())


# In typed notes, only an answer line or a quotation can be the respondent's own words; everything else is the
# interviewer writing. Transcript lines carry a speaker label instead and are left to the model.
RESPONDENT_LINE = re.compile(r"^(a|answer|r|respondent|parent)\s*[:.)-]|^[\"“']|^\[\d\d:\d\d:\d\d\]", re.I)
LINE_PREFIX = re.compile(r"\bL\d+\|\s*")


def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v) if float(v).is_integer() else float(v)
    if isinstance(v, str):
        try:
            return _num(float(v.replace(",", "").replace("$", "").strip()))
        except ValueError:
            return None
    return None


def _fmt(n) -> str:
    return str(int(n)) if float(n).is_integer() else str(n)


def _stated(n, text: str) -> bool:
    plain = text.replace(",", "")
    if re.search(rf"(?<![\d.]){re.escape(_fmt(n))}(?![\d])", plain):
        return True
    words = [w for w, v in WORD_NUMBERS.items() if v == n]
    return any(re.search(rf"\b{w}\b", text, re.I) for w in words)


def analyze(extraction: dict, lines: list[Line], meta: SourceMeta, hypotheses: list[str], processed_at: str) -> Analysis:
    reasons: list[str] = []
    e = dict(extraction) if isinstance(extraction, dict) else {}
    source_text = "\n".join(l.text for l in lines)

    for f in STR_FIELDS:
        v = e.get(f)
        e[f] = v.strip() or None if isinstance(v, str) else None
    for f in LIST_FIELDS:
        v = e.get(f)
        if isinstance(v, str):
            v = [v]
        e[f] = [LINE_PREFIX.sub("", str(x)).strip() for x in v if isinstance(x, (str, int, float)) and str(x).strip()] if isinstance(v, list) else []
    for f, (allowed, fallback) in ENUMS.items():
        v = e.get(f)
        if v is not None and v not in allowed:
            reasons.append(f"model returned an invalid {f} ({str(v)[:30]!r}); treated as not provided")
            v = fallback
        e[f] = v if v is not None else fallback
    for f in ("outerwear_only", "concept_introduced_before_reaction"):
        if not isinstance(e.get(f), bool):
            e[f] = None

    # Numbers: must be numbers, and must appear in the source. Made-up numbers are the most damaging hallucination.
    for f in ("number_of_kids_who_ski", "parent_age", "amount_min", "amount_max"):
        raw = e.get(f)
        n = _num(raw)
        if raw is not None and n is None:
            reasons.append(f"{f} was not a number ({str(raw)[:30]!r}); removed")
        if n is not None and not _stated(n, source_text):
            reasons.append(f"{f} = {_fmt(n)} does not appear in the source; removed")
            n = None
        e[f] = n
    ages = []
    for raw in e.get("kids_ages") or []:
        n = _num(raw)
        if n is None:
            if raw is not None:
                reasons.append(f"kids_ages had a non-number ({str(raw)[:30]!r}); removed")
            continue
        if not _stated(n, source_text):
            reasons.append(f"kid age {_fmt(n)} does not appear in the source; removed")
            continue
        ages.append(n)
    e["kids_ages"] = ages

    if e["spend_raw_text"]:
        hh, pc = bool(HOUSEHOLD_WORDS.search(e["spend_raw_text"])), bool(PER_CHILD_WORDS.search(e["spend_raw_text"]))
        said = "unknown" if hh and pc else "household" if hh else "per_child" if pc else None
        if said and e["spend_basis"] != said:
            reasons.append(f"spending basis: model said {e['spend_basis']}, respondent's words indicate {said}; using {said}")
            e["spend_basis"] = said

    if e["willingness_to_rent"] == "yes" and e["rental_conditions"]:
        e["willingness_to_rent"] = "conditional"
        reasons.append("model said an unconditional yes to renting but listed conditions; recorded as conditional")

    iid = interview_id(meta.file_id)
    evidence_rows, ref_to_id = _verify_evidence(e.get("evidence"), lines, iid, meta.revision_key, reasons,
                                                expert=e["interview_type"] == "expert")

    if not hypotheses:
        e["supported_hypotheses"], e["challenged_hypotheses"] = [], []

    derived, note = _per_child(e)
    if e["spend_raw_text"] and e["outerwear_only"] is not True:
        reasons.append("spending mentioned but the outerwear share is unknown (may include other gear)")
    if e["conflicting_statements"]:
        reasons.append("respondent contradicts themselves: " + "; ".join(e["conflicting_statements"]))
    if INJECTION.search(source_text):
        reasons.append("source contains instructions aimed at the agent; they were ignored, check the extraction")
    missing_key = [f for f in KEY_FIELDS if not e.get(f)]
    if len(missing_key) >= 2:
        reasons.append("incomplete: " + ", ".join(missing_key) + " not provided")

    nothing = not evidence_rows and all(not e.get(f) for f in CORE_FIELDS)
    if nothing:
        raise NothingExtracted("no interview content could be extracted with verifiable evidence")

    missing = [f for f in CORE_FIELDS if not e.get(f)]
    findings = []
    for item in e.get("key_findings") or []:
        if not isinstance(item, dict) or not str(item.get("finding", "")).strip():
            continue
        refs = [ref_to_id[r] for r in item.get("evidence_refs") or [] if r in ref_to_id]
        if not refs:
            reasons.append(f"finding has no verified evidence: {str(item['finding'])[:80]}")
        findings.append((str(item["finding"]).strip(), refs))
    findings = findings[:3]

    status = "Needs review" if reasons else "Auto-accepted"
    exposure = {True: "Concept explained before reaction", False: "Reaction given before concept explained"}.get(
        e["concept_introduced_before_reaction"])
    row = {
        "interview_id": iid,
        "source_file_id": meta.file_id,
        "source_name": meta.file_name,
        "source_url": meta.url,
        "source_version_or_hash": meta.revision_key,
        "processed_at": processed_at,
        "submitted_by": meta.submitted_by,
        "exclude_from_parent_stats": e["interview_type"] != "parent",
        "derived_per_child_amount": derived,
        "derivation_note": note,
        "concept_exposure_context": exposure,
        "concise_summary": _summary(e, findings, missing, bool(hypotheses)),
        "missing_fields": "; ".join(missing),
        "review_reasons": "; ".join(reasons),
        "review_status": status,
        "extractor_version": EXTRACTOR_VERSION,
    }
    for col in INTERVIEW_COLUMNS:
        if col in row:
            continue
        v = e.get(col)
        if col == "kids_ages":
            v = "; ".join(_fmt(a) for a in v)
        elif isinstance(v, list):
            v = "; ".join(v)
        row[col] = v
    row = {col: escape_cell(row[col]) for col in INTERVIEW_COLUMNS}
    return Analysis(row, evidence_rows, reasons)


def _verify_evidence(items, lines: list[Line], iid: str, revision_key: str, reasons: list[str], expert: bool = False):
    rows: list[dict] = []
    ref_to_id: dict[int, str] = {}
    normed = [_norm(l.text) for l in lines]
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict) or not isinstance(item.get("exact_excerpt"), str):
            reasons.append("model returned a malformed evidence item; dropped")
            continue
        item = {**item, "exact_excerpt": LINE_PREFIX.sub("", item["exact_excerpt"])}
        excerpt = _norm(item["exact_excerpt"]).strip(" .,;:!?\"'")
        if len(excerpt) < 3:
            reasons.append("evidence excerpt too short to check; dropped")
            continue
        cited = _num(item.get("line"))
        order = list(range(len(lines)))
        if isinstance(cited, int) and 1 <= cited <= len(lines):
            order.remove(cited - 1)
            order.insert(0, cited - 1)
        hit = next((i for i in order if excerpt in normed[i]), None)
        if hit is None:
            reasons.append(f"evidence excerpt not found in the source; dropped: {item['exact_excerpt'][:80]!r}")
            continue
        etype = item.get("evidence_type") if item.get("evidence_type") in EVIDENCE_TYPES else "unspecified"
        if etype == "respondent_statement" and not RESPONDENT_LINE.search(lines[hit].text):
            etype = "interviewer_note"
        if etype == "respondent_statement" and expert:
            etype = "expert_opinion"  # an expert's words never count as a parent's buying behaviour
        eid = f"{iid}-{_short(revision_key)}-E{len(rows) + 1:02d}"
        ref = _num(item.get("ref"))
        if isinstance(ref, int):
            ref_to_id[ref] = eid
        rows.append({
            "evidence_id": eid,
            "interview_id": iid,
            "source_revision": revision_key,
            "field_or_claim": str(item.get("field_or_claim") or ""),
            "exact_excerpt": item["exact_excerpt"].strip(),
            "source_locator": lines[hit].locator,
            "evidence_type": etype,
            "interpretation_note": item.get("interpretation_note") if isinstance(item.get("interpretation_note"), str) else None,
        })
    return [{c: escape_cell(r[c]) for c in EVIDENCE_COLUMNS} for r in rows], ref_to_id


def _short(revision_key: str) -> str:
    return hashlib.sha1(revision_key.encode()).hexdigest()[:6]


def _per_child(e: dict):
    lo, hi = e["amount_min"], e["amount_max"]
    kids = e["number_of_kids_who_ski"] or (len(e["kids_ages"]) or None)
    if lo is None and hi is None:
        return None, "Not calculated: no amount stated"
    if lo is not None and hi is not None and lo != hi:
        return None, "Not calculated: respondent gave a range, not one amount"
    if e["spend_basis"] == "per_child":
        return None, "Not calculated: respondent stated a per-child amount directly"
    if e["spend_basis"] != "household":
        return None, "Not calculated: spending basis (per child or household) unknown"
    if e["period"] != "per_season":
        return None, "Not calculated: amount is not stated per season"
    if e["outerwear_only"] is not True:
        return None, "Not calculated: unclear whether the amount covers outerwear only"
    if not kids:
        return None, "Not calculated: number of children unknown"
    amount = lo if lo is not None else hi
    per = round(amount / kids, 2)
    per = int(per) if float(per).is_integer() else per
    return per, f"Calculated: household {_fmt(amount)} / {_fmt(kids)} children = household average per child, not what each child received"


HUMAN = {
    "interview_date": "interview date", "interviewer": "interviewer", "number_of_kids_who_ski": "number of kids who ski",
    "kids_ages": "kids' ages", "days_skied_per_season": "days skied per season", "gear_sources": "where gear comes from",
    "replacement_frequency": "how often gear is replaced", "main_pain_points": "pain points",
    "spend_raw_text": "spending", "amount_min": "spending amount", "willingness_to_rent": "reaction to renting",
}


def _summary(e: dict, findings, missing: list[str], have_hypotheses: bool) -> str:
    parts = [f"Overview: {e['overview'] or 'Not provided'}"]
    if findings:
        lines = []
        for i, (text, refs) in enumerate(findings, 1):
            lines.append(f"{i}. {text} [{', '.join(r.rsplit('-', 1)[-1] for r in refs)}]" if refs else f"{i}. {text} (no verified evidence)")
        parts.append("Key findings: " + " ".join(lines))
    if have_hypotheses:
        sup = "; ".join(e["supported_hypotheses"]) or "none"
        cha = "; ".join(e["challenged_hypotheses"]) or "none"
        parts.append(f"Hypotheses: supports {sup}; challenges {cha}.")
    else:
        parts.append("Hypotheses: no team hypothesis list supplied.")
    if missing:
        parts.append("Not provided: " + ", ".join(HUMAN.get(f, f) for f in missing) + ".")
    if e["suggested_followups"]:
        parts.append("Follow-ups: " + " ".join(f"{i}. {q}" for i, q in enumerate(e["suggested_followups"][:3], 1)))
    if e["possible_implication"]:
        parts.append(f"Possible implication (not a decision): {e['possible_implication']}")
    return "\n".join(parts)
