# Submission format (queue repo contract, format 1)

The Send app writes it; the processor reads it. Change both together, and bump `format`.

## Layout in the private queue repo (branch `main`)

```
submissions/
  2026-11-02T183005Z-3f9a1c2e/      ← one folder per Submission, never edited after sending
    meta.json
    notes.txt                      ← optional (UTF-8 text, as dictated/typed)
    recording.m4a                  ← optional (any audio/video extension), max 100 MB
```

At least one of `notes.txt` or a recording must be present.

**Submission id:** `<UTC send time yyyy-MM-ddTHHmmssZ>-<8 random lowercase hex>`. It sorts by time and is unique without coordination.

## meta.json

```json
{
  "format": 1,
  "submission_id": "2026-11-02T183005Z-3f9a1c2e",
  "sent_at": "2026-11-02T18:30:05Z",
  "interviewer": "Alex",
  "respondent_label": "P-07",
  "interview_type": "parent",
  "interview_date": "2026-11-02",
  "notes_file": "notes.txt",
  "recording_file": "recording.m4a",
  "notes_sha256": "…",
  "recording_sha256": "…",
  "app_version": "1.0.0"
}
```

| Field | Rule |
|---|---|
| `interview_type` | `"parent"` or `"expert"` |
| `interview_date` | `YYYY-MM-DD`, the day of the interview (defaults to today in the app) |
| `respondent_label` | Short label like `P-07`; never a full name (the app warns on two capitalised words) |
| `interviewer` | The name set once in the app's settings |
| `notes_file` / `recording_file` | File name inside the folder, or `null` |
| `*_sha256` | Hex SHA-256 of that file's bytes, or `null`. Used to spot the same interview sent twice |

## How the app writes it

One commit per Submission, all files at once (GitHub Git Data API): create a blob per file, then a tree on top of the current `main` tree, then a commit, then move `refs/heads/main` without force. If moving the ref fails because someone else sent at the same moment, re-read `main` and redo the tree/commit (up to 5 tries). Commit message: `Submission <id> from <interviewer>`.

## How the processor reads it

Only the Processor Mac clones the queue repo. On every trigger it fetches `main` and resets to it (it never commits). Each folder under `submissions/` is one Source. Its revision key is the git tree id of that folder. Identical notes and recording bytes under a different id count as a duplicate.
