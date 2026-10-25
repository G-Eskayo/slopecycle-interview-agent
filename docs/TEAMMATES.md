# Guide for teammates

You don't install anything. Your whole job is: **put the interview in the Inbox folder, then read the results in the sheet.**

---

## One-time setup (5 minutes)

### 1. Accept the two invites

Noah will share two things with your Google account. Check your email for:

- [ ] **"SlopeCycle Interviews Inbox"**, a folder. Open the email and click **Open**.
- [ ] **"SlopeCycle Interview Log"**, a spreadsheet. Open it and **bookmark it** (⌘ Command + D).

### 2. Put the Inbox where you can find it

**On your laptop:** in Google Drive, click **Shared with me**, right-click **SlopeCycle Interviews Inbox** → **Organize → Add shortcut** → **My Drive**. Now it's in your own Drive.

**On your phone:** install the **Google Drive** app (App Store or Google Play) and sign in with the same Google account. The folder is under **Shared** (or in **Files** if you added the shortcut).

That's it for setup.

---

## For every interview

### Before the interview

- **Ask permission to record.** Say something like:
  > "Is it OK if I record this so I don't miss anything? It's only for our student team's research, and we won't share your name."
  
  If they say no, take notes instead. That works just as well.
- **Don't write down** the parent's full name, phone number, email or address unless the team has decided you need them. Use a label like **P-07** (parent number 7) instead.

### Option A: You recorded it on your phone

**iPhone (Voice Memos app):**
1. After the interview, open **Voice Memos** and tap the recording.
2. Tap **⋯** (three dots) → **Share** → **Save to Files**. If you don't see Drive there, use **Share → Drive** instead.
3. Choose **Drive → Shared → SlopeCycle Interviews Inbox** → **Save / Upload**.

**Android (Recorder app):**
1. Open the recording, tap **Share** → **Drive**.
2. Choose the folder **SlopeCycle Interviews Inbox** → **Save**.

**Zoom / Google Meet recording:** download the recording file (the audio or video file), then upload it to the Inbox from your laptop (drag it into the folder in your browser).

> Recordings of any length work. A one-hour interview takes a few minutes to process.

### Option B: You took notes

Write a **Google Doc** in your own Drive (or a Word or text file). **When it's finished, move it into the Inbox**: in Drive, right-click the Doc → **Organize → Move** → **SlopeCycle Interviews Inbox**. Use this layout, which gives the best results:

```
Interview date: 2026-11-02
Interviewer: (your name)
Respondent: P-07, Louisville CO   (parent / expert: shop owner, coach…)

Q: How many of your kids ski?
A: Two, ages 8 and 11.
Q: Where do you get their jackets and pants?
A: ...
```

Tips:
- Start answers with **A:** when you're writing down what *they* said. Lines without **A:** are treated as *your* notes, not their words.
- Put their exact words in quotes when you can: `A: "They outgrow everything by February."`
- Write down what you showed or told them before they reacted (e.g. "Explained the rental idea, then asked…").
- If they're an expert (shop owner, coach, rental business) and not a parent, say so on the Respondent line.

**Why finish before moving it in:** the agent reads a file as soon as it sees it. If you fix something later, that's fine. It updates the same row, never a second one, but the first version's quotes stay in the Evidence tab marked with the old version, which is clutter.

### After uploading

Nothing else to do. When Noah's Mac is on, the agent checks the folder every 5 minutes. If his Mac is asleep, your file waits safely and gets processed when it wakes.

---

## Reading the results

Open the **SlopeCycle Interview Log** sheet.

### The Interviews tab: one row per interview

The columns you'll use most:

| Column | What it means |
|---|---|
| `source_name` | Which file this row came from |
| `review_status` | **Auto-accepted**: the agent found no problems. **Needs review**: a person should check it |
| `review_reasons` | Exactly what to check, e.g. "respondent contradicts themselves" |
| `concise_summary` | The short write-up: overview, key findings (with evidence numbers like E03), what's missing, follow-up questions |
| `number_of_kids_who_ski`, `kids_ages` | As stated by the parent |
| `spend_raw_text` | Their spending, **in their own words** |
| `derived_per_child_amount` | A calculated average, only when the math is clearly valid. `derivation_note` explains it |
| `willingness_to_rent` | **yes** / **conditional** (yes *if* something) / **undecided** / **no** / blank (never came up) |
| `rental_conditions`, `objections` | What would make them rent, and what puts them off |
| `missing_fields` | What the interview didn't cover. Good things to ask next time |
| `suggested_followups` | Questions worth asking if you talk to them again |
| `exclude_from_parent_stats` | TRUE for expert interviews. Don't count these as parents |

**A blank cell means "not said", not "no" and not zero.**

### The Evidence tab: the quotes

Each row is one quote that backs up an answer, with its `source_locator` (line number in your notes, or a timestamp like `00:12:31` in a recording). The summary's **E01, E02…** point to these rows. **Use these quotes in presentations and the investor deck. They're checked against the original.**

`evidence_type` tells you whose words they are: `respondent_statement` (the parent said it), `interviewer_note` (you wrote it), or `expert_opinion`.

### The Run Log tab

One row per processing attempt. **completed** = done. **duplicate (skipped)** = the same file was uploaded twice, so nothing new was created. **failed** = see `error_message` (usually "not supported" for PDFs or photos).

---

## When a row says "Needs review"

1. Read `review_reasons`.
2. Open the original file (link in `source_url`) and check that part.
3. If something is wrong, **fix the original file** (edit the Doc). The agent re-reads it and updates the row.
4. To add your own judgement, **add a new column at the right edge** of the Interviews tab (e.g. `founder_notes`). The agent never writes to columns it didn't create.

Don't type over the agent's own columns; the next update of that interview would replace your edit.

---

## Do and don't

| ✅ Do | ❌ Don't |
|---|---|
| One interview per file | Put two interviews in one file |
| If you have both a recording and notes, upload **only the recording** | Upload two files for one interview (that counts the parent twice) |
| Keep the Inbox for interviews only | Put unrelated files in the Inbox (they'll show as "not supported") |
| Use labels like P-07 instead of names | Write down phone numbers, emails or kids' names |
| Ask before recording | Record without permission |
| Fix mistakes in the original file | Edit the agent's columns in the sheet |
| Paste PDF or photo content into a Doc | Upload PDFs or photos of notes (they can't be read) |

## Questions

Ask Noah. If the Run Log shows errors you don't understand, he can check the status page on his Mac.
