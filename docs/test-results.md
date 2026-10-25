# Test results

Expected results come from the spec (section 9). "Actual" is only what was run. Not prefilled.

## Unit tests (no model, no Google)
- processor: `cd processor && uv run pytest` — 85 passed (2026-10-25)
- transcriber: `cd transcriber && swift test` — 23 passed (2026-10-25)

## Real model, synthetic fixtures (qwen3:8b, dev MacBook, no Google)

| Test | Input | Expected | Actual | Pass? |
|---|---|---|---|---|
| Happy path | `fixtures/happy-path.txt` | Correct record, evidence, summary | 2 kids, ages 7 and 10, $300 household per season, $150 calculated per-child average labelled as calculated, conditional interest, 14 verified evidence rows, Auto-accepted; ~30–110 s | Pass |
| Bad input: empty | `fixtures/empty.txt` | Failed, no interview | Failed: "file is empty or too short", model never called | Pass |
| Bad input: malicious | `fixtures/malicious-instruction.txt` | Instructions ignored | Injected line withheld; "no" recorded; flagged Needs review | Pass (after iteration 2) |
| Bad input: unsupported | PDF | Unsupported status | Run Log "failed / unsupported" (API test with stub model) | Pass (unit) |
| Missing data | `fixtures/missing-data.txt` | Nulls, follow-ups, no invention | Kids, spend, rental all blank; 3 follow-ups asked for them; Needs review "incomplete" | Pass |
| Ambiguous spending | `fixtures/ambiguous-spending.txt` | No outerwear per-child figure | Per-child not calculated; flagged outerwear share unknown | Pass |
| Expert interview | `fixtures/expert-interview.txt` | Labelled expert, excluded from parent stats | interview_type expert, exclude_from_parent_stats TRUE | Pass; evidence now forced to expert_opinion in code (unit test) |
| Conflicting statements | `fixtures/conflicting.txt` | Needs review | Contradiction listed; flagged | Pass |
| Audio | synthetic 2-voice m4a (macOS voices) | Speaker-labelled transcript → record | 8 turns, timestamps; 2 kids, ages 9 and 6, $400, conditional; 80 s total | Pass, with a speaker-boundary slip ("Two of" put on the interviewer's turn) |
| Duplicate trigger | same revision twice, 8 simultaneous claims | One interview, duplicate logged | One claim, 7 duplicates (ledger test); model called once (API test) | Pass (unit) |
| Lost write response | write OK, confirmation lost | Rewrite, no duplicate | Cached rows re-sent to keyed upsert, no re-extraction | Pass (unit) |
| Connection failure | Ollama down; sheet write 403 | Visible, retried, no false completion | "failed (will retry)", backoff 5→10 min, complete refused | Pass (unit) |

## Not yet run (needs the real Google connection)
- Real Drive read and Sheet write from the deployed workflow
- Rerun the same Doc and see one row
- Revoke sheet access mid-run and see the failure + recovery
- Revised source after a founder override (slice 2)
- Real human interview audio (only synthetic voices so far)
