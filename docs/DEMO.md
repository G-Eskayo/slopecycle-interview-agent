# Live demo script (about 5 minutes; time it in rehearsal)

Rehearse with synthetic interviews; for the real demo use a de-identified real one and say which is which. Before class: Noah's Mac awake and plugged in, the sheet open, the queue repo open on GitHub, http://127.0.0.1:8787 open.

1. **The problem (30 s).** Five of us interview parents. Recoding every conversation by hand is slow and inconsistent.
2. **The agent (30 s).** Show the "big picture" diagram in the README: Send app → private queue → doorbell → Noah's Mac → sheet → verified → deleted.
3. **Send one live (2 min).**
   - On a teammate's Mac: paper plane → fill in the window → dictate with Wispr (or paste) → **Send**. "✓ Sent to the queue."
   - On GitHub: the queue now has a `submissions` folder, and **Actions** shows the doorbell run.
   - In the sheet: the new **Interviews** row, its summary, the **Evidence** quotes with locators, and "Not collected in interview" where it wasn't covered.
   - Back on GitHub: the folder is **gone**. Explain that it was deleted only after the sheet was read back and matched.
4. **Duplicate (30 s).** Send exactly the same notes again. Run Log: "duplicate (skipped)". There's no second row.
5. **Failure (30 s).** Send a note that just says "hi". Run Log: "failed (needs a person)", and it stays in the queue instead of disappearing.
6. **What broke and what we changed (1 min).** From `docs/prompt-log.md`: the model left stated facts blank; a malicious file flipped "no" to "yes"; "for both kids" read as per child. Each was fixed in code, not just in the prompt.

## Questions to be ready for
- *Where does it run?* Noah's Mac. No server, no subscription, no timer: sending an interview is what starts it.
- *Who sees interview data?* Only the team: a private queue that empties itself, a local AI model, the team's Google account.
- *Why delete the recordings?* Once the sheet has been checked, they're just a liability. Wispr keeps the dictation on the teammate's side.
- *What still needs a human?* Anything marked Needs review, interpreting what findings mean for the venture, and whether one parent's view generalises (it doesn't on its own).
