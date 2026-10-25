# Design — SlopeCycle Interview Analyst v1

Spec of record: [spec.md](spec.md). Decisions: [adr/](adr/). Terms: [../CONTEXT.md](../CONTEXT.md).

## Flow

```
 Teammate (any device)          Google Drive                    Processor Mac (Noah's)
 ─────────────────────          ────────────                    ──────────────────────
 upload notes / Doc / audio ──► Inbox folder ◄── list (5 min) ── n8n  Schedule + "Run now"
                                                                  │
                                                                  ├─ POST /plan  ─────► processor  (ledger: what is new/changed/stuck?)
                                                                  ├─ download each todo file
                                                                  ├─ POST /process ───► processor
                                                                  │                       ├ text: Doc / txt / md / docx
                                                                  │                       ├ audio → slope-transcribe (Parakeet Ultra + diarizer)
                                                                  │                       ├ Ollama extract (JSON schema)
                                                                  │                       └ validate, calculate, escape → rows
                                 Transcripts folder ◄── upload ───┤ (audio only)
                                 Interview sheet   ◄── upsert ────┤ Interviews / Evidence / Run Log, keyed
                                                                  └─ POST /runs/{id}/complete ► processor
```

## Components

| Component | Where | Job |
|---|---|---|
| `workflow/` | n8n on the Processor Mac | Schedule, Drive list/download, Sheets upserts, transcript upload |
| `processor/` | Python, `127.0.0.1:8787`, launchd | Ledger (SQLite), extraction, validation, row building |
| `transcriber/` | Swift CLI `slope-transcribe` | Audio file → JSON transcript with speakers and timestamps |
| Ollama | Processor Mac | `qwen3:8b`, local only |

## Run states

`claimed → awaiting_write → completed`, or `failed` (retryable or permanent), or `skipped` (duplicate / unsupported, logged once per revision). A claim is a lease: one older than 30 minutes is treated as abandoned and retried. Max 3 attempts, then permanent failure with the reason in Run Log.

Revision key: Drive `md5Checksum` when present (uploaded files), otherwise Drive `version` (Google Docs). The content SHA-256 is also stored so a re-upload of identical bytes is a duplicate.

## Sources supported in v1

Google Docs (exported as text), `.txt`, `.md`, `.docx`, audio (`.m4a .mp3 .wav .aac .caf .mp4 .mov`). PDFs, images, scans and anything else: a Run Log row saying unsupported, no Interview row.

## Validation rules (code, not prompt)

- Every Evidence excerpt must be found in the source text (whitespace/quote-normalised). Not found → dropped, reason added to `review_reasons`.
- `willingness_to_rent` ∈ yes / conditional / no / undecided / null. "yes" with conditions → conditional + review reason.
- Spending numbers numeric or null. `derived_per_child_amount` computed only when basis = household, period = season, items = outerwear only, and kid count known; otherwise null with a `derivation_note` saying why.
- Expert interviews are flagged `exclude_from_parent_stats`.
- Conflicting statements, unverified excerpts, empty extraction, or instructions-to-the-agent found in the source → `review_status = Needs review`.
- Every text cell starting with `= + - @` (or tab/CR) is prefixed with `'`.
- Unstated → empty in the sheet, "Not provided" in the summary; `missing_fields` lists them.

## Not in v1 (slice 2)

Mapping onto the team's existing interview sheet (not yet seen), preserving founder Overrides across revisions, chunking very long transcripts, trend reports across interviews.
