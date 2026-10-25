# 5. Event-driven: a Send app, a private Git queue, and triggers instead of timers

Date: 2026-10-25. Status: accepted. Supersedes the queue and schedule parts of [0001](0001-one-processor-mac-drive-inbox.md).

## Context
The team wants every step started by an event, not a recurring check, and wants teammates to send interviews straight from their own Macs, dictating with Wispr Flow. Wispr Flow has no export or send feature; it types into whatever text box has focus.

## Decision
- **Send app.** Teammates install a small Mac menu-bar app, *SlopeCycle Send*. They dictate notes into its text box with Wispr, optionally attach a recording, and press Send. The app writes one **Submission** (notes, recording, and who/when) as a single commit to a **private** GitHub repo, the **queue repo**, through GitHub's web API. Teammates never install Git or hold a copy of the repo. If they're offline, the app keeps the Submission and sends it when the connection comes back.
- **One access key.** Noah creates one fine-grained GitHub token limited to writing that one repo, and teammates paste it once. They need no GitHub account. Revoking it cuts everyone off at once.
- **Triggers, no timers.**
  1. *Sent*: GitHub notifies Noah's Mac (see [0006](0006-data-lifetime-and-github-runner-trigger.md): a self-hosted runner, not ngrok).
  2. *Woke up / logged in*: a small listener on Noah's Mac fires the same workflow, because GitHub does not resend notifications a sleeping Mac missed.
  3. *Run now*: the button, for demos.
  All three only ring a doorbell. The processor then pulls the queue repo itself and works out what's new, so a fake or repeated notification can't inject anything or cause duplicates.
- **Recordings go in the same repo.** Phone voice memos are about 30 MB per hour, under GitHub's 100 MB file limit. The repo grows by every recording sent; archive it each semester.
- **Google Drive is no longer used.** Google access shrinks to Sheets only.

## Rejected
- A 5-minute schedule: the team wants event-driven work.
- Reading Wispr Flow's private history database: unofficial, breaks on app updates, and ships everything the person ever dictated.
- Each teammate cloning the repo: storage on every Mac, and Git skills nobody has.

## Consequences
- The queue repo holds customer interview data and must stay private. The public code repo never holds interview data.
- (Tunnel consequence superseded by 0006: no public address at all.)
- The app is unsigned until signed with an Apple Developer ID. Until then, first launch needs System Settings → Privacy & Security → Open Anyway.
- Only Noah's Mac clones the queue repo, so only it grows with recordings.
