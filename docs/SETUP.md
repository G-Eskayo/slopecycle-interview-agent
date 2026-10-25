# Setup guide for Noah

This guide sets up the agent on your Mac, start to finish. Do it once. Every step says what to click or paste, and what you should see when it worked.

**Plan for about 45 minutes**, mostly waiting for downloads. Keep the Mac plugged in.

---

## Before you start: checklist

- [ ] **A Mac with an Apple chip.** Apple menu  → **About This Mac**. The "Chip" line should say **Apple M1** (or M2, M3, M4…). An "Intel" Mac won't work.
- [ ] **macOS 14 (Sonoma) or newer.** Same window, the line at the top (15 Sequoia or newer is best).
- [ ] **16 GB of memory**, on the "Memory" line.
- [ ] **15 GB of free disk space.** Apple menu → **System Settings → General → Storage**.
- [ ] **The team's Google account** password at hand. This is the account that will own the Inbox folder and the sheet.
- [ ] **Your Mac login password.** Some steps ask for it.

---

## Part 1: Open Terminal

Terminal is a window where you paste text commands. You only need it for Part 2.

1. Press **⌘ Command + Space**, type **Terminal**, press **Return**.
2. A window with a blinking cursor opens. That's it.

**How to run a command from this guide:** click the copy button on the grey box, click into Terminal, press **⌘ Command + V** to paste, then press **Return**. Wait until the text stops scrolling and you see the blinking cursor again before the next one.

> When Terminal asks for your **password**, type your Mac login password and press Return. **Nothing appears while you type.** That's normal.

---

## Part 2: Install the agent

### Step 2.1: Install Homebrew (the Mac's app installer for developer tools)

Skip this step if you've installed Homebrew before. To check, paste `brew --version`. If it prints a version number, skip ahead.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

- It asks for your password, then "Press RETURN to continue". Press Return.
- It takes 5–10 minutes.
- **At the end it prints "Next steps" with two or three commands** starting with `echo` and `eval`. Copy those lines exactly as printed and run them. This step is easy to miss.

✅ **Check:** `brew --version` prints a version number.

### Step 2.2: Install Apple's command line tools

```bash
xcode-select --install
```

- A pop-up appears. Click **Install**, then **Agree**. It takes 5–15 minutes.
- If it says "already installed", great, move on.

### Step 2.3: Download the agent

```bash
git clone https://github.com/G-Eskayo/slopecycle-interview-agent.git ~/slopecycle-interview-agent
```

✅ **Check:** in Finder, your home folder now has a folder called **slopecycle-interview-agent**.

### Step 2.4: Run the installer

```bash
cd ~/slopecycle-interview-agent && ./scripts/install.sh
```

This installs everything else: the AI model, n8n, the transcriber and the processor. **It takes 15–30 minutes.** The AI model alone is a 5 GB download.

- If macOS asks whether to open **Ollama** ("downloaded from the internet"), click **Open**.
- If it stops with a message like "Install Homebrew first" or "Run: xcode-select --install", do that step, then run the same command again.
- Running it again is always safe.

✅ **Check:** near the end you see both lines:
```
  processor OK
  n8n OK: open http://127.0.0.1:5678
```

From now on, both start by themselves whenever you log in to the Mac.

---

## Part 3: Make your n8n account

n8n is the tool that runs the workflow. It runs on your Mac, and you use it in your web browser.

1. Open **http://127.0.0.1:5678** in Chrome or Safari.
2. Fill in the "Set up owner account" form: your email and a password. **Save this password**; it's only for n8n on this Mac.
3. Skip the survey questions.

✅ **Check:** you see the n8n home screen ("Overview" / "Workflows").

---

## Part 4: Make the Inbox folder and the sheet in Google Drive

Sign in to **drive.google.com** with the **team Google account**.

### Step 4.1: The Inbox folder

1. **New → New folder**, name it **SlopeCycle Interviews Inbox**, then **Create**.
2. Right-click the folder → **Share → Share**. Add all five teammates' emails as **Editor**, then **Send**.
3. Open the folder and look at the web address. It ends like this:
   `drive.google.com/drive/folders/`**`1AbCdEfGhIjKlMnOpQrStUv`**
   The bold part is the **folder ID**. Copy it into a note; you'll paste it in Part 7.

### Step 4.2: The Interview Log sheet

1. **New → Google Sheets → Blank spreadsheet**. Rename it (top left) to **SlopeCycle Interview Log**.
2. Add the four tabs from the files in `workflow/sheet-template/` in your slopecycle-interview-agent folder:
   1. **File → Import → Upload**, choose `Interviews.csv`.
   2. Import location: **Insert new sheet(s)**. Click **Import data**.
   3. Repeat for `Evidence.csv`, `Transcripts.csv` and `Run Log.csv`.
3. Delete the empty **Sheet1** tab: right-click it → **Delete**.
4. **Check the four tab names are exactly** `Interviews`, `Evidence`, `Transcripts`, `Run Log`, with the same capitals and spaces. Rename any that differ (double-click the tab).
5. Look at the web address:
   `docs.google.com/spreadsheets/d/`**`1XyZaBcDeFgHiJkLmNoPqRsTuVwXyZ`**`/edit`
   The bold part is the **sheet ID**. Copy it into your note.
6. Share the sheet with the teammates (**Share** button, top right), as **Editor** or **Viewer**.

---

## Part 5: Give n8n permission to use Google

Google requires a free "OAuth client". It's a key that lets *your* n8n, and only yours, open *your* Drive and Sheets. It's the most clicks of any part, so take it slowly.

### Step 5.1: Create a Google Cloud project

1. Go to **console.cloud.google.com** and sign in with the **team Google account**. Accept the terms if asked.
2. Top left, click the project picker (it may say "Select a project") → **New project**. Name it **SlopeCycle agent**, then **Create**.
3. Make sure the picker now shows **SlopeCycle agent**.

### Step 5.2: Turn on Drive and Sheets

1. In the search bar at the top, type **Google Drive API**, open it, and click **Enable**.
2. Search **Google Sheets API**, open it, and click **Enable**.

### Step 5.3: Set up the sign-in screen

1. Search **OAuth consent screen** and open it. Click **Get started**.
2. **App name:** `SlopeCycle agent`. **User support email:** the team email. **Next**.
3. **Audience:** **External**. **Next**.
4. **Contact email:** the team email. **Next**, tick the agreement, **Create**.
5. In the left menu click **Audience**. Under **Test users** click **Add users**, add the team Google account, **Save**.

### Step 5.4: Create the key

1. In the left menu click **Clients** → **Create client**.
2. **Application type:** **Web application**. **Name:** `n8n`.
3. Under **Authorized redirect URIs** click **Add URI** and paste exactly:
   ```
   http://localhost:5678/rest/oauth2-credential/callback
   ```
4. Click **Create**. A box shows a **Client ID** and a **Client secret**. Copy both into your note. Treat the secret like a password, and don't post it anywhere.

### Step 5.5: Put the key into n8n

1. In n8n (http://127.0.0.1:5678): **Overview → Credentials** tab → **Create credential**. (In some versions it's the **+** button → **Credential**.)
2. Search **Google Drive OAuth2 API** and pick it.
3. Name it exactly **SlopeCycle Google** (click the name at the top to edit it).
4. Paste the **Client ID** and **Client Secret**.
5. Compare the **OAuth Redirect URL** n8n shows with the one you pasted in 5.4. If it's different, go back to Google and add n8n's version too.
6. Click **Sign in with Google**, choose the team account.
   - You'll see **"Google hasn't verified this app."** That's expected: it's your own app. Click **Continue**.
   - Tick all the boxes it asks for, then **Continue**.
7. ✅ n8n says **"Connection tested successfully"** or shows a green "Account connected". Click **Save**.
8. **Do the same again** for **Google Sheets OAuth2 API**: same name, same ID and secret, same sign-in.

### Step 5.6: Stop the weekly sign-out (important)

While a Google app is in "Testing", Google signs it out **every 7 days**, and the agent would quietly stop working.

1. Back in Google Cloud: **OAuth consent screen → Audience → Publish app → Confirm**.
2. You don't need Google's verification for this. It only affects the "unverified app" warning, which only you see.

If you ever see Google sign-in errors in the Run Log, repeat Step 5.5's **Sign in with Google** for both credentials.

---

## Part 6: Import the workflow

1. In n8n: **Overview → Create workflow** (or **+ → Workflow**).
2. Top right, click the **⋯** menu → **Import from File…**, then choose `workflow/slopecycle-interview-agent.json` from your slopecycle-interview-agent folder.
3. ✅ You see a long row of boxes with coloured notes (it matches the picture in the README).

---

## Part 7: Fill in the settings and connect Google

1. **Double-click the "Settings" box** (section 2).
   - Replace `PASTE_INBOX_FOLDER_ID_HERE` with your **folder ID**.
   - Replace `PASTE_SPREADSHEET_ID_HERE` with your **sheet ID**.
   - Leave `processor_url` as it is. Close the box.
2. **Connect Google on the six Google boxes.** Double-click each one, choose **SlopeCycle Google** in the **Credential** dropdown at the top, then close it:
   - **List files in Inbox** and **Download file from Drive** (green triangle Drive icon)
   - **Save to Transcripts tab**, **Save to Evidence tab**, **Save to Interviews tab**, **Save to Run Log tab** (green Sheets icon)
3. Press **⌘ Command + S** to save.
4. Top right, flip the switch from **Inactive** to **Active**. Confirm if asked.

✅ The workflow now checks the Inbox every 5 minutes.

---

## Part 8: Test it

1. In Finder, open **slopecycle-interview-agent → fixtures**. Drag **happy-path.txt** into the **SlopeCycle Interviews Inbox** folder in Google Drive. (It's made-up test data and says so inside.)
2. Open **http://127.0.0.1:8787**. This is the agent's status page. Click **Run now**.
3. Wait 1–3 minutes, then open the **Interview Log** sheet.

✅ **Check, all four:**
- [ ] **Interviews** has a new row: 2 kids, ages 7 and 10, rental reaction "conditional".
- [ ] **Evidence** has rows with quotes like "About $300 for both kids…".
- [ ] **Run Log** has a row saying **completed**.
- [ ] Click **Run now** again and wait a minute: **still only one** interview row. That's the duplicate protection working.

Afterwards you can delete the test rows from each tab, or keep them; they're labelled SYNTHETIC TEST DATA.

**Bookmark http://127.0.0.1:8787.** It only opens on your Mac. It's your control panel for demos.

---

## Part 9: Keeping it running

- The agent works **while your Mac is on, awake and logged in**. Files uploaded while it sleeps simply wait, and it catches up when you open the lid.
- For a demo or a busy week, stop it sleeping: **System Settings → Battery → Options →** turn on **"Prevent automatic sleeping on power adapter when the display is off."**
- Everything restarts on its own when you log in. No need to open anything.

## Updating to a newer version

```bash
cd ~/slopecycle-interview-agent && git pull && ./scripts/install.sh
```

If the update notes say the workflow changed, repeat Parts 6–7 (import the new file, fill in the settings, delete the old workflow).

## Turning it off

```bash
~/slopecycle-interview-agent/scripts/stop.sh
```

To disconnect Google as well: in n8n delete the **SlopeCycle Google** credentials, then remove "SlopeCycle agent" at **myaccount.google.com/permissions**. Nothing in Drive or the sheet is deleted.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| `command not found: brew` after installing Homebrew | You skipped the "Next steps" lines at the end of Step 2.1. Scroll up in Terminal, run them, then open a new Terminal window. |
| Installer stops with a red error | Run `./scripts/install.sh` again. If it fails at the same place, copy the last 20 lines and send them to Gil. |
| http://127.0.0.1:8787 won't open | The processor isn't running. Run `./scripts/install.sh` again; it restarts it. |
| Nothing shows up in the sheet | Status page: does the file appear? If not, check the workflow is **Active** and the folder ID in **Settings** is right. In n8n open **Executions** to see the last runs. |
| Run Log says **failed (will retry)** | Usually Google or the AI model was briefly unavailable. It retries on its own, waiting longer each time. After 3 failed tries at reading a file it stops and says **failed**; edit the file (any small change) or upload it again to make it try again. |
| Run Log says **failed** with "not supported" | The file was a PDF, photo or other type the agent can't read. Paste the content into a Google Doc instead. |
| Google sign-in errors | Redo Step 5.5 "Sign in with Google" for both credentials, and check Step 5.6 was done. |
| A row says **Needs review** | Not an error. The reason is in the `review_reasons` column. Read it and check the interview. |

Logs, if someone technical asks for them, are in `~/Library/Logs/slopecycle/`.

## Privacy

Interviews stay on this Mac and in the team's Google account. The AI model runs on this Mac; no AI company receives interview content. The only other copy is a small run history at `~/Library/Application Support/slope-processor/`, used for retries and duplicate checks.
