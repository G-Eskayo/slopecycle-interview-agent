# SlopeCycle Send

A small Mac menu-bar app for sending interview notes and recordings to the team's private queue repo. You dictate notes into it with Wispr Flow, attach a recording if you have one, and press **Send**. Why it exists and how it fits the pipeline: [ADR 0005](../docs/adr/0005-event-driven-git-queue.md). What it writes, exactly: [submission format](../docs/submission-format.md).

![The SlopeCycle Send window](docs/send-window.png)

Requires macOS 14 or later. Runs on Apple silicon and Intel.

## Install (teammates)

1. Get `SlopeCycle-Send.zip` from Noah and double-click it. You get **SlopeCycle Send.app**.
2. Drag it into **Applications**.
3. Open it. The app isn't signed with an Apple Developer ID yet, so the first time macOS says it can't check it. On macOS 15 and later, right-click → Open no longer gets past this. Instead:
   - Click **Done** (not Move to Trash).
   - Open **System Settings → Privacy & Security**, scroll to the message about "SlopeCycle Send", and click **Open Anyway**.
   - Confirm with your password or Touch ID, then click **Open**.

   You only do this once.
4. A paper-plane icon appears in the menu bar. If you can't see it (it can hide behind the notch on a MacBook), open the app again from Applications or Spotlight and the window appears.
5. Optional, and recommended: **System Settings → General → Login Items → +**, add SlopeCycle Send. Anything that couldn't be sent yet then goes out automatically after a restart.

## Settings (once)

Paper-plane icon → **Settings…**

| Field | What to put |
|---|---|
| Your name | Your first name. It goes into each submission as the interviewer. |
| Queue repository | `owner/name` of the private queue repo, from Noah. A pasted `https://github.com/owner/name` link works too. |
| Access key | The shared key from Noah. It's stored in your Mac's Keychain, never in a file. |

Press **Test connection**. "✓ The key can see owner/name" means you're set. If you press Send before Settings are complete, the app opens Settings for you.

## Sending

Paper-plane icon → **Open SlopeCycle Send**.

- **Respondent**: a label like `P-07`, never a name. If it looks like a full name (two capitalised words) you see a warning, but you can still send.
- **Type** and **Date**: the date is today unless you change it.
- **Notes**: click in the box and dictate with Wispr Flow, type, or paste.
- **Recording**: optional. Any audio or video file: m4a, mp3, wav, aiff, caf, mp4, mov…
- **Send** is enabled once there's a respondent and either notes or a recording. **Cancel** clears the form and closes the window.

"✓ Sent to the queue" means GitHub has it. If you're offline you'll see "Saved. It will be sent automatically when you're back online." You don't need to do anything else.

## How it works

**Recordings are compressed first.** The app re-encodes the recording to speech-quality audio: AAC, 16 kHz, mono, 24 kbps, about 11 MB per hour. For a video it keeps only the audio track. The result is always sent as `recording.m4a`, and `recording_sha256` is the hash of the compressed file. Your original file is only read, never changed or moved. If compression fails, the original is sent unchanged, with "(recording sent uncompressed)" added to the status line. The 100 MB limit applies to the file that is actually sent. A bigger file is refused with a message and nothing is saved. Files that aren't audio or video can't be attached.

**Outbox first, so nothing is lost.** Pressing Send copies the submission into
`~/Library/Application Support/SlopeCycle Send/outbox/<submission_id>/`
(`meta.json`, `notes.txt`, `recording.m4a`) before any network traffic. A folder only appears there once it's complete. It's deleted only after GitHub has accepted the commit. Each submission keeps the same `submission_id` every time it's retried.

**Retry on events, not timers.** The outbox is sent oldest first at launch, whenever the network comes back (`NWPathMonitor`), and after a successful Test connection. There is no polling.

**One commit per submission** (GitHub Git Data API): read `heads/main` → check whether `submissions/<id>/` already exists there → upload one blob per file → read the head commit's tree → create a tree on top of it → create the commit `Submission <id> from <name>` → move `main` without force. If another teammate sent at the same moment, the move is rejected (409/422). The app then re-reads `main` and rebuilds the tree and commit, up to 5 tries, reusing the uploaded blobs.

**Idempotent.** If the folder for that id is already on `main` (say the last attempt landed but the reply was lost), the app counts it as sent and clears it from the outbox. It never makes a duplicate commit.

Other details:
- HTTP caching is off. GitHub marks API replies cacheable for 60 s, and a cached `heads/main` would make every ref update look like a conflict.
- The access key is sent only in the `Authorization` header and is never logged.
- Commit messages never contain CI-skip markers such as `[skip ci]`. The processor reserves those for its own commits, so they're removed from the interviewer name.

## Build (developers)

```sh
cd send-app
swift test                      # unit tests (no network)
./scripts/build-app.sh          # → dist/SlopeCycle Send.app and dist/SlopeCycle-Send.zip
```

`build-app.sh` builds a universal release binary and assembles the bundle (`com.slopecycle.send`, version 1.0.0, `LSUIElement`, minimum macOS 14.0). It then ad-hoc signs it and zips it with `ditto`.

Layout:
- `Sources/SlopeSendCore`: all logic, UI-free and unit-tested: submission ids, `meta.json`, the name check, settings validation, compression (AVFoundation), the outbox, and the Git Data API writer with its retry loop behind an `HTTPClient` protocol.
- `Sources/SlopeCycleSend`: the SwiftUI app: window, Settings, Keychain, network monitor.
- `Tests/SlopeSendCoreTests`: an in-memory fake GitHub with real fast-forward rules, plus race, outage and lost-reply knobs. There are also real-audio compression tests and opt-in live tests.

Live tests against a private scratch repo (synthetic data only; the key is passed through the environment, never written to a file):

```sh
SLOPE_SEND_LIVE=1 SLOPE_SEND_TOKEN="$(gh auth token)" \
SLOPE_SEND_REPO=G-Eskayo/slopecycle-queue-test SLOPE_SEND_M4A=/path/to/synthetic.m4a \
swift test --filter LiveGitHubTests
```

Developer checks built into the app; they do nothing unless the variable is set:
- `SLOPE_SEND_SELFTEST=1 "dist/SlopeCycle Send.app/Contents/MacOS/SlopeCycleSend"`: drives the real notes box in-process with typed keys, Cmd-V paste, `insertText` and a 1 MB paste, prints PASS/FAIL, then quits. It borrows the clipboard and restores it afterwards.
- `SLOPE_SEND_SNAPSHOT_DIR=docs …/SlopeCycleSend`: renders the window to `docs/send-window.png` and `docs/send-window-filled.png`. It doesn't need Screen Recording permission.
