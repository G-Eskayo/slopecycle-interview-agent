# Live demo script (about 5 minutes, measure it in rehearsal)

Rehearse with synthetic fixtures; for the real demo use a de-identified real interview and say which is which.

1. **The problem (30 s).** Five of us interview parents; recoding each conversation by hand is slow and inconsistent.
2. **The agent (30 s).** Show the workflow diagram in `docs/design.md`: Drive Inbox → n8n → local transcriber + local model → validation → Google Sheet.
3. **Run it (2 min).**
   - Drop an interview (notes or a short recording) into the Inbox in front of the room.
   - Open http://127.0.0.1:8787 and press **Run now**.
   - Open the sheet: the new `Interviews` row, its summary, and the `Evidence` rows with exact quotes and line/timestamp locators.
4. **Duplicate (30 s).** Press Run now again. No second row; the status page shows nothing new to do. (To show a logged duplicate, upload an identical copy of the file: Run Log shows "duplicate (skipped)".)
5. **Missing answers (30 s).** Show the `missing-data` row: blanks stay blank, the follow-up questions ask for them, status Needs review.
6. **What broke and what we changed (1 min).** From `docs/prompt-log.md`: the model left stated facts blank; a malicious file flipped "no" to "yes"; "for both kids" read as per child. Each fixed in code, not just the prompt.

## Questions to be ready for
- *Where does it run?* Noah's Mac. No server, no subscription; files wait in Drive until it's awake.
- *Who sees interview data?* Only the team: local model, team Google account.
- *What still needs a human?* Anything marked Needs review, interpreting what findings mean for the venture, and whether one parent's view generalises (it doesn't on its own).
