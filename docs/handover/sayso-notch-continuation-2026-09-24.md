# Sayso Notch continuation handover

- **Generated:** 2026-09-24 11:25:00 BST
- **Repository:** `/Users/stevengonsalvez/orca/sayso`
- **Active branch:** `main`, code head `67092c1`, docs at `cf14f9b`
- **Live development session:** `dev-sayso-notch-1790188365:1.1`

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
| `e9d9020` through `ea42442` | BYOK cloud-first onboarding wizard, models/profiles per-app model override, directive sync, element bindings, legacy consent migration fallback |
| `67092c1` | Packaged app runner script with robust root path, binary existence guard, and clean logging |

## Current verification evidence

All evidence below is from the current source head (`67092c1`).

- `swift test`, run in `macos`, passed **201 tests** in 8.4 seconds with zero failures.
- Package path is `macos/Scripts/package-app.sh`; it builds release, packages the app and verifies its code signature.
- Packaged app passed `codesign --verify --deep --strict --verbose=2`: `valid on disk` and `satisfies its Designated Requirement`.
- Live app is running once from `macos/.artifacts/Sayso Notch.app/Contents/MacOS/SaysoNotch --automation-server` in tmux session `dev-sayso-notch-1790188365:1.1`.
- Automation status reported `microphone=granted`, local English/Indic/Punjabi models installed, `speech=undetermined`, no active session and `dictation=idle`.
- CLI commands `sayso status`, `sayso history`, `sayso start`, and `sayso stop` verified against active socket.
- `pgrep -fl 'SaysoNotch|Sayso Notch'` confirms exactly one running process.
- Live microphone dictation physically verified: real spoken utterance captured by local FluidAudio engine and transcribed live into Sayso Notch.
- Visual state verified via `orca computer` and `screencapture` across compact, expanded, and detached floating presentations.

### Verification limits

- A signed local app is not a notarized release. `spctl` rejects the package until an authorized notarization profile is supplied through `SAYSO_NOTARY_PROFILE` (`SAYSO_NOTARY_PROFILE=not_set`).
- Real BYOK cloud transcription provider calls require user API keys. Provider integration is verified via protocol unit tests and HTTPS validation; keys stay strictly in Keychain.
- Automated tests prove component contracts, parsing, safety guards, and integration lifecycles. Real-world acoustic variations depend on hardware microphones.

## Delivered feature parity

### 1. BYOK first-run onboarding delivery

- `OnboardingWizard` contains a dedicated `.byok` cloud onboarding step.
- Requests provider base URL (HTTPS validated, localhost permitted for testing), transcription model name, and API secret.
- Stores API secret exclusively in `KeychainSecretStore`. Never writes secrets to `UserDefaults` or plaintext files.
- `OnboardingReadiness.engineIsReady(.byok)` requires `byokConsentGranted` and valid configuration (base URL, model, and keychain secret).
- `hasRequiredPermissions` verifies microphone permission while bypassing Apple Speech recognition permission for BYOK-only setups.
- Covered by unit tests in `SaysoCoreTests`: `byokRouteExemptFromSpeechRecognition`, `byokConfigurationValidationEnforcesHTTPSModelAndKey`.

### 2. Models and profiles parity delivery

- Added `transcriptionModelOverride`, `cleanupModelOverride`, and `cleanupDirectives` to `DictationProfileBundleOverride`.
- Conformed `DictationProfileBundleOverride` to `Identifiable` using normalized lowercased bundle identifier.
- Implemented `CleanupDirectivesEditor` with bidirectional text synchronization and element-level SwiftUI binding, preventing out-of-range mutation.
- Creating an application override automatically copies global cleanup directives as starting default.
- Per-app model overrides resolve at runtime for the foreground app without mutating global settings.
- Legacy profile decoding and legacy consent migration paths preserved.
- Covered by unit tests in `SaysoCoreTests`: `dictationProfileResolverNormalizesBundleIDAndUsesFirstMatch`, `whitespaceOnlyProfileModelOverrideIsIgnored`, `dictationProfilePostProcessingIsIdempotent`.

### 3. Evidence-based JustSpeakToIt parity (delivered core subset)

| Capability | JustSpeakToIt Reference | Sayso Implementation | Traceable Evidence |
|---|---|---|---|
| Live Partial Transcription | Real-time transcription HUD | `LiveTranscriber.swift`, `NotchPanelController.swift` | [manual] Live audio stream decoded by local FluidAudio engine and rendered in HUD; [test] `installedNativeMultilingualModelRoutesIndianLanguagesWithoutSpeechPermission` |
| Safe Live Insertion | Replacement region guard | `TextTools.swift` (`LiveTextRegion`) | [test] `liveTextRegionReplacesOnlyItsOriginalSelection` |
| Final Text Insertion | Active app AX/CGEvent delivery | `TextTools.swift`, `SaysoNotchApp.swift` | [test] `textOutputTargetIdentityRequiresCurrentAppAndFocusedFieldForEveryDelivery` |
| Clipboard Restoration | Save and restore clipboard | `TextTools.swift` (`restoreClipboardAfterPaste` parameter) | [test] `pasteFailureMessagesMatchVerifiedClipboardOutcomes` |
| Spoken Text Editing | Voice edit rewrite/delete | `Domain.swift`, `SaysoNotchApp.swift` | [test] `voiceEditsRequireExactCommandShape`, `voiceEditsMatchWholeTokensOnly` |
| Selection Anchors | Target selection tracking | `TextTools.swift` (`SelectedTextEditAnchor`) | [test] `selectedTextEditAnchorRequiresExactUTF16Selection` |
| Dictation Profiles | Per-app profiles and overrides | `DictationProfile.swift` | [test] `dictationProfileResolverNormalizesBundleIDAndUsesFirstMatch` |
| Application Profile Switching | Foreground app profile resolution | `DictationProfile.swift` | [test] `dictationProfileResolverNormalizesBundleIDAndUsesFirstMatch`, `dictationProfileSnapshotAppliesBundleOverrides` |
| Push-to-Talk and Tap Toggle | Configurable hotkey activation | `HotKeyEngine.swift`, `SaysoNotchApp.swift` | [test] `hotKeyDefaultsMatchExpectedShortcuts` |
| Lexicon and Cleanup | Text replacements and directives | `Domain.swift`, `DictationProfile.swift` | [test] `dictationProfilePrefersLongestCorrectionPhrase`, `localCleanupIsIdempotentAndKeepsIndianScripts` |
| BYOK Cloud Route | OpenAI-compatible audio API | `OpenAICompatibleAudioTranscriber.swift` | [test] `compatibleAudioTranscriberPostsMultipartAudioWithLanguage`, `byokRouteExemptFromSpeechRecognition` |
| Indian Languages | Multi-language catalog | `FluidAudioLocalModel.swift`, `SherpaPunjabiModel.swift` | [test] `installedNativeMultilingualModelRoutesIndianLanguagesWithoutSpeechPermission`, `PunjabiManifestPinsModelAndTokenizer` |
| Hands-Free Dictation | Continuous cycle with cooldown | `HandsFreeRearm.swift` | [test] `handsFreeCycleArmsOnlyForContinuousDictation`, `handsFreeSilenceWaitsForSustainedSpeechBeforeStopping` |
| History and Audio Archive | Journaled storage with replay | `HistoryStore.swift`, `SessionAudioArchive.swift` | [test] `journaledHistoryAppendRetainsAudioUntilReplay`, `clearingHistoryDeletesAllManagedRecordingsInItsConfiguredDirectory` |
| Automation Socket and CLI | Unix domain socket automation | `SaysoAutomationServer.swift`, `sayso` CLI | [manual] Runtime verified via socket IPC (`sayso status`, `sayso history`, `sayso start`, `sayso stop`) |

### 4. Evidence-based jev-use desktop control parity (partial grounded action subset)

| Capability | jev-use Reference | Sayso Implementation | Traceable Evidence |
|---|---|---|---|
| AX Candidate Capture | Bounded candidate tree search | `AXCandidateCapture.swift`, `DesktopControl.swift` | [test] `candidateIDIsStableForSameAXLocator`, `candidateStateExcludesProtectedAndDisabledControls` |
| Grounded Action Schema | Closed plan action types | `DesktopAction`, `ControlPlanStep` | [test] `controlPlannerUsesOnlyExactVisibleControlTitle`, `controlPlannerAllowsOnlyReviewedNavigationKeys` |
| Exact Title Click / Press | Single matching visible control | `DesktopControlPlanner.plan` (`click`) | [test] `controlPlannerUsesOnlyExactVisibleControlTitle`, `resolverUsesOneExactTargetableCandidate` |
| Ambiguity Rejection | Reject multiple matches | `DesktopControlResolver` | [test] `resolverRejectsAmbiguousTargetableCandidatesDeterministically` |
| Pointer Row Click | Targetable table and list rows | `DesktopControl.swift` (`supportsPointerClick`) | [test] `pointerRowPlannerUsesExactRowsAfterPressTargets`, `pointerRowsNeverResolveAmbiguousTitles` |
| Field Focus and Selection | Focus input / select row | `DesktopAction.focus`, `DesktopAction.select` | [test] `focusPlannerRequiresOneExactFocusableField`, `selectionPlannerRequiresOneExactSelectableRow` |
| Text Typing | Literal typing at focus | `DesktopAction.type` | [test] `controlPlannerGroundsTypeAgainstCurrentTarget` |
| Scroll Navigation | Counted and directional scroll | `DesktopAction.scroll` | [test] `controlPlannerSupportsBoundedCountedScrollAndReviewedWindowKeys` |
| App Lifecycle Control | Launch, switch, and quit | `DesktopControl.swift` (`open`, `switch to`, `quit`) | [test] `namedApplicationCommandsResolveExactlyAndRequireReview`, `namedApplicationLaunchValidationChecksBundleAtPlannedPath`, `namedApplicationCommandsRejectAmbiguousAndNonExactNames` |
| Browser and Folder Open | URL and folder navigation | `DesktopAction.open`, `DesktopAction.openFolder` | [test] `namedApplicationPlannerPreservesExplicitHTTPSNavigation`, `folderControlRequiresAnExistingExplicitDirectory` |
| Navigation and Window Keys | Tab, arrows, back, forward, close | `DesktopKey` (`goBack`, `goForward`, `nextTab`, `closeWindow`) | [test] `controlPlannerAllowsOnlyReviewedNavigationKeys` |
| Redo & Undo Navigation Keys | Cmd+Z and Cmd+Shift+Z key planning | `DesktopKey.undo`, `DesktopKey.redo` | [test] `controlPlannerSupportsBoundedCountedScrollAndReviewedWindowKeys` (planner only; layout resolution in source) |
| Destructive Action Gates | Mandatory confirmation | `ControlPlanStep.requiresConfirmation`, `DesktopAction.isDestructive` | [test] `controlPlannerRequiresReviewForDestructiveVisibleControl`, `destructivePressPolicyUsesCapturedTitleNotOpaqueLocator` |
| Audit History | Plan before/after fingerprints | `ControlAuditEntry`, `ControlEffect` | [test] `desktopFingerprintIgnoresTransientPointerVisibility`, `controlOutcomeRequiresObservedEffect` |

### Sayso voice mode transition (hybrid capability)

Sayso bridges dictation and desktop control by recognizing spoken mode switches during control sessions:

| Capability | Mode Design | Sayso Implementation | Traceable Evidence |
|---|---|---|---|
| Spoken Mode Switch | Hands-free transition back to dictation | `SaysoNotchApp.swift` (`handleVoiceModeSwitch`) | [manual] Spoken phrase "sayso switch to dictation" stops control session and re-arms dictation ready state |

### 5. Visual notch proof and interaction proof

Physical captures on live macOS display verified and committed in repository under `docs/handover/screenshots/`:
- **Compact Notch State** (`docs/handover/screenshots/notch-compact-crop.png`): Collapsed HUD (height: 42px) sitting at top center with amber Control pointer glyph. Note: in compact mode, Sayso displays an icon glyph rather than the full wordmark (waveform icon in Dictation mode, or cursor pointer icon in Control mode, per `macos/Sources/SaysoNotch/NotchPanelController.swift:146`). No controls appear in the central area corresponding to the MacBook camera cutout.
- **Expanded Notch State** (`docs/handover/screenshots/notch-expanded-crop.png`): Expanded 210px HUD in Control mode. Top bar shows 6 icon buttons (detach/attach, open window, settings gear, collapse chevron, hide xmark, power quit). Mode picker shows Dictation and Control (Control active in blue). Text area displays "Live words appear here." placeholder and primary button shows "Stop listening".
- **Detached Floating State** (`docs/handover/screenshots/notch-detached-crop.png`): Floating HUD repositioned on desktop in Control mode displaying live transcribed utterance ("i'm building so jetf is this so it's the sa..."). Main window mode picker is visible in the background behind the floating HUD.
- **Real Voice Dictation**: Manually observed utterance captured through physical microphone and transcribed live by local FluidAudio engine into the HUD text field.
- **Single Process and Clean Exit**: `pgrep` confirms exactly 1 process running; quit button and clean teardown verified.
- **HUD Interaction Proof**:
  - Collapse toggle: Tapped HUD body or chevron up button collapses expanded panel to compact 42px notch height (`NotchPanelController.swift:77`).
  - Start does not dismiss: Clicking "Start dictation" toggles live recording without closing the HUD (`NotchHUD.swift:195-207`).
  - Detach toggles presentation: Clicking detach button alternates between `.notch` (attached beside camera) and `.floating` (desktop-positioned overlay).
  - Open Settings and Open Sayso: Clicking open settings (`NotchHUD.swift:177`) or open app brings forward the full multi-section settings workspace.
- **Orca Computer-Use E2E Verification**:
  - App and window discovery: `orca computer list-apps` identified `Sayso Notch` (bundle ID `ai.sayso.notch`, PID 43382); `orca computer list-windows` resolved main window 34184 (1100x804).
  - Accessibility tree snapshot: `orca computer get-app-state` captured all 46 initial UI elements including sidebar navigation (Speak, Control, History, Languages, Models, Voice output, Settings).
  - Keyboard navigation and view synchronization: `orca computer press-key --key Down` navigated through sidebar elements, updating main content views dynamically. Verified Desktop Control view (status "Awaiting capture", instructions), Models view (active routes, local models, BYOK endpoint `https://api.openai.com/v1`, models `gpt-4o-mini-transcribe`, `gpt-4.1-mini`, secure API key redacted in Keychain), and Settings view (language, route, presentation, hotkey, profiles, directives, BYOK consent).
  - High-resolution window screenshots captured automatically by ScreenCaptureKit provider.

### 6. Release proof and packaging

- Packaging script `macos/Scripts/package-app.sh` builds release binaries, packages `Sayso Notch.app`, and applies codesigning.
- Runner script `macos/Scripts/run-packaged-app.sh` resolves root directory, validates binary existence, and logs output under `macos/dev-sayso-app.log`.
- Code signature verified with `codesign --verify --deep --strict --verbose=2`: `valid on disk` and `satisfies its Designated Requirement`.
- Gatekeeper boundary confirmed: `spctl` assessment correctly documents requiring `SAYSO_NOTARY_PROFILE` for distribution.
- Socket automation confirmed: `SaysoAutomationServer` responds to CLI status, history, start, and stop.

### 7. Open items and follow-up work

1. **Notarization Profile**: A local Apple Development signed app is not a notarized release. `spctl` rejects the package until an authorized notarization profile is provided via `SAYSO_NOTARY_PROFILE`.
2. **Live Cloud Account Provider Verification**: Provider contract, protocol serialization, and HTTPS endpoint checks are verified via unit tests; end-to-end cloud roundtrip requires user API credentials stored in Keychain.
3. **Advanced Accessibility Candidate Models**: Grounded control covers exact titles, pointer rows, scrolling, navigation keys, app launching, URLs, folders, undo, and redo. Extended candidate coverage (menu-bar items, double-click, window geometry arrangement, Finder selection semantics) remains open for subsequent iteration.
4. **Multi-Device Screenshot Baseline**: Notch geometry was physically verified on the local 16-inch MacBook Pro display; baselines across different MacBook notch dimensions and external monitors remain to be captured as hardware becomes available.
5. **Outside-Click Auto-Collapse**: Current HUD collapse is explicit (click toggle or chevron button); automatic outside-click collapse via NSEvent global/local monitor is tracked as an enhancement for subsequent UX polish.

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
2. Verify existing test baseline passes with `swift test` (201 tests across all suites).
3. Trace all callers before changing shared settings or session code.
4. Keep current safety boundaries: secrets stay in Keychain, destructive desktop actions require confirmation gates.
5. Add behavior-focused tests with any new change.
6. Commit each changed file separately with signed commits, run review, and push to `main`.
7. After each feature slice, package, launch only the known app pane, query automation status, and record exact proof plus any physical limits.

## Handover acceptance criteria and delivery status

The continuation handoff has achieved the following verifiable status:

- Delivered slices through `67092c1`: BYOK cloud onboarding wizard, per-app profile overrides, directive sync, element bindings, and runner script.
- All 201 automated tests passing across the test suite (`swift test`).
- Packaged release binary verified on disk with codesign (`codesign --verify --deep --strict --verbose=2`).
- Core jev-use desktop control grounded action subset verified (exact controls, pointer rows, navigation keys, redo planner, confirmation gates, and mode switching; extended candidate items tracked in Section 7).
- Visual notch HUD verified on macOS display across compact, expanded, and detached presentations with screenshot proof in `docs/handover/screenshots/`.
- Live speech transcription into HUD verified manually via local FluidAudio engine.
- Preserved Keychain-only secret security and confirmation-gated safety boundaries for desktop controls.
