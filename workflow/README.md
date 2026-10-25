# n8n workflow: SlopeCycle Interview Agent

`slopecycle-interview-agent.json` is the whole workflow. n8n only does the visible steps (timer, Google Drive, Google Sheets, calling the processor). The processor owns every decision (ADR 0003). No node here decides anything the processor did not tell it.

## What each section does

Every node has a plain-English name and every section has a sticky note on the canvas.

| # | Section | Nodes | What happens |
|---|---|---|---|
| 1 | Two ways to start | `Every 5 minutes`, `Run now button` | Timer, or a POST to `/webhook/slopecycle-run-now` (answers immediately). Both go into the same path. |
| 2 | Settings | `Settings` | The only place for `inbox_folder_id`, `spreadsheet_id`, `processor_url` (default `http://127.0.0.1:8787`). |
| 3 | Look in the Inbox | `List files in Inbox`, `Put all files in one list` | Lists files directly inside the Inbox folder (not sub-folders, not trashed), then bundles them into `{files: [...]}`. |
| 4 | Ask the processor | `Ask processor what is new`, `One item per file to handle`, `Add link and uploader` | POST `/plan`, split `todo` into one item per file, attach `url` (webViewLink) and `submitted_by` (last modifier's display name) from the Drive listing. |
| 5 | One file at a time | `One file at a time`, `Does the file need to be read?`, `Download file from Drive`, `Send file to processor`, `Send decision to processor (no file)`, `Processor answer` | Batch size 1. `action = process`: download (Google Docs exported as `text/plain`, everything else as-is) and POST `/process` as multipart with the binary in field `file`. `reject` / `rewrite`: same POST, no file. `/process` timeout is 60 minutes. |
| 6 | Save to the Sheet | `Any transcript lines?` ... `Save to Run Log tab` | In order: Transcripts (key `line_id`), Evidence (`evidence_id`), Interviews (`interview_id`), Run Log (`run_id`), each as Append or Update Row. An empty array is skipped (the `Any ...?` checks). The `Get the answer again ...` nodes just re-load the processor's answer, because the Sheets nodes replace the data flowing through. |
| 7 | Report back | `Did processor ask us to save?`, `Tell processor: save finished`, `Tell processor: save failed` | All writes OK and `write` is true: POST `/runs/{run_id}/complete`. Any Sheets node fails (its error output): POST `/runs/{run_id}/write-failed` with `{"message": ...}`. Either way the loop moves to the next file. |

If the Drive download or the `/process` call itself fails, that file is skipped and the loop continues. Nothing is reported, because the processor already handles it: a claim older than 30 minutes is treated as abandoned and the file is offered again by `/plan`.

## Node types and versions

All exist in n8n 1.64.3 (the version installed on this Mac) and are still supported in current n8n.

| Node | type | typeVersion |
|---|---|---|
| Schedule | `n8n-nodes-base.scheduleTrigger` | 1.2 |
| Webhook | `n8n-nodes-base.webhook` | 2 |
| Settings, Add link and uploader, Get the answer again | `n8n-nodes-base.set` | 3.4 |
| Google Drive (list, download) | `n8n-nodes-base.googleDrive` | 3 |
| Put all files in one list | `n8n-nodes-base.aggregate` | 1 |
| HTTP Request (x5) | `n8n-nodes-base.httpRequest` | 4.2 |
| One item per ... | `n8n-nodes-base.splitOut` | 1 |
| One file at a time | `n8n-nodes-base.splitInBatches` | 3 |
| If (x5) | `n8n-nodes-base.if` | 2.2 |
| Processor answer | `n8n-nodes-base.noOp` | 1 |
| Google Sheets (x4) | `n8n-nodes-base.googleSheets` | 4.5 |
| Sticky notes | `n8n-nodes-base.stickyNote` | 1 |

There is no Code node. Newer n8n shows newer versions of some of these (for example Sheets 4.7), but older versions keep working. If n8n offers to upgrade a node, the defaults used here do not change.

## How to set it up

1. **Sheet.** Create a Google Sheet with four tabs named exactly `Interviews`, `Evidence`, `Transcripts`, `Run Log`. In each, import the matching file from `sheet-template/` into row 1 (File > Import > Replace current sheet, or paste the single header row). The column order is taken from the processor code. Adding your own extra columns to the right (or anywhere) is fine.
2. **Import.** In n8n: Workflows > Add workflow > the `...` menu > Import from file > `slopecycle-interview-agent.json`. (The n8n CLI `import:workflow` wants a JSON array, so wrap it first: `python3 -c "import json,sys;print(json.dumps([json.load(open(sys.argv[1]))]))" slopecycle-interview-agent.json > /tmp/wf-array.json`.)
3. **Settings.** Open the `Settings` node and replace the two placeholders. The Inbox folder id is the last part of the folder's Drive URL. The Sheet id is the long part of the Sheet's URL between `/d/` and `/edit`. Leave `processor_url` unless the processor runs elsewhere.
4. **Google credential.** Create one Google OAuth2 credential in n8n named **SlopeCycle Google** (needs the Google Drive API and Google Sheets API enabled in the Google Cloud project, and Drive/Sheets scopes). The workflow references that name with no id. Open each of the 6 Google nodes (`List files in Inbox`, `Download file from Drive`, the four `Save to ... tab` nodes) and select the credential if n8n has not matched it. For this credential type, n8n creates separate "Google Drive OAuth2 API" and "Google Sheets OAuth2 API" credentials; create both and name both `SlopeCycle Google`.
5. **Activate.** Make sure the processor is running on `processor_url`. Run the workflow once by hand first (Execute workflow, or POST to the test URL), look at the Run Log tab, then switch the workflow to Active. The Run now URL is `http://<n8n-host>:5678/webhook/slopecycle-run-now` (POST). The processor's Run now button needs `SLOPE_RUN_NOW_URL` set to that.
6. n8n's own execution timeout must not be shorter than the audio jobs. Default is unlimited; if `EXECUTIONS_TIMEOUT` is set on Noah's install, raise it above 3600 seconds.

## How the Sheets nodes behave (read from the n8n 1.64.3 source, not guessed)

- **Mapping mode** is "Map Automatically": every key in the processor's row is a column header. Only keys present in the row are written. Columns the founder adds to a tab are never touched on an update, because Append or Update writes one cell per key it was given. On a brand new row, columns not in the processor's row are written empty.
- **Match column** is the id key (`line_id`, `evidence_id`, `interview_id`, `run_id`). A matching row is updated in place; otherwise a row is appended. Resending the same rows is therefore safe.
- **Null values are skipped on update.** If a re-processed revision has an empty field that used to have a value, the old cell value stays. This is a property of the node, not something n8n can change here.
- **Extra fields in input = Error.** If the processor ever sends a key with no matching header in the tab (for example someone renamed a header), the write fails loudly and the processor is told `write-failed`, rather than silently creating or dropping columns. Header names must match the CSV templates exactly.
- **Cell format = USER_ENTERED** ("Let Google Sheets format"). The processor prefixes formula-looking text with `'`. With USER_ENTERED, Google Sheets treats that leading apostrophe as its "this is text" marker: the cell holds the text without the apostrophe, so it displays cleanly and is not evaluated as a formula. (RAW would also not evaluate formulas but would show the apostrophe.) Side effect: other values are interpreted as if typed, so something like `2026-10-12` becomes a date and `00:00:02` becomes a time. Matching is on text read back from the sheet, and the ids are not number- or date-like, so keys are unaffected.
- **Minimise API Calls (use append) = on.** Without it the node adds only one blank row and then writes the whole batch below the data, which fails once a few hundred transcript lines pass the end of the sheet's grid (a new tab has 1000 rows). With it on the node uses Google's append call, which grows the grid. The node's own hint says this assumes no blank gaps between rows, so do not leave blank rows in the data.

## Verified by actually running it

Done here with n8n 1.64.3 (isolated `N8N_USER_FOLDER`, `~/.n8n` untouched) against the real processor (`uvicorn`, temp data dir) with a fake Ollama returning a canned extraction:

- The JSON imports cleanly with `n8n import:workflow` (array-wrapped) and keeps the credential references name-only.
- With Drive list/download swapped for stand-ins and Sheets swapped for pass-through nodes: three files (a `.txt`, a PDF, a Google Doc) went through `/plan`, `Add link and uploader`, the one-at-a-time loop, `/process` multipart with the binary as `file` (accepted by the processor), and the processor returned a completed Interview with `source_url` and `submitted_by` filled in. Empty tabs were skipped, Evidence/Interviews/Run Log were reached in order, and `/complete` was called only for the item with `write: true` (the processor status page showed it completed). The PDF went down the no-file path and produced a Run Log failure row with no Interview.
- With the real Google Sheets nodes and no credentials: every Sheets node failed, its error output called `/write-failed`, the processor moved the runs to `retry` (`sheet_write`), and the loop still processed all three files.
- With the real workflow activated on a local n8n: POST `/webhook/slopecycle-run-now` returned 200 in about 40 ms and started the same path (it then stopped at the Drive node for lack of credentials, as expected); GET returns 404, so the webhook is POST only.

## NOT verified (needs real Google credentials or real data)

- Anything that talks to Google: the Drive list (the folder filter, `trashed = false`, and that `fields = *` returns `md5Checksum`, `version`, `modifiedTime`, `webViewLink`, `lastModifyingUser`), the Google Doc export as `text/plain`, binary downloads, and every Sheets write. I read the node source for the behavior above but never ran it against Google.
- That n8n auto-matches the name-only `SlopeCycle Google` credential after import. On a local activation it logged "Found credential with no ID", so expect to pick the credential once per Google node.
- The Drive node cannot select individual fields in 1.64.3 (its list lacks `md5Checksum`, `modifiedTime`, `lastModifyingUser`), so the workflow requests all fields (`*`). That is a superset of the ones you asked for, and the processor ignores extras. If the payload to `/plan` is too big for a large Inbox, the fix is an HTTP Request node calling the Drive API with an exact `fields` list.
- The real error text of a failed Sheets write: in 1.64.3 the Sheets node's error output does not carry the message in the item data. The `write-failed` message is therefore the generic "Google Sheets write failed (see the n8n execution log for details)" unless a newer n8n puts the text in `$json.error`, which the expression already handles. The real cause is in the n8n execution log.
- A real audio job. The 60-minute HTTP timeout and n8n's own execution timeout are set but untested.
- A Run now press while the 5-minute timer is already mid-run. Two executions can overlap. The processor's claims prevent duplicate processing, but two n8n executions may also each send the same file's rows; the keyed upserts make that harmless. Not tested.
- The `Schedule` trigger firing (activation succeeded; I did not wait five minutes).
- Whether a failed Run Log write for a `write: true` item matters: if Evidence/Interviews/Run Log fails midway, nothing after the failure is written for that file this cycle, and no Run Log "completed" row exists until the retry succeeds. Intentional (the processor will redo it), but not observed on real Sheets.
