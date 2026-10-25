# 6. Data lives only until the sheet is verified; GitHub's own runner rings the doorbell

Date: 2026-10-25. Status: accepted. Amends [0005](0005-event-driven-git-queue.md) (replaces the ngrok tunnel).

## Context
Recordings and notes exist only to produce the sheet. Once the sheet holds the result, nothing else needs to be kept: Wispr Flow already keeps its own copy of what was dictated. The queue repo must not grow without limit, and nothing may be deleted until the sheet provably has it.

## Decision
**Smallest audio.** The Send app re-encodes every recording to 16 kHz mono AAC at 24 kbps (about 11 MB per hour; a real-speech clip transcribed identically to the original WAV).

**Lifecycle of a Submission:**
1. *Sent* → committed to the queue repo.
2. *Processed* → rows built; the processor keeps them only in memory-backed run state until verified.
3. *Written* → n8n writes the rows to the sheet.
4. *Verified* → n8n reads the rows back **from the sheet** and the processor compares every cell it sent with what is actually there. Anything missing or different: not verified, write again later.
5. *Purged* → only after verification: the Submission folder is deleted from the queue repo, and the processor forgets the rows it cached. It keeps only content fingerprints, so the same recording sent again is recognised as a duplicate.
6. *Compacted* → whenever the queue holds no Submissions and nothing is in progress, the processor replaces the repo's history with a single fresh commit (`--force-with-lease`, so a Submission sent at that exact moment is never lost), then prunes its own clone. That is what actually frees the space: deleting a file alone leaves it in Git history.

Submissions that **fail** (unreadable audio, empty notes) are **never purged automatically**: their data never reached the sheet. They stay in the queue until a person deals with them; the Run Log says why.

**No transcript copies.** The Transcripts tab is dropped. The Evidence tab still holds the exact quotes behind each answer, which the assignment requires. n8n is set not to keep execution data, so no copy of interview content lingers in its history.

**Missing answers say so.** Every interview field the interview didn't cover reads **"Not collected in interview"** in the sheet, never a blank or a guess. Calculated fields that couldn't be calculated say why in their note.

**Trigger: a GitHub Actions self-hosted runner, not ngrok.** Noah installs GitHub's runner app on his Mac and attaches it to the private queue repo. A push to `submissions/` queues a job, and the runner picks it up and calls n8n on the same Mac (`127.0.0.1`). The runner opens the connection to GitHub; nothing on the internet can reach the Mac, and there is no public address and no extra account. Jobs wait for up to 24 hours while the Mac is offline; anything older is caught by the wake-up trigger. The processor's own commits carry `[skip ci]`, so they don't trigger runs.

## Rejected
- ngrok or any tunnel: an extra account and a public address pointing at the Mac, for no gain over the runner.
- Deleting right after the write (without reading the sheet back): a write that silently lost a column would lose the data for good.
- Keeping transcripts "just in case": the team doesn't want copies, and the evidence quotes are what the assignment needs.

## Consequences
- The processor's GitHub access must allow deleting files and replacing history on the queue repo (its own key, kept on the Processor Mac only). Teammates' Send key cannot touch `.github/` (no Workflows permission), so it cannot change what the runner runs.
- GitHub may keep unreachable objects for a while after a history rewrite before its garbage collection removes them; the repo's reported size drops then.
- A field the model missed even though it was said will also read "Not collected in interview". The quotes, `missing_fields` and Needs review make that visible; the phrase means "the agent found no evidence", not a guarantee.
