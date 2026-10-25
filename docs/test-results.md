# Test results

Expected results come from the spec (section 9) and ADRs 0005–0006. "Actual" is only what was run. Nothing is prefilled.

## Automated tests (run 2026-10-25)

| Part | Command | Result |
|---|---|---|
| processor | `cd processor && uv run pytest` | 162 passed |
| Send app | `cd send-app && swift test` | 65 passed (60 unit; 5 live tests run separately against a private scratch repo, all passed) |
| transcriber | `cd transcriber && swift test` | 23 passed |
| wake helper | `cd wake && swift test` | 6 passed |

The processor's end-to-end tests drive the real HTTP API, the real ledger and real git (a local repo standing in for GitHub). Only the AI model's answer is stubbed.

## Live runs against real services

| What | How | Result |
|---|---|---|
| Send app → GitHub | 5 live sends to a private scratch repo: notes only, notes + recording, two at the same moment, a resend of an already-sent id | All landed as one commit each; the concurrent pair both landed (one retried); the resend made no new commit. The recording arrived as 16 kHz mono AAC, sha256 matching meta.json |
| Doorbell | Temporary GitHub runner on a dev Mac, pushes to the scratch repo | Every push queued a job that rang the local listener within seconds; a `[skip ci]` commit did not ring; simultaneous sends collapsed to one pending ring |
| Wake helper | Simulated wake event, and a normal start | Rang once each, first attempt |
| Processor ← GitHub | Processor syncing the real scratch repo over HTTPS, real qwen3:8b, real transcriber | 6 Submissions processed and verified (sheet read-back simulated), then deleted from GitHub; 1 recognised as a duplicate of another; a broken folder (no meta.json) failed as "needs a person" and was **kept** |
| History wipe | After the broken folder was removed by hand, one more sync | 18 commits on GitHub became 1; README and workflow kept; nothing from the interviews left on the processor (0 cached rows, no interview text in its files) |
| Audio compression | Real-speech clip at 32 / 24 / 16 kbps through Parakeet Ultra | Identical transcript at all three; 24 kbps chosen (~11 MB/hour) |
| n8n workflow | Isolated n8n with the real processor; Google Sheets replaced by a stand-in sheet | Happy path verified and deleted; duplicate verified and deleted; a dropped row on read-back → not verified, kept; with real Sheets nodes and no credentials → "write-failed" once per run, nothing deleted |

## Spec scenarios (real model, synthetic fixtures)

| Test | Expected | Actual | Pass? |
|---|---|---|---|
| Happy path | Correct record, evidence, summary | 2 kids, ages 7 and 10, $300 household per season, $150 per-child average labelled calculated, conditional interest, Auto-accepted | Pass |
| Bad input: empty / junk | Failed, no interview | "too short" / "not text"; model never called | Pass |
| Bad input: malicious | Instructions ignored | Injected line withheld from the model; "no" recorded; flagged | Pass (after prompt-log iteration 2) |
| Missing data | Nothing invented | Kids, spending, rental all "Not collected in interview"; follow-ups ask for them; Needs review | Pass |
| Ambiguous spending | No outerwear per-child figure | Not calculated; flagged outerwear share unknown | Pass |
| Expert interview | Labelled expert, excluded | expert, excluded from parent stats, evidence typed expert_opinion | Pass |
| Duplicate trigger | One interview | Same content sent twice → one row + a duplicate log line; two triggers at once → one claim | Pass |
| Connection failure | Visible, no false completion, no data loss | Model down → "failed (will retry)"; sheet write/read failure → kept and rewritten from cache; nothing deleted without a read-back match | Pass (unit + n8n stand-in) |
| Audio | Speaker-labelled transcript → record | Synthetic two-voice m4a: 2 kids, ages 9 and 6, $400, conditional; 80 s | Pass, with one speaker-boundary slip on synthetic voices |

## Not yet run

- Real Google Sheets (write, read back, verify) — the first real run on Noah's Mac should be watched.
- `install.sh` and `install-runner.sh` end to end on Noah's Mac (the runner's always-on service mode was not exercised; a foreground runner was).
- The Send app's Keychain, Attach-file panel and offline resend by hand in the GUI (the same code paths are unit-tested).
- Real human interview audio (only synthetic voices and one real single-speaker clip so far).
- Wispr Flow typing into the Send window (system text input, paste and key events were tested in-app).
