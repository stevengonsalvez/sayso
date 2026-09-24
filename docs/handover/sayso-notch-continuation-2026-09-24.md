# Sayso Notch continuation handover

**Generated:** 2026-09-24 09:46:35 BST  
**Repository:** `/Users/stevengonsalvez/orca/sayso`  
**Active branch:** `main`, clean and aligned with `origin/main`  
**Last commit:** `35334d4 test: cover redo desktop control`  
**Live development session:** `dev-sayso-notch-1790188365:1.1`

## Original product goal

Build a premium native Swift macOS app called **Sayso Notch**:

- A crisp, Sayso-branded, native notch experience. Collapsed state sits at the hardware notch, with only the icon visible beside the camera. Expanded state stays centered, shows two live transcript lines, a premium dictation/control selector, long primary start button, detach, settings/open-app and quit controls.
- A detachable floating-widget presentation that can toggle back to notch presentation.
- Full user-facing dictation parity with `crmitchelmore/justspeaktoit`, implemented in Swift. This includes live/final transcription, active-app insertion, clipboard handling, profiles, history, recordings, hotkeys, hands-free behavior, translation, cleanup, audio routing and language/model choices.
- Comprehensive desktop control based on `savka777/jev-use`, including a safe voice-command desktop automation system. Dictation and Control are switchable from the notch, including switching back to dictation through voice control.
- English default, plus Indian-language dictation support for Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Punjabi, Telugu and Urdu. User requested Sayso-style onboarding and all setting sections, not a minimum viable product.
- Small signed, atomic commits, review before merge, direct pushes to `main`, and accurate proof of what is and is not physically verified.

## Reference implementations and attribution

| Reference | Local copy | Product use |
|---|---|---|
| JustSpeakToIt | `/Users/stevengonsalvez/d/git/justspeaktoit` | Dictation UX, profiles, permissions, clipboard patterns, history and session behavior |
| jev-use | `/Users/stevengonsalvez/orca/workspaces/jev-use/jevuse` | Voice desktop control, accessibility capture and command ergonomics |
| JustSpeakToIt GitHub | `https://github.com/crmitchelmore/justspeaktoit` | MIT source reference |
| jev-use GitHub | `https://github.com/savka777/jev-use` | Desktop control reference |

MIT attribution exists in `macos/LICENSES.md`. Any copied or materially adapted source must retain accurate attribution and license notices.

## Current implementation

### Presentation and app shell

- Native SwiftUI/AppKit app with `NotchPanelController.swift` controlling compact, expanded, detached and click-away behavior.
- Premium dark Sayso styling, brand colors, subtle shine/glow treatment, icon-first compact state, live text area, mode selector, controls for detach, open/settings, collapse and quit.
- Main app contains a left navigation and settings sections for the dictation/control product rather than a single popover.
- Onboarding exists in `SaysoNotchApp.swift`, requests privacy permissions, then sets language, route and text-output choices.

### Dictation

- Apple Speech route plus local FluidAudio engines for English and Indic languages.
- Local Sherpa Punjabi model support.
- Default spoken language is English. Supported choices include automatic plus Hindi, Tamil, Malayalam, Bengali, Gujarati, Kannada, Marathi, Punjabi, Telugu and Urdu.
- Apple Speech lifecycle, microphone permission state, audio-device selection and session lifecycle are implemented.
- Partial transcript delivery is available. Live insertion uses a replacement-region guard so only Sayso-owned text is replaced.
- Final transcript insertion supports the active app, clipboard restore behavior and user-configured output handling.
- Hotkey support includes push-to-talk/tap and a configurable default. Hands-free continuous mode has target-app and field identity pins, phrase/session bounds and failure disarm.
- History, recordings, saved-audio policy and selected-text voice editing are wired.
- Translation and cleanup routes exist, with explicit cloud consent for cloud work.
- Per-app profiles can override language, route, translation, output language and cleanup. Runtime resolves a snapshot for the foreground application without mutating global preferences.

### BYOK cloud transcription

- BYOK is a real dictation route, not a settings-only selector.
- `OpenAICompatibleAudioTranscriber.swift` sends the captured M4A to `baseURL/audio/transcriptions` over HTTPS, with bearer authentication, transcription model, normalized language and multipart audio field.
- API secret stays in `KeychainSecretStore`, not in `UserDefaults`.
- Endpoint validation blocks non-HTTPS endpoints except localhost. File size is bounded at 512 MB. Temporary recording cleanup obeys the save-audio setting.
- BYOK sessions capture locally, submit after stopping and deliver the returned final transcript. Streaming partials are intentionally unavailable for this post-capture provider protocol.
- `sayso transcribe_file` refuses BYOK without explicit validated provider configuration, preventing accidental Apple fallback.
- Settings expose a global transcription model, default `gpt-4o-mini-transcribe`.

### Desktop control

- `DesktopControl.swift` implements protected command planning and execution through accessibility APIs.
- Current supported control includes application/window targeting, captures and navigation candidates, selection/focus/click, scrolling, tabs, undo, redo, app/URL/folder opening and destructive-action confirmation/audit behavior.
- Redo was most recently added. It uses the layout-aware `Command+Shift+Z` sequence and requires confirmation.
- Control actions remain intentionally confirmation-gated where they could cause data loss or an irreversible external change.

## Key code map

| Area | Key files |
|---|---|
| App, onboarding, settings views | `macos/Sources/SaysoNotch/SaysoNotchApp.swift` |
| Notch geometry and interaction | `macos/Sources/SaysoNotch/NotchPanelController.swift` |
| Automation/status endpoint | `macos/Sources/SaysoNotch/SaysoAutomationServer.swift` |
| Domain, languages and routes | `macos/Sources/SaysoCore/Domain.swift` |
| Dictation profiles | `macos/Sources/SaysoCore/DictationProfile.swift` |
| Permissions/settings panes | `macos/Sources/SaysoCore/Permissions.swift` |
| Speech session orchestration | `macos/Sources/SaysoCore/LiveTranscriber.swift` |
| BYOK audio transcription | `macos/Sources/SaysoCore/OpenAICompatibleAudioTranscriber.swift` |
| Local English and Indic recognition | `macos/Sources/SaysoCore/FluidAudioLocalModel.swift` |
| Local Punjabi recognition | `macos/Sources/SaysoCore/SherpaPunjabiModel.swift` |
| Live insertion safety | `macos/Sources/SaysoCore/TextTools.swift` |
| Hands-free safety | `macos/Sources/SaysoCore/HandsFreeRearm.swift` |
| Desktop automation | `macos/Sources/SaysoCore/DesktopControl.swift` |
| Packaging | `macos/Scripts/package-app.sh` |

## Recent delivered commit slices

| Commit range | Delivered work |
|---|---|
| `02a5c91` through `d042746` | Safe live partial insertion with user preference, replacement region, selected-text guard and final output gating |
| `65247f8` through `1edd634` | Per-app dictation runtime overrides and exact application profile settings |
| `4b8c434` through `ce1c09e` | Configured BYOK cloud audio-transcription route, keychain secret handling, explicit file-transcription configuration and tests |
| `c0a1795`, `35334d4` | Desktop-control redo planner/executor and coverage |

## Current verification evidence

All evidence below is from the current source head unless stated otherwise.

- `swift test`, run in `macos`, passed **193 tests** in approximately 3.9 seconds after the BYOK and redo work.
- Package path is `macos/Scripts/package-app.sh`; it builds release, packages the app and verifies its code signature.
- Packaged app passed `codesign --verify --deep --strict --verbose=2`.
- Live app is running once from `macos/.artifacts/Sayso Notch.app/Contents/MacOS/SaysoNotch --automation-server` in tmux session `dev-sayso-notch-1790188365:1.1`.
- Automation status reported `microphone=granted`, local English/Indic/Punjabi models installed, `speech=undetermined`, no active session and `dictation=idle`.
- `pgrep` found one SaysoNotch process at last check.

### Verification limits

- A signed local app is not a notarized release. `spctl` rejects the package until an authorized notarization profile is supplied through `SAYSO_NOTARY_PROFILE`.
- No real cloud transcription provider call has been made. Unit tests use a mock provider protocol. Never invent or print a BYOK secret.
- No automated spoken utterance validates physical microphone capture, recognition quality or a live cloud account response. Automation proves the app lifecycle and current permissions, not real-world recognition.
- Visual state was exercised during previous user screenshots, but no screenshot baseline currently proves every notch geometry requirement across all Mac models.

## Detailed remaining work

### 1. Finish the BYOK first-run path

**Why first:** BYOK dictation works after configuration, but a cloud-first new user cannot complete it entirely in onboarding.

- `OnboardingWizard` filters out `.byok`; `OnboardingReadiness.engineIsReady(.byok)` returns false.
- Add a cloud configuration step to onboarding: explicit consent, HTTPS provider base URL, transcription model and secure Keychain secret save.
- Gate Continue on valid provider configuration and microphone permission only. Do not ask for Apple Speech permission on a BYOK-only setup.
- Test onboarding readiness, secret-save behavior, rejected endpoint behavior and session routing.

### 2. Complete models and profiles parity

- Add an optional per-app BYOK transcription-model override. Profiles currently choose the BYOK route but use the global BYOK model.
- Compare profile fields against JustSpeakToIt at `Sources/SpeakCore/DictationProfile.swift` and `Sources/SpeakApp/SessionProfileApplier.swift`.
- Implement only compatible, user-visible fields with a tested runtime effect. Candidate gaps to evaluate: per-profile model choice, directives/polish setup and richer external-route controls.
- Preserve legacy profile decoding and avoid changing global settings when a profile is activated.

### 3. Close JustSpeakToIt parity using evidence

- Re-run a user-level feature inventory against the current upstream/local reference, then classify each item as implemented, intentionally different, unsafe/not applicable or missing.
- Verify end-to-end flows: normal dictation, live insertion, final insertion, clipboard restore, selected-text editing, PTT, hands-free, profile switching, recording/history, language routes and translation/cleanup.
- Do not claim feature parity until the inventory has traceable code plus behavior test evidence.

### 4. Close jev-use desktop-control parity using evidence

- Re-inventory `JevDesktop/Desktop.swift` and related capture code. Compare user capabilities, not filenames.
- Test each supported control command with an accessibility fixture or controlled local target app.
- Candidate gaps needing investigation: menu-bar/menu-item targeting, double-click/open behavior, window geometry, rich candidate capture, Finder/desktop selection semantics and recovery when accessibility state changes.
- Keep confirmations, audit history and post-action observation for destructive or security-sensitive commands.

### 5. Visual and interaction proof

- Capture actual screenshots of compact, expanded and detached states on the target Mac.
- Prove no notch control falls beneath the physical camera cutout. Compact state must display the Sayso icon, not full wordmark.
- Confirm outside click collapses, Start does not unexpectedly close the panel, detach toggles back, settings/open works, quit works and only one process runs.
- Refine only defects observable in those captures. Do not create speculative visual systems.

### 6. Release proof

- Keep tests green, run code-signature validation and validate a fresh launch with automation status after every material slice.
- For distribution, use a valid `SAYSO_NOTARY_PROFILE`, run notarization, then re-check `spctl` and a freshly downloaded/installed artifact.

## Build, test and launch runbook

Run from the repository root unless a command says otherwise.

```zsh
cd /Users/stevengonsalvez/orca/sayso/macos
swift test
swift build --target SaysoNotch
./Scripts/package-app.sh
codesign --verify --deep --strict --verbose=2 '.artifacts/Sayso Notch.app'
```

Relaunch only the known Sayso tmux pane. Do not use bulk process or tmux termination commands.

```zsh
tmux send-keys -t dev-sayso-notch-1790188365:1.1 C-c
tmux send-keys -t dev-sayso-notch-1790188365:1.1 '"/Users/stevengonsalvez/orca/sayso/macos/.artifacts/Sayso Notch.app/Contents/MacOS/SaysoNotch" --automation-server 2>&1 | tee "/Users/stevengonsalvez/orca/sayso/macos/dev-sayso-app.log"' C-m
/Users/stevengonsalvez/orca/sayso/macos/.build/release/sayso status
pgrep -fl 'SaysoNotch|Sayso Notch' | wc -l
```

Expected status shape: version `1.0.0`, local model installation flags, `microphone=granted`, no active session unless deliberately recording.

## Commit, review and push discipline

Each file change is a separate signed atomic commit:

```zsh
cd /Users/stevengonsalvez/orca/sayso
git diff --check
git add path/to/one-file
git commit -S -m 'feat: concise single concern'
git fetch origin
node '/Users/stevengonsalvez/.codex/plugins/cache/sendbird/cc/1.5.0/scripts/claude-companion.mjs' review --view-state on-success --base origin/main --scope branch
git push origin main
```

Never stage with `git add .` or `git add -A`. Never use unsigned commits. Do not commit build artifacts, `.build`, `.artifacts`, secrets or transient agent scratch.

## Continuation protocol

1. Read this file and check `git status --short --branch` before editing.
2. Start with the BYOK onboarding gap. It is the narrowest unambiguous product gap and unlocks a complete cloud-first flow.
3. Trace all callers before changing shared settings/session code.
4. Add behavior-focused tests with the change, then run the full `swift test` suite.
5. Commit each changed file separately, run review and push `main`.
6. After each feature slice, package, launch only the known app pane, query automation status and record exact proof plus any remaining physical limitation.

## Handover acceptance criteria

The successor owns continuation when it has:

- Read this document and confirmed clean `main` at or after `35334d4`.
- Started the BYOK onboarding implementation or recorded an evidence-backed blocker.
- Kept the current safety boundaries for keys, accessibility control and destructive actions.
- Used signed per-file commits, tests, review and direct `main` push before calling a slice complete.
