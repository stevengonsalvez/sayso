# Installed-app E2E batch 1 runbook

Status: written, NOT run. No result below is real until the results table at the end is filled in by someone who ran it.

Scope: the modules that are wired into `SaysoAppModel` at origin head: TTS, History, Models install progress, Vocabulary suggestions, Shortcut intents, Control run/review, Dictation session activity, status line and Studio menu. Clipboard, File shelf, External API (opt-in) are built but not wired and are out of scope except where stated.

Rule from HANDOVER: this batch runs once after three to five modules are wired. Any failure becomes a deterministic failing acceptance test first, then a fix.

## 0. Preconditions (stop if any fails)

1. Exact head recorded: `git rev-parse HEAD` in the worktree, plus the CI result for that head.
2. `swift test` green on that head in `macos/`.
3. No other Sayso process holds the socket, hotkeys or microphone:
   - `pgrep -fl SaysoNotch` must print nothing, or only the process you are about to replace on purpose.
   - Another Claude session may be packaging or running the app (for example a Control-proof session). Ask or check `ListAgents` first; never kill a process you did not start.
   - Never run `pkill` by name. Kill by exact pid you started.
4. Use a fresh disposable target for every write test (new TextEdit document, scratch Finder folder). Never send a message, delete a file or quit an unrelated app.
5. Provider keys stay in Keychain or memory only. Never print a key.

## 1. Package without touching the installed app

The installed app is `/Applications/Sayso Notch.app` (bundle id `ai.sayso.notch`). Do not overwrite or remove it.

```bash
cd <worktree>/macos
./Scripts/package-app.sh          # builds release, writes macos/.artifacts/Sayso Notch.app, codesign --verify
```

- Signing: `SAYSO_CODESIGN_IDENTITY` if set, else the first local "Apple Development" identity, else ad hoc (`-`). Ad hoc builds lose Accessibility and Microphone grants on each rebuild; expect to re-grant.
- The script ends with `spctl --assess`, which rejects an un-notarized build. That is expected.
- Run it in tmux (long build, about 3.5 minutes cold): `tmux new -d -s e2e-package ...`, log with `| tee package.log`. Kill the session by exact name only.
- Run the artifact from `.artifacts`, not from `/Applications`:

```bash
cd <worktree>/macos
./Scripts/run-packaged-app.sh     # runs .artifacts app with --automation-server, logs to dev-sayso-app.log
```

Run this only when precondition 3 holds. If the installed app must stay running, do NOT run batch 1; quit the installed app yourself first (the user's call), or wait.

Record: app path, `codesign -dv` identity line, `pgrep -fl SaysoNotch` showing exactly one process.

## 2. Permissions

Grant in System Settings for the packaged app: Microphone, Accessibility, Input Monitoring (shortcut taps), Speech Recognition if the Apple Speech route is used. Record the state of each before and after.

Expected before grant: Control shows "Accessibility permission needed"; dictation start asks for the microphone. These are existing behaviors, not module behavior.

## 3. Hotkeys (shortcut intents)

Defaults from `SaysoShortcutAction`: dictation double-tap Fn, control triple-tap Fn, toggle notch Control-Option-N. Fallbacks: dictation Option-Space, control Control-Option-Space.

| Step | Action | Pass |
|---|---|---|
| 3.1 | Press the dictation hotkey once in TextEdit | Dictation starts exactly as on the previous release; notch shows "Listening" |
| 3.2 | Press it again | Dictation stops; no double start, no double stop |
| 3.3 | Press the control hotkey | Control mode listens; key up/down edges behave as before |
| 3.4 | Press Control-Option-N | Notch toggles |

Fail if any hotkey does nothing or fires twice. Known risk: `ShortcutsModule` and `ShortcutIntentModule` would double fire if both were enabled; only the intent module should be.

## 4. Dictation into editable targets (HANDOVER Wave 1 first E2E)

The CLI is the `sayso` product (`swift build -c release --product sayso`, binary under `.build/release/`); it is separate from the app bundle.

Deterministic acceptance first (no speech): `sayso acceptance --target <bundle-id> "<text of more than two words>"` with the target frontmost and a fresh empty field. The verdict requires: at least one applied partial insertion, final insertion (not clipboard), a readable target value that changed and contains the text.

Bundle ids: only TextEdit (`com.apple.TextEdit`) and Finder (`com.apple.finder`) were verified on the authoring machine. Resolve the others at run time with `osascript -e 'id of app "<name>"'` and record the result; the ids below marked `?` are unverified guesses.

| Target | Bundle id | Setup | Pass |
|---|---|---|---|
| TextEdit | `com.apple.TextEdit` | New empty document, plain text | Text appears incrementally, final text exact, clipboard untouched afterwards |
| Orca | `?` (resolve at run time) | Focus an empty editable field | Same as TextEdit, or a documented limitation |
| Arc | `?` (Arc is commonly `company.thebrowser.Browser`; resolve at run time) | Focus a text input on a scratch page, not the address bar | Same |
| WhatsApp | `?` (resolve at run time) | Open a chat with a disposable contact, type in the draft field | Draft text exact; MESSAGE IS NEVER SENT; clear the draft afterwards |
| Finder | `com.apple.finder` | Rename field of a scratch file, or Spotlight-style field | Same, or a documented non-editable result |

Pass criteria per HANDOVER: partial transcript chunks reach the focused target; the clipboard is not used for normal streaming; a temporary clipboard is only a fallback; the previous clipboard is restored after verified insertion; dictated text stays available only when insertion fails. Note: the clipboard module's `pasteTemporarily` is NOT wired; the existing `TextOutput` logic is what is being tested.

Then repeat once with real speech (Apple Speech microphone proof). This is a separate boundary from the injected-text acceptance; never claim one from the other.

Evidence to capture per target: before and after screenshot, the `sayso acceptance` JSON, and `sayso status` output.

## 5. What each wired module should visibly do

| Module | Trigger | Expected visible behavior | Pass |
|---|---|---|---|
| TTS | Studio, Voice output tab: Speak | Speech plays; Stop works; speaking twice replaces the first utterance and the second is not cut off | Audible, no stuck state |
| TTS | Notch "Speak" for the latest transcript | Latest transcript is read in its language | Audible |
| History | Complete one dictation | New row appears in Studio History; failure to save shows a notice and the transcript is not lost | Row present |
| History busy state | Start a reprocess or import, then try a second one and Clear | Second and Clear are refused with the same notice strings as before | Same text as 69cdcb0 |
| Models | Start a local model install in Studio | Notch status shows "Downloading <model> · N%" while not live; completes with "<model> ready" that disappears after about 5 s; cancel clears it; failure offers Retry | Status line follows the install |
| Vocabulary | Edit a dictated word the same way until the promotion threshold | A "Remember X as Y?" suggestion appears; resolving it in Settings removes the notch card | Card appears and clears |
| Dictation activity | Start and stop dictation | Activity "Listening" then "Transcribing" then gone; failure shows "Dictation failed" for about 6 s | Matches |
| Status line | Trigger any of the above while not live | One line of status; tap runs only Retry for a failed install; never Approve, Cancel or a clarification choice | No unintended action |
| Studio menu | Notch More menu, "Open in Studio" with an activity shown | Studio opens on the module's tab (history 2, models 4, vocabulary 6, tts 9, control 1, dictation 0, shortcuts 8) | Correct tab |

## 6. Control (guarded; Calculator only for the review test)

Precondition: Desktop Control enabled in Settings and Accessibility granted. Use the built-in Try now (Open Calculator) first, then the matrix from `CONTROL_PROOF.md` for Calculator `12 x 3 = 36`, Arc explicit HTTPS navigation, TextEdit exact text, Finder safe folder, WhatsApp draft (never sent).

| Step | Pass |
|---|---|
| 6.1 Run "Open Calculator" | Notch shows "Control: ..." with a Cancel; ends with a completion notice; exactly one finish (no "Control stopped" after a cancel) |
| 6.2 Cancel mid-run | Notch shows the cancelled state; no later completed or failed notice |
| 6.3 Ambiguous target (two similar names) | One bounded clarification card with one button per choice; ignoring it for 60 s removes it; tapping the status text never picks a choice |
| 6.4 A step that requires confirmation | A critical review card with explicit Approve and Deny buttons in EVERY mode; tapping the status text never approves; the menu item reads "Deny" |
| 6.5 Approve in the Studio window while the card shows | Card disappears; the step runs once |
| 6.6 Approve a stale card after a second step replaced it | Rejected; nothing runs |
| 6.7 Provider failure, low confidence, protected or stale target, destructive action | Nothing executes; audit entry present and free of secrets |

## 7. Not in this batch

Clipboard history, File shelf, External API socket (needs `defaults write ai.sayso.notch sayso.externalAPI.enabled -bool true`), the module permission gate, performance numbers (idle CPU below 0.5 percent median, under 150 MB excluding speech models, hover under 80 ms), multi-display and fullscreen. These need their own batches.

## 8. Results table (fill in; leave blank if not run)

Run date: ____  Head: ____  CI for head: ____  Runner: ____  Packaged app path: ____  Signing identity: ____

| # | Step | Result (pass/fail/blocked) | Evidence (file, screenshot, JSON) | Notes / failure becomes test |
|---|---|---|---|---|
| 3.1 | | | | |
| 3.2 | | | | |
| 3.3 | | | | |
| 3.4 | | | | |
| 4 TextEdit | | | | |
| 4 Orca | | | | |
| 4 Arc | | | | |
| 4 WhatsApp (not sent) | | | | |
| 4 Finder | | | | |
| 5 TTS | | | | |
| 5 History | | | | |
| 5 Models | | | | |
| 5 Vocabulary | | | | |
| 5 Status line | | | | |
| 6.1 to 6.7 | | | | |

Proof boundaries to state in the report: injected-text acceptance versus real Apple Speech; installed app versus `.artifacts` build; exact head; CI status of that head; anything blocked and why.
