# Design — SlopeCycle Interview Analyst (v2, event-driven)

Spec of record: [spec.md](spec.md). Decisions: [adr/](adr/) (0005 and 0006 define v2). Terms: [../CONTEXT.md](../CONTEXT.md). Upload contract: [submission-format.md](submission-format.md).

## Flow

```
 Teammate Mac                     GitHub (private queue repo)             Processor Mac (Noah's)
 ────────────                     ───────────────────────────             ──────────────────────
 SlopeCycle Send ── 1 commit ───► submissions/<id>/{meta,notes,rec}
  (Wispr types in; audio → 16 kHz        │ push event
   mono AAC 24 kbps; offline outbox)    ▼
                                  Actions job on the self-hosted runner ─► curl 127.0.0.1:5678/webhook/slopecycle-run
                                                                          ▲  slope-wake (login / wake) rings the same URL
                                                                          │  Run now button rings the same URL
                                                                          n8n
                                                                           ├ POST /queue/sync     (fetch+reset clone, purge verified, compact, plan)
                                                                           ├ POST /submissions/{id}/process   (transcribe, extract, validate → rows)
                                                                           ├ Sheets append-or-update (RAW): Evidence, Interviews, Run Log
                                                                           ├ Sheets Get Row(s) by key → read-back
                                                                           └ POST /runs/{id}/verify  → match: purge Submission (commit [skip ci])
                                                                                                     → mismatch: keep, write again on next trigger
```

## Components

| Component | Where | Job |
|---|---|---|
| `send-app/` | each teammate's Mac | The approved window; compress; single-commit write via the Git Data API; Keychain; outbox |
| queue repo (from `queue-repo-template/`) | GitHub, private | Holds Submissions only until verified; Actions workflow rings the doorbell, no checkout |
| runner | Processor Mac (launchd, via `scripts/install-runner.sh`) | Outbound connection to GitHub; runs the doorbell job |
| `wake/` (`slope-wake`) | Processor Mac (launchd) | Rings at login and on every wake from sleep, bounded retries |
| `workflow/` | n8n on the Processor Mac, 127.0.0.1 only | Moves data; makes no decisions; no execution history |
| `processor/` | Python, 127.0.0.1:8787 | Ledger, queue clone, extraction, validation, verification, purge, compaction |
| `transcriber/` | Swift CLI | Parakeet Ultra + diarizer → speaker-labelled timestamped lines |
| Ollama | Processor Mac | `qwen3:8b`, local only |

## Run states

`claimed → awaiting_write → completed (verified) → purged`. Also `retry` (bounded backoff, at most 3 extraction attempts; sheet failures retried from cache), `failed` (needs a person; never purged), `duplicate` (logged; a duplicate of *another* Submission is purged once its Run Log row is verified). Verification clears the cached rows; the ledger keeps only fingerprints (content hash, ids, times).

Revision key: the git tree id of the Submission folder. Duplicate key: SHA-256 over the notes and recording bytes.

## Validation rules (code, not prompt)

- Every Evidence excerpt must appear in the source (normalised); otherwise dropped and flagged.
- Numbers (kids, ages, amounts, parent age) must appear in the source as digits or words; otherwise removed and flagged.
- `willingness_to_rent` ∈ yes / conditional / no / undecided; "yes" with conditions becomes conditional.
- Spending basis is checked against the respondent's words ("both", "total" → household; "each", "per kid" → per child).
- `derived_per_child_amount` is computed in code, only for household + per season + outerwear only + known kid count.
- Interviewer-entered details (respondent label, parent/expert, date, interviewer) override the model.
- Notes lines are interviewer notes unless quoted; expert interviews' statements are expert_opinion and excluded from parent stats.
- Lines containing instructions to the agent are withheld from the model and the row is flagged.
- Text starting with `= + - @` is prefixed with `'`; Sheets writes are RAW, so nothing is evaluated.
- Unanswered interview fields read "Not collected in interview" in the sheet.

## Retention

See ADR 0006: Submissions are deleted only after a cell-by-cell read-back match; the queue's history is replaced with one commit whenever the queue is empty and nothing is in flight (`--force-with-lease`). No transcripts are stored. Failed Submissions stay until a person acts.

## Not in v2

Mapping onto a pre-existing team sheet, founder overrides across revisions (Submissions are immutable; a correction is a new Send), trend reports across interviews.
