# Setup guide for Noah

This sets up the agent on your Mac, start to finish. Do it once. Every step says what to click or paste, and what you should see when it worked.

**Plan for about an hour**, mostly waiting for downloads. Keep the Mac plugged in.

You'll set up five things, in this order:

| # | What | Why |
|---|---|---|
| 1 | The agent software on your Mac | Does the actual work |
| 2 | A **private** GitHub repository (the "queue") | Where teammates' interviews wait until your Mac processes them |
| 3 | Two GitHub access keys | One for teammates' Send app, one for your Mac |
| 4 | A Google Sheet + Google permission | Where results go |
| 5 | The GitHub runner | Tells your Mac the moment an interview arrives |

---

## Before you start: checklist

- [ ] **A Mac with an Apple chip.** Apple menu  → **About This Mac**. The "Chip" line should say **Apple M1** (or M2, M3, M4…). An "Intel" Mac won't work.
- [ ] **macOS 14 (Sonoma) or newer** (15 Sequoia or newer is best). It's shown in the same window.
- [ ] **16 GB of memory**, on the "Memory" line.
- [ ] **15 GB of free disk space.** Apple menu → **System Settings → General → Storage**.
- [ ] **A GitHub account** (free, github.com). This is where the queue lives.
- [ ] **The team's Google account** password at hand. It will own the results sheet.
- [ ] **Your Mac login password.** Some steps ask for it.

---

## Part 1: Install the agent on your Mac

### 1.1 Open Terminal

Press **⌘ Command + Space**, type **Terminal**, then press **Return**. A window with a blinking cursor opens.

**How to run a command from this guide:** copy the grey box, click into Terminal, press **⌘ Command + V**, then press **Return**. Wait until the blinking cursor is back before the next one.

> When Terminal asks for your **password**, type your Mac login password and press Return. **Nothing appears while you type.** That's normal.

### 1.2 Install Homebrew (the Mac's installer for developer tools)

To check whether you already have it, paste `brew --version`. If it prints a version number, skip to 1.3.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

- It asks for your password, then "Press RETURN to continue". Press Return. It takes 5–10 minutes.
- **At the end it prints "Next steps"** with two or three lines starting with `echo` and `eval`. **Copy those exactly as printed and run them.** This step is easy to miss.

✅ `brew --version` now prints a version number.

### 1.3 Install Apple's command line tools

```bash
xcode-select --install
```

A pop-up appears. Click **Install**, then **Agree**, and wait 5–15 minutes. If it says "already installed", move on.

### 1.4 Download the agent

```bash
git clone https://github.com/G-Eskayo/slopecycle-interview-agent.git ~/slopecycle-interview-agent
```

✅ Finder → your home folder now has a **slopecycle-interview-agent** folder.

### 1.5 Run the installer

```bash
cd ~/slopecycle-interview-agent && ./scripts/install.sh
```

This installs the AI model (a 5 GB download), n8n, the transcriber, the processor and the wake-up helper. **It takes 15–30 minutes.**

- If macOS asks whether to open **Ollama**, click **Open**.
- If it stops and tells you to do something first, do it, then run the same command again. Running it again is always safe.

✅ Near the end you see `processor OK` and `n8n OK`. You'll also see a line saying to fill in the queue settings. That's next.

---

## Part 2: Make the private queue on GitHub

Teammates' interviews wait here until your Mac picks them up. Each one is deleted automatically once it's safely in the sheet.

1. Sign in at **github.com**. Top right **+** → **New repository**.
2. **Repository name:** `slopecycle-interview-queue`.
3. Choose **Private**. ⚠️ This matters: it will hold customer interviews.
4. Tick **Add a README file**. Click **Create repository**.
5. Add the "doorbell" file that tells your Mac when something arrives:
   1. In the new repository click **Add file → Create new file**.
   2. In the name box type exactly: `.github/workflows/tell-processor.yml` (the slashes create folders).
   3. Open `queue-repo-template/.github/workflows/tell-processor.yml` from your slopecycle-interview-agent folder (right-click → Open With → TextEdit), copy everything, and paste it into the big box on GitHub.
   4. Click **Commit changes…** → **Commit changes**.
6. Replace the README text with the one in `queue-repo-template/README.md` (click README.md → the pencil icon → paste → **Commit changes**).

✅ The repository shows **Private**, a `.github` folder and the README.

---

## Part 3: Make two access keys

An access key lets an app add files to the queue without anyone's password. Make two, so you can cut off teammates' key without stopping your own Mac.

1. github.com → your profile picture (top right) → **Settings** → scroll down to **Developer settings** (bottom of the left menu) → **Personal access tokens → Fine-grained tokens** → **Generate new token**.
2. Fill in:
   - **Token name:** `SlopeCycle Send (teammates)`
   - **Expiration:** **Custom**, pick the end of the semester
   - **Repository access:** **Only select repositories** → choose `slopecycle-interview-queue`
   - **Permissions → Repository permissions → Contents:** **Read and write**. Leave everything else alone; in particular, don't give it "Workflows".
3. Click **Generate token** and **copy it right away** (it starts with `github_pat_`). Save it in your notes as **Teammate key**. You'll give this to teammates.
4. Do it again with the name `SlopeCycle processor (Noah's Mac)`, with the same settings. Save it as **Processor key**. **Don't share this one.**

### Put the processor key on your Mac

```bash
open -e ~/.slopecycle.env
```

A TextEdit window opens. Fill in the two lines and save (⌘ Command + S):

```
SLOPE_QUEUE_REPO=YOUR_GITHUB_USERNAME/slopecycle-interview-queue
SLOPE_QUEUE_TOKEN=github_pat_...your processor key...
```

Then run the installer once more so the processor picks them up:

```bash
cd ~/slopecycle-interview-agent && ./scripts/install.sh
```

✅ The "fill in SLOPE_QUEUE" line no longer appears.

---

## Part 4: Results sheet and Google permission

### 4.1 Make your n8n account

Open **http://127.0.0.1:5678** in Chrome or Safari and fill in "Set up owner account". **Save this password**; it's only for n8n on this Mac. Skip the survey.

### 4.2 Make the sheet

Sign in to **sheets.google.com** with the **team Google account**.

1. **Blank spreadsheet**. Rename it (top left) to **SlopeCycle Interview Log**.
2. Add the three tabs from `workflow/sheet-template/`:
   1. **File → Import → Upload**, choose `Interviews.csv`.
   2. Import location: **Insert new sheet(s)**. Click **Import data**.
   3. Repeat for `Evidence.csv` and `Run Log.csv`.
3. Right-click the empty **Sheet1** tab → **Delete**.
4. **Check the tab names are exactly** `Interviews`, `Evidence`, `Run Log`. Double-click a tab to rename it.
5. Copy the **sheet ID** from the address into your notes. It's the bold part here: `docs.google.com/spreadsheets/d/`**`1XyZaBcDeF...`**`/edit`
6. **Share** (top right): add the teammates as **Viewer**, so they can read results but not type over them.

### 4.3 Let n8n write to the sheet

Google needs a free "OAuth client", a key that lets *your* n8n, and only yours, edit *your* sheet.

1. **console.cloud.google.com**, signed in with the team account. Top left project picker → **New project** → name `SlopeCycle agent` → **Create**. Make sure it's selected.
2. Search **Google Sheets API** → **Enable**.
3. Search **OAuth consent screen** → **Get started**:
   1. App name `SlopeCycle agent`, support email the team email → **Next**.
   2. **External** → **Next**.
   3. Contact email → **Next** → agree → **Create**.
4. Left menu **Audience** → **Test users → Add users** → the team account → **Save**.
5. Left menu **Clients** → **Create client**:
   1. **Web application**, name `n8n`.
   2. Under **Authorized redirect URIs** → **Add URI**, paste:
      ```
      http://localhost:5678/rest/oauth2-credential/callback
      ```
   3. **Create**, then copy the **Client ID** and **Client secret** into your notes. Treat the secret like a password.
6. In n8n: **Overview → Credentials → Create credential** → **Google Sheets OAuth2 API**:
   1. Name it exactly **SlopeCycle Google** and paste the ID and secret.
   2. If n8n's **OAuth Redirect URL** differs from what you pasted in step 5, add n8n's version in Google too.
   3. **Sign in with Google** with the team account. On "Google hasn't verified this app", click **Continue** (it's your own app), tick the boxes, **Continue**.
   4. ✅ "Account connected". **Save**.
7. **Stop the weekly sign-out:** back in Google Cloud → **Audience → Publish app → Confirm**. Apps left in "Testing" get signed out every 7 days, and the agent would quietly stop.

---

## Part 5: Import the workflow

1. In n8n: **Overview → Create workflow**. Top right **⋯ → Import from File…** and choose `workflow/slopecycle-interview-agent.json`.
2. Double-click **Settings**. Paste your **sheet ID** in place of `PASTE_SPREADSHEET_ID_HERE` and leave `processor_url` alone.
3. Double-click **each green Google Sheets box** and choose **SlopeCycle Google** under **Credential**. n8n doesn't link it automatically after import.
4. **⌘ Command + S** to save, then flip **Inactive → Active** (top right).

---

## Part 6: Connect the GitHub runner (the doorbell)

1. On GitHub open **slopecycle-interview-queue → Settings → Actions → Runners → New self-hosted runner**.
2. Choose **macOS** and **ARM64**. In the "Configure" box there's a line like:
   `./config.sh --url https://github.com/you/slopecycle-interview-queue --token ABCDEF123456...`
   Copy only the **token**, the long code after `--token`. It's valid for one hour.
3. In Terminal (replace the two parts in capitals):
   ```bash
   cd ~/slopecycle-interview-agent && ./scripts/install-runner.sh YOUR_GITHUB_USERNAME/slopecycle-interview-queue PASTE_TOKEN_HERE
   ```
4. ✅ It ends with "Runner connected". The GitHub Runners page shows your Mac as **Idle**.

---

## Part 7: Test it end to end

1. Install the **SlopeCycle Send** app on your own Mac, as in the [teammate guide](TEAMMATES.md). Use the **Teammate key**.
2. Send a test interview. Respondent `TEST-01`, notes: *"SYNTHETIC TEST DATA. Parent has two kids who ski, ages 8 and 11. Would rent if size swaps are free."*
3. Within a few minutes:
   - [ ] **Interviews** has a row for TEST-01: 2 kids, ages 8 and 11, rental "conditional", and lots of cells saying **"Not collected in interview"**. That's correct: the notes didn't cover those things.
   - [ ] **Evidence** has the quotes.
   - [ ] **Run Log** says **completed**.
   - [ ] On GitHub, `slopecycle-interview-queue` no longer has a `submissions` folder. The interview was deleted *after* the sheet was checked.
4. Open **http://127.0.0.1:8787** (bookmark it). Your test shows **Verified** and **Removed** times.

Delete the TEST-01 rows afterwards if you like.

## Part 8: Hand out the Send app

Send each teammate three things privately (not in a group chat): the **Send app** download link from the README, the **Teammate key**, and the queue name `YOUR_GITHUB_USERNAME/slopecycle-interview-queue`. Their guide is [TEAMMATES.md](TEAMMATES.md).

---

## Keeping it running

- **Your Mac only needs to be on when you want results.** Interviews sent while it's asleep wait safely in the queue. When it wakes up or you log in, it catches up by itself.
- Everything starts by itself at login. Nothing needs opening.
- For a demo, stop it sleeping: **System Settings → Battery → Options →** turn on **"Prevent automatic sleeping on power adapter when the display is off."**

## What gets deleted, and when

| Thing | Kept until |
|---|---|
| Notes and recording in the queue | The sheet has been **read back and matched** cell by cell. Then they're deleted, and the history is cleared once the queue is empty |
| An interview that **failed** (unreadable audio, empty notes) | **Never deleted automatically.** Its data never reached the sheet. The Run Log says why; fix it by sending it again, then delete the old folder on GitHub |
| Rows in the sheet | Forever. They're the record |
| Copies on your Mac | None. The processor forgets the content once the sheet is verified, and n8n keeps no run history |

## Updating

```bash
cd ~/slopecycle-interview-agent && git pull && ./scripts/install.sh
```

If the release notes say the workflow changed, re-import it (Part 5) and delete the old one.

## Turning it off

```bash
~/slopecycle-interview-agent/scripts/stop.sh
```

To cut off teammates: GitHub → Settings → Developer settings → Fine-grained tokens → **SlopeCycle Send (teammates)** → **Delete**. Your Mac keeps working with its own key.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| `command not found: brew` | You skipped the "Next steps" lines in 1.2. Scroll up, run them, open a new Terminal window. |
| Installer stops with a red error | Run it again. If it fails at the same place, send the last 20 lines to Gil. |
| http://127.0.0.1:8787 won't open | Run `./scripts/install.sh` again (it restarts everything). |
| Status page says **Queue problem** | Check the two lines in `~/.slopecycle.env` (Part 3) and that the processor key hasn't expired. |
| An interview was sent but nothing happens | GitHub → queue repo → **Actions**: is there a run? If it's "queued", the runner is offline: run Part 6 again. If there's no run at all, check `.github/workflows/tell-processor.yml` exists. Also check the n8n workflow is **Active**. |
| Run Log: **failed (will retry)** | Google or the AI model was briefly unavailable. It tries again on the next interview, wake-up or **Run now**. |
| Run Log: **failed (needs a person)** | Read `error_message`. Usually an empty note or a recording that can't be played. Ask the teammate to send it again. |
| Google sign-in errors | Redo "Sign in with Google" (Part 4.3 step 6) and check step 7 was done. |
| A row says **Needs review** | Not an error. `review_reasons` says what a person should check. |

Logs, if someone technical asks: `~/Library/Logs/slopecycle/`.
