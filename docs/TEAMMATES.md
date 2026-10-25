# Guide for teammates

After each interview you dictate your notes into the **SlopeCycle Send** app (with Wispr Flow, if you use it), attach the recording if you made one, and press **Send**. Then you read the results in the team sheet. That's it.

---

## One-time setup (about 5 minutes)

### 1. Get three things from Noah

He'll send them to you privately:
- [ ] the **download link** for SlopeCycle Send (it's also at the top of the [README](../README.md))
- [ ] the **access key**: a long code starting with `github_pat_`
- [ ] the **queue name**, which looks like `noahsname/slopecycle-interview-queue`

Also accept his invite to the **SlopeCycle Interview Log** Google Sheet and **bookmark it** (⌘ Command + D).

### 2. Install the app

1. Click the download link. **SlopeCycle-Send.zip** lands in your Downloads folder.
2. Double-click the zip. **SlopeCycle Send** appears next to it.
3. Drag **SlopeCycle Send** into your **Applications** folder (in Finder, the left sidebar → Applications).
4. Double-click it in Applications. **The first time, your Mac will refuse** ("Apple could not verify…"). That's because the app isn't from the App Store. To allow it:
   1. Click **Done** (or **OK**) on the warning.
   2. Open Apple menu  → **System Settings → Privacy & Security**.
   3. Scroll down to the message about **SlopeCycle Send** and click **Open Anyway**. Type your Mac password if asked.
   4. Click **Open Anyway** once more.
5. ✅ A small **paper-plane icon** appears in the menu bar at the top right of your screen. On a MacBook with a notch the icon may be hidden; open the app from Applications again and the window appears.

### 3. Fill in the settings (once)

1. Click the paper plane → **Settings…**
2. **Your name:** first name is fine. It's recorded as the interviewer.
3. **Queue repository:** paste the queue name from Noah.
4. **Access key:** paste the key from Noah. It's stored in your Mac's Keychain, not in a file.
5. Click **Test connection**. ✅ It says the connection works. If not, check you pasted the whole key.

---

## For every interview

### Before the interview

- **Ask permission to record.** Say something like:
  > "Is it OK if I record this so I don't miss anything? It's only for our student team's research, and we won't share your name."

  If they say no, just take notes afterwards. That works too.
- **Pick a label instead of a name**, like **P-07** (parent number 7) or **E-02** (expert number 2). The app warns you if you type something that looks like a real name.

### Recording (optional)

- **On your iPhone:** use **Voice Memos**. Afterwards, tap the recording → **⋯** → **Share** → **AirDrop** → your Mac. It lands in Downloads.
- **On your Mac:** open **Voice Memos** (or QuickTime Player → File → New Audio Recording) and press record.
- **Zoom / Google Meet:** download the recording file.

Any length is fine. The app shrinks it before sending (an hour becomes about 11 MB).

### Send it

1. Click the **paper plane** in the menu bar.
2. **Respondent:** the label, e.g. `P-07`.
3. **Type:** **Parent** for a parent or guardian; **Expert** for a shop owner, coach, rental business, etc.
4. **Date:** the day of the interview (it starts on today).
5. **Notes:** click in the box and dictate with Wispr Flow, or type or paste. Say what *they* said, in their words where you can. Use quotation marks for exact quotes: `"They outgrow everything by February."` Mention if you explained the rental idea before asking what they thought.
6. **Recording:** **Attach file…** and pick the recording (optional).
7. Press **Send**. ✅ It says **"✓ Sent to the queue"**.

**No internet?** Press Send anyway. The app saves it and sends it by itself as soon as you're back online. Don't send it again.

### After sending

Nothing else to do. The results appear in the sheet once Noah's Mac is on. If it's asleep, your interview waits safely and gets processed when it wakes. Your notes and recording are deleted from the queue automatically **after** the sheet has been checked.

---

## Reading the results

Open the **SlopeCycle Interview Log** sheet.

### The Interviews tab: one row per interview

| Column | What it means |
|---|---|
| `respondent_label`, `interviewer`, `interview_date`, `interview_type` | What you entered in the app |
| `review_status` | **Auto-accepted**: no problems found. **Needs review**: a person should check it |
| `review_reasons` | Exactly what to check, e.g. "respondent contradicts themselves" |
| `concise_summary` | The short write-up: overview, key findings (with evidence numbers like E03), what wasn't covered, follow-up questions |
| `number_of_kids_who_ski`, `kids_ages` | As stated |
| `spend_raw_text` | Their spending, **in their own words** |
| `derived_per_child_amount` | A calculated average, only when the math is clearly valid. `derivation_note` explains it |
| `willingness_to_rent` | **yes** / **conditional** (yes *if* something) / **undecided** / **no** |
| `rental_conditions`, `objections` | What would make them rent, and what puts them off |
| `missing_fields`, `suggested_followups` | What the interview didn't cover, and questions worth asking next time |
| `exclude_from_parent_stats` | TRUE for expert interviews. Don't count these as parents |

**"Not collected in interview"** means the agent found nothing about it in your notes or recording. It doesn't mean "no". If you know they did talk about it, it's worth checking `review_reasons` and telling Noah.

### The Evidence tab: the quotes

One row per quote backing an answer, with `source_locator` (e.g. `notes, line 3` or `recording, line 12 (00:12:31)`). The summary's **E01, E02…** point here. **Use these in presentations and the investor deck. They're checked against the original.** `evidence_type` says whose words they are: `respondent_statement`, `interviewer_note` (your notes) or `expert_opinion`.

### The Run Log tab

| Status | Meaning |
|---|---|
| **completed** | Done |
| **duplicate (skipped)** | The same notes or recording were already sent; nothing new was created |
| **failed (will retry)** | Something was briefly unavailable; it'll try again by itself |
| **failed (needs a person)** | Something's wrong with what was sent (e.g. empty notes, a recording that won't play). `error_message` says what. Send it again, fixed |

---

## When a row says "Needs review"

1. Read `review_reasons`.
2. If something is wrong, tell Noah. Don't type over the agent's cells: the sheet is view-only for teammates, so the agent's checks stay reliable.
3. Your own judgement and corrections go in a separate notes column Noah adds on the right, or in your team discussion.

---

## Do and don't

| ✅ Do | ❌ Don't |
|---|---|
| One interview per Send | Put two interviews in one Send |
| Send the recording **and** your notes together, in one Send | Send the notes and the recording separately (that's two interviews) |
| Use labels like P-07 | Type full names, phone numbers, emails or kids' names |
| Ask before recording | Record without permission |
| Press Send once, even offline | Press Send again because you're not sure (it's caught, but it's noise) |
| Keep the access key private | Post the access key in a group chat or on social media |

## Questions

Ask Noah. He can see exactly what happened to every interview on his status page.
