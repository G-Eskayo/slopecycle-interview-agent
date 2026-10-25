# Tasks — v1 (from design.md)

## Track: processor

- [x] **T1** — Text sources to a validated Interview
  Blocked by: none
  Doc/txt/md/docx bytes → numbered source lines → Ollama extraction → validation → Interview + Evidence rows. Tests cover the spec's happy path, missing data, ambiguous spending, expert interview and malicious-instruction fixtures (model stubbed in unit tests, real model in one opt-in test).
- [x] **T2** — Run ledger and duplicate safety
  Blocked by: T1
  `/plan`, `/process`, `/runs/{id}/complete` on SQLite. Same revision twice → one run; overlapping calls → one claim; stuck awaiting_write → handed back with cached rows; 3 attempts then permanent failure.
- [x] **T3** — Audio sources
  Blocked by: T1, T5
  Audio bytes → `slope-transcribe` → timestamped speaker lines → same extraction path; transcript text returned for upload.

## Track: transcriber

- [x] **T5** — `slope-transcribe` CLI
  Blocked by: none
  FluidAudio Parakeet Ultra + offline diarizer → JSON `{segments:[{speaker,start,end,text}]}`. Tested on a real clip.

## Track: workflow

- [x] **T6** — n8n workflow export
  Blocked by: T2
  Schedule + manual trigger, Drive list/download, processor calls, keyed Sheets upserts, transcript upload, completion callback. Imports into n8n and runs against the processor.
- [ ] **T7** — Real Google Sheets connection test (write, read back, verify) (HITL: needs a Google OAuth client and a test folder + sheet)
  Blocked by: T6
  Real Drive read, real Sheet write, rerun shows dedup, revoked access shows a visible failure.

## Track: handover

- [ ] **T8** — Setup guide, launchd services, sheet template, demo script, test results table, prompt-log template
  Blocked by: T6

## v2: event-driven Git queue (ADR 0005)

- [x] **T9** — Processor reads the queue repo
  Blocked by: none
  `/queue/sync` (fetch + reset, list Submissions, plan) and `/submissions/{id}/process`; meta fields become authoritative facts; notes + recording in one Submission become one Interview. Remove the Drive endpoints.
- [x] **T10** — SlopeCycle Send (Mac menu-bar app)
  Blocked by: none
  The confirmed window: respondent, parent/expert, date, notes box for Wispr, attach recording, Send. Single-commit write via the Git Data API, offline outbox, settings (name, access key in Keychain, queue repo).
- [x] **T11** — Wake trigger on the Processor Mac
  Blocked by: none
  `slope-wake`: fires the n8n run webhook at login and on every wake from sleep, with bounded retries while the network comes up.
- [x] **T12** — n8n workflow v2
  Blocked by: T9
  Triggers: GitHub webhook, Run now / woke up. No schedule, no Drive. Sync → one Submission at a time → Sheets → complete.
- [ ] **T13** — Runner + install + docs v2 (docs and scripts done; first real install on Noah's Mac pending)
  Blocked by: T9–T12
  ngrok (Noah's free static domain, only the webhook path let through), install.sh, Noah and teammate guides, README diagrams.
