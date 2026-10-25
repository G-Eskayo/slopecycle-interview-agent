# n8n workflow: SlopeCycle Interview Agent (v2, event-driven)

`slopecycle-interview-agent.json` is the whole workflow. n8n only does the visible steps (the doorbell, calling the processor, Google Sheets). The processor owns every decision (ADR 0003, 0005, 0006). No node here decides anything the processor did not tell it, and there are no Code nodes.

![The whole workflow](../docs/images/n8n-workflow-full.png)

## What each section does

| # | Section | Nodes | What happens |
|---|---|---|---|
| 1 | The doorbell | `Doorbell rings` | One Webhook, POST `/webhook/slopecycle-run`, "Respond: Immediately". Rung by the GitHub Actions runner after each send, by the wake-from-sleep listener, and by the status page's Run now button. It carries no data. No timer, no Google Drive. |
| 2 | Settings | `Settings` | The only place for `spreadsheet_id` and `processor_url` (default `http://127.0.0.1:8787`). |
| 3 | What is waiting? | `Ask processor what is new`, `One item per submission to handle` | POST `{processor_url}/queue/sync` (no body), then split `todo` into one item per Submission. Nothing waiting: the run ends here. |
| 4 | One at a time | `One submission at a time`, `Process the submission`, `Processor answer` | Batch size 1. POST `/submissions/{file_id}/process` with `{"action": action}`. 60-minute timeout (audio + local model). |
| 5 | Save to the Sheet | `Any evidence quotes?` ... `Save to Run Log tab` | In order: Evidence (key `evidence_id`), Interviews (`interview_id`), Run Log (`run_id`), each Append or Update. An empty list is skipped. The `Get the answer again ...` nodes re-load the processor's answer because Sheets nodes replace the data flowing through. |
| 6 | Read it back | `Read Interview back from sheet`, `Read Evidence back from sheet`, `Read Run Log back from sheet`, their `Collect ...` and `... found` nodes | Get Row(s) from the sheet itself: Interviews where `interview_id` = the row's id, Evidence where `interview_id` = that id (all matches), Run Log where `run_id` = `run_id`. Interview and Evidence reads are skipped when the processor sent no interview row (duplicates, failures); the Run Log read always runs. |
| 7 | Compare | `Put the three tabs together`, `Ask processor to compare with the sheet` | One body `{"interviews": [...], "evidence": [...], "run_log": [...]}` (keys = column headers) goes to POST `/runs/{run_id}/verify`. n8n does nothing with the answer: the processor deletes the Submission only on a perfect match. |
| - | Failures | `Tell processor: sheet failed` | Any Sheets write or read fails (error output): POST `/runs/{run_id}/write-failed` `{"message": ...}`, then the loop moves on. Verify is never called with data that did not come from the sheet. If `Process the submission` or the verify call itself fails, the loop also moves on; the processor still holds the data and offers it again. |

**Nothing is deleted until the sheet is read back and matches** (ADR 0006). The processor remembers exactly what it sent; the only thing that releases a Submission is rows read back from the Google Sheet that match cell for cell.

## Node types and versions

| Node | type | typeVersion |
|---|---|---|
| Doorbell | `n8n-nodes-base.webhook` | 2 |
| Settings, `Get the answer again ...`, `... found`, `Put the three tabs together` | `n8n-nodes-base.set` | 3.4 |
| HTTP Request (x4) | `n8n-nodes-base.httpRequest` | 4.2 |
| `One item per ...` | `n8n-nodes-base.splitOut` | 1 |
| `Collect ... read back` | `n8n-nodes-base.aggregate` | 1 |
| `One submission at a time` | `n8n-nodes-base.splitInBatches` | 3 |
| If (x4) | `n8n-nodes-base.if` | 2.2 |
| Processor answer | `n8n-nodes-base.noOp` | 1 |
| Google Sheets (x6: 3 save, 3 read) | `n8n-nodes-base.googleSheets` | 4.5 |
| Sticky notes (12) | `n8n-nodes-base.stickyNote` | 1 |

All exist in n8n 1.64.3 (installed on this Mac) and in current n8n.

## How to set it up

1. **Sheet.** Create a Google Sheet with three tabs named exactly `Interviews`, `Evidence`, `Run Log`. Import the matching file from `sheet-template/` into row 1 of each. Column order comes from the processor code. Extra columns are fine. Do not apply number or date formatting to the tabs (see RAW below).
2. **Import.** Workflows > Add workflow > `...` > Import from file. (The CLI `import:workflow` wants a JSON array: `python3 -c "import json,sys;print(json.dumps([json.load(open(sys.argv[1]))]))" slopecycle-interview-agent.json > wf-array.json`.)
3. **Settings.** Paste the Sheet id (the long part of the Sheet's URL between `/d/` and `/edit`) into `Settings`.
4. **Google credential.** One Google OAuth2 credential named **SlopeCycle Google** (Sheets API only; Drive is no longer used). Pick it in each of the 6 Google Sheets nodes if n8n has not matched it.
5. **Keep n8n private.** Start n8n with `N8N_LISTEN_ADDRESS=127.0.0.1` so only this Mac can reach the doorbell. If `EXECUTIONS_TIMEOUT` is set, keep it above 3600 seconds.
6. **Activate** after one manual run. The doorbell URL is `http://127.0.0.1:5678/webhook/slopecycle-run` (POST). The processor's Run now button needs `SLOPE_RUN_NOW_URL` set to it.

## Workflow settings (execution data)

Success executions: **not saved**. Manual executions: **not saved**. Error executions: **not saved**. Progress saving: off. Reason: node data in n8n's history would hold full interview rows and quotes, which ADR 0006 says must not linger anywhere. The cost is that a failed run leaves no trace in n8n's Executions list. Failures are visible instead in the processor's status page and Run Log. To debug, temporarily set "Save failed production executions" to "Save" in the workflow settings, reproduce, then turn it off and delete the saved executions.

## How the Sheets nodes behave (read from the n8n 1.64.3 source, and exercised by running the real node code)

- **Cell format (value input mode) = RAW** on all three save nodes (`options.cellFormat: "RAW"`, shown in the UI as "Let n8n format"). The 4.5 default is USER_ENTERED, so it is set explicitly. RAW stores values exactly as sent: `2026-11-02` stays text and reads back identically, and formulas are never evaluated. A formula-looking text keeps the processor's leading `'` visible in the cell; the processor's verify accepts that.
- **Minimise API calls (`useAppend`) = on** for saves: new rows go through Google's append call (a new tab only has 1000 grid rows). Rows that already exist are updated in place by key. Do not leave blank rows between data rows. (The Get Row(s) operation has no such option.)
- **Mapping** is "Map Automatically", match column is the id key, **Extra fields in input = Error** (a renamed header fails loudly and the processor is told `write-failed`). The processor never sends nulls, because append-or-update skips them and would leave a stale value.
- **Get Row(s):** filter column = the key, `combineFilters` AND, **"Return only First Matching Row" = off** (`returnFirstMatch: false`), so Evidence returns every match. Output formatting is set to unformatted values so numbers compare exactly. The node downloads the whole tab and filters in the node, not in Google, so each read costs one Sheets API call whatever the filter. If nothing matches the node would normally output nothing and stop the path, so the read nodes have "Always Output Data" on; the resulting empty item is dropped by the `... found` / `Put the three tabs together` nodes, so a missing row shows up as a missing row, not an empty one.
- n8n's Sheets read adds a `row_number` key; the processor ignores keys it did not send.

## Verified by actually running it

n8n 1.64.3 in an isolated `N8N_USER_FOLDER` on port 5701 (listening on 127.0.0.1 only, `~/.n8n` untouched), the real processor (`uvicorn`, temp data dir), a local bare git repo as the queue, and a fake Ollama returning a valid extraction:

- **Test copy with a fake sheet** (the six Google Sheets nodes swapped for HTTP Request nodes talking to a small in-memory sheet that upserts by key and filters on read; everything else is the real workflow). POST `/webhook/slopecycle-run` answered 200 in about 25 ms and GET returned 404. Two Submissions went through sync, process, save, read-back and verify; each verify body had the shape `{interviews: 1, evidence: 2, run_log: 1}`, the processor answered `verified: true, purged: true`, and the Submissions were gone from the bare repo. A third Submission with the same content (a duplicate, no interview rows) skipped the Evidence/Interviews saves and reads, sent `{"interviews": [], "evidence": [], "run_log": [1 row]}`, and was verified and purged.
- **Dropped row:** the fake sheet lost one Evidence row on read-back. Verify answered `verified: false` ("evidence: row ... not found in the sheet"), both Submissions stayed in the bare repo, and the processor marked the runs `retry`.
- **Real workflow, real Sheets nodes, no credentials:** every Sheets node fails; `write-failed` was POSTed exactly once per run, the processor moved the runs to `retry`, verify was never called, the Submissions stayed, and the loop still processed both.
- **Real Sheets node code** (read and append-or-update from the installed n8n, run in a harness with a mocked Google API and this workflow's real parameters): Get Row(s) returns all matches (including a row with an empty cell), saves are sent with `RAW`, updates go through the update call and new rows through append.

## NOT verified (needs real Google credentials or real data)

- Anything that talks to Google: the real RAW round trip (write, then read back through the Sheets API), the `useAppend` append on a real tab, the key match, and that the `'` prefix and number/boolean cells read back as the processor expects. I read the source but never ran it against Google.
- That n8n matches the name-only `SlopeCycle Google` credential after import (expect to pick it once per Sheets node).
- The real text of a failed Sheets call: in 1.64.3 the error output carries no message, so `write-failed` carries the generic text unless a newer n8n fills `$json.error`.
- The GitHub Actions runner and the wake listener as callers, a real audio job, and the 60-minute timeout.
- Overlapping runs (a send arrives while another run is mid-way). The processor's claims and sync lock prevent duplicate processing, but this was not tested.
