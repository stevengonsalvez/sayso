# Ultimate Notch proof ledger

Base: merged main `69cdcb0`. Baseline before any change: `cd macos && swift test` = 273 tests passed in 2 suites.

Every RED below was a focused `swift test --filter <name>` run observed before production code: either a compile failure on the missing wished-for API, or (stopped publish, pin edge cases, alert restore, concurrency) an assertion failure or crash on existing behavior.

## Wave 0 foundation modules

| Module | Acceptance spec | RED observed | GREEN (full suite) | Real integration | E2E batch |
|---|---|---|---|---|---|
| Activity engine | `ActivityEngine*Tests` | replace/rank, expiry, pin: missing API; restore, pin prune, pinned confirmation, critical-only: assertion failures | 295 | none, pure model | none yet |
| Module host and quarantine | `Module*Tests` | missing API; stale context publish; unserialized publish crashed 3 of 3 runs | 295 | none | none yet |
| Acceptance harness | `ModuleAcceptanceHarnessTests`, `Support/SaysoModuleAcceptance.swift` | missing harness type | 298 | none | none yet |
| Gallery scenario catalog | `GalleryScenarioTests` | missing catalog and surfaces | 299 | none | none yet |
| Gallery UI (SwiftUI card, filter, browser, executable) | `Tests/SaysoGalleryUITests` | missing types per slice | 319 | window launched by agent, no interaction or visual sign-off by me | none yet |
| TTS module (first extraction) | `SpeechPlanTests`, `TtsModuleTests` (incl. generic harness, async-cancel fake, replacement, disable-then-speak) | missing `SpeechPlan`, `TtsModule`, `SpeechSynthesizing`; voice-per-language API change; fake modelled on real async cancel (compile RED, then GREEN) | 330 | `SpeechOutput` adapted and `SaysoAppModel.speak/speakLatest` routed through module; app builds; AVSpeech audio unverified | batch 1 pending |

| History operation gate | `HistoryOperationGateTests` (truth table of the four legacy busy flags) | missing type | 328 | `SaysoAppModel` busy flags replaced by the gate; app builds; no runtime check of reprocess/import/clear UI | batch 1 pending |
| Platform event bus + module scopes | `EventBusTests`, `ModuleEventsTests` | missing bus/scope/emit API | 340 | none, in-process | none yet |
| History module (events, retry, recovery notice) | `HistoryModuleTests` (incl. generic harness) | missing types; later test-bug fix `isFinal` | 347 | Wired: all five `SaysoAppModel` transcript save sites call `HistoryModule.append`; app builds; no runtime check. Failure activities are not rendered yet (no host UI) | batch 1 pending |
| Shortcuts module (events, release on stop) | `ShortcutsModuleTests` (incl. generic harness) | missing types | 350 | NOT wired: no adapter over `SaysoShortcutManager` yet; app still handles hotkeys directly. Hotkey regressions are not observable in tests | none yet |
| Studio router | `StudioRouterTests` | missing router/route types | 361 | not wired to any Studio UI | none yet |
| External API v1 (listModules, publish, clear) + external module | `ExternalAPITests` (validation, no confirmations from scripts, disabled module, generic harness) | missing API types | 368 | handler only: NOT connected to the Unix socket transport; expiry ticker exists but is not attached to an app host | none yet |
| Expiry ticker + dispatch scheduler | `ExpiryTickerTests`, `DispatchSchedulerTests` | missing types; first scheduler test run on the main queue was flaky in the full suite, moved to a private queue | 374 | not yet attached to the app host (nothing renders or ticks activities yet) | none yet |
| Notch surface machine (hover 60ms peek, click pin, outside collapse, swipe, jump, top-edge) | `NotchSurfaceMachineTests` | missing type; first GREEN failed on float timing at exactly 60ms, fixed with epsilon | 382 | NOT wired: `NotchPanelController` still uses its own isCollapsed toggle | none yet |
| Gallery interactive notch simulator | `NotchSimulatorModelTests`, `NotchSimulatorRenderTests` | missing types, then stubbed assertion failures | 401 (agent reported 22 new vs 19 counted; I did not reconcile) | window never driven live; 3 rendered PNGs viewed by the agent | none yet |
| Vocabulary module (candidate suggestions, accept/dismiss/retry) | `VocabularyModuleTests` (incl. generic harness) | missing types | 407 | bridge `VocabularyBridge` over the real `SaysoCorrectionLearning` tested with a real temp store (409 pass); app enables the module and syncs candidates on store changes; app builds; suggestions are not rendered anywhere yet | none yet |
| Gallery notch simulator (model with injected clock + view) | `NotchSimulatorModelTests` (15), `NotchSimulatorRenderTests` (7) | missing types, then stub RED on assertions | 401 (agent claimed 22 new tests vs 19 observed delta, unreconciled) | PNGs read for 3 surfaces; no live window interaction | none yet |
| Vocabulary module (suggest, accept, dismiss, retry) | `VocabularyModuleTests` (incl. generic harness) | missing types | 407 | port adapter over `SaysoCorrectionLearning` and app wiring NOT written; corrections still flow directly | none yet |
| Activity progress | `ActivityProgressTests` | missing `progress` param | 411 | none | none yet |
| Models module + install reporter | `ModelsModuleTests` (incl. harness), `ModelInstallReporterTests` | missing types | 419 | wired in app via Combine on the model managers; retry handled for English and Punjabi only (multilingual retry is a silent no-op); downloads never exercised; no UI renders the progress activity | none yet |
| Activity presentation + status line in notch | `ActivityPresentationTests` | missing type | 422 | the notch status text now shows the primary module activity (title and percent) when not live; action buttons are NOT shown (no layout change was made blind); panel behavior unobserved | none yet |
| Shortcut intent module (events to intents, mirrors original switch) | `ShortcutIntentModuleTests` (incl. harness) | missing types | 425 | wired: `SaysoShortcutManager.onActionTriggered` now publishes `ShortcutTriggered` and the module calls the original handlers via a main-actor hop. HIGH RISK, unobserved: a regression would silently break hotkeys. The Shortcuts registration module itself is still unwired. | none yet |
| Cleanup (route + pipeline with local-rules fallback) | `CleanupRouteTests`, `CleanupPipelineTests` | missing types | 415 | wired into `SaysoAppModel.cleaned`; app builds; no live check against Ollama/BYOK; behavior preserved by reading the old branches | none yet |
| Control module (run, clarification, review activities + typed answers) | `ControlModuleTests` (incl. generic harness) | missing event/module types | 446 | wired at the existing `controlStatus` sites in `SaysoAppModel`: run/step/clarification/review/finish events out, cancel/approve/deny/choice answers routed back to `cancelControl`, `approvePendingControl`/`discardPendingControl`, `runControl`; app builds; no live Control run, no Jev call, no AX action tested; guarded execution path untouched | none yet |
| Module socket server + External API transport | `ModuleSocketServerTests` (real Unix socket: framing, 0600/0700, oversize rejected, stop removes, end-to-end publish) | missing server; full suite then FAILED twice in unrelated tests (history, audio archive) because my first version used process-wide `umask` while tests ran in parallel; fixed by dropping umask and relying on a private 0700 directory (two clean 450-test runs after) | 456 | wired opt-in only (`defaults write ... sayso.externalAPI.enabled -bool true`), default off, never run live | none yet |
| Dictation module (phase tracker, lifecycle events, Listening/Transcribing activity, Stop, failure notice) | `DictationPhaseTrackerTests`, `DictationModuleTests` (incl. harness), `DictationPhaseBridgeTests` | missing types per slice | 456 | wired: `transcriber.$phase` bridged to events, Stop routed to `startOrStopDictation`; app builds; dictation capture, partial insertion and delivery code untouched and not exercised live; no installed-app run | none yet |
| Notch status policy (critical review shown in every mode with explicit Approve/Deny, no tap-to-approve, menu Deny) | `NotchStatusPolicyTests` | missing type | 464 | wired in `NotchPanelController`/`SaysoAppModel`; app builds; buttons never clicked in a live notch; before this a Control review was hidden in Control mode and a tap on the status text ran the first action (Approve) | none yet |
| Studio router wiring (route to tab, capability to permission) | `StudioNavigationTests` (tab fallbacks, capability mapping), `StudioRouterTests` | missing `SaysoStudioNavigation` | 467 | wired via notch menu "Open in Studio" -> `SaysoAppModel.openStudio(forModule:)`; module host gating still ignores real permissions on purpose (enabling it would hide Control/Dictation activities); menu never clicked live | none yet |
| PR #54 review fixes for Control (step-bound Approve, single `endControl` exit, tap allowlist) | `ControlModuleTests` (stale approve, resolved elsewhere), `NotchStatusPolicyTests` (tap never runs clarification/cancel/confirmation) | missing `stepID`/`tapAction`; stale-approve fixed by action ids carrying the step | 470 | app wired: `pendingControlStepID`, `controlRunAnnounced`, `endControl`; app builds; the cancel-then-late-completion race and window-approve card dismissal are reasoned from code, not reproduced live | none yet |
| Clipboard module (Wave 1, first slice: privacy filter, history with 40/100/200/500 limit, link cleaner, polling via injected scheduler, copy back, temporary paste with restore, concealed restore) | `ClipboardPrivacyTests`, `ClipboardHistoryTests`, `ClipboardLinkCleanerTests`, `ClipboardModuleTests` (incl. harness, disabled-no-write), `PasteboardClipboardPortTests` (real NSPasteboard on an isolated unique board) | missing types per slice | 490 | NOT wired to the app (per -82). Adapter `sourceApp` is the frontmost app at snapshot time, an approximation. Not yet built: plain-text paste hotkey, smart actions, OCR, file shelf, AirDrop, capture | none yet |
| File shelf module (Wave 1: stage dropped files, dedupe by path, limit 10/20/50, missing-file pruning on a 5s check armed only while items exist, optional lifetime, open/reveal/remove/clear, drag-out URLs, scoped access released on remove/trim/stop) | `FileShelfModuleTests` (9 incl. generic harness) | missing types | 506 | NOT wired. Real adapter `FileSystemShelfPort` written (FileManager attributes, readability check, security-scoped start/stop when the URL carries a scope, injectable open/reveal); tested on a temp dir (3 tests, 509 total) but real NSWorkspace open/reveal and real scoped URLs from a drag are NOT exercised; drag in/out UI not written; items are in memory only; the pruning timer is the injected scheduler, not exercised with real time | none yet |

## Proof boundaries

- All proof is synthetic and in-process. No installed-app run, no real macOS adapter, no performance measurement yet.
- No existing dictation, Control, TTS, history, CLI, MCP code has been moved yet; the 273 baseline tests still pass.
- Per-commit RED/GREEN raw output is not archived here; the commit sequence (test commit, then implementation commit) is the record.
- TTS wiring in `SaysoNotchApp.swift` has no automated test (app target has no test target); only build success and the pure `SpeechPlan` tests back it. Behavior change: an explicit `.automatic` language now falls back to the settings language.
- Opus review of gallery UI and TTS found: double-speak dropped the live activity, speak after disable played audio, system Reduce Motion ignored, fake Grant/Retry buttons. TTS items fixed with tests; gallery items assigned and pending (check git log).
- History module is wired via direct `append` (returns the result for completion notices). Dictation does not yet emit `TranscriptCompleted`; that event path is proven only in module tests.
- Known gap: TTS commits `4a85c81` to `69b7d49` do not build alone (protocol signature changed across files).
- Known gap: gallery commits `11e7411` and `af76582` do not build alone (Package.swift precedes sources).
- Known gap: intermediate commit `1cb32cf` leaves `ActivityEnginePinTests` failing until `3f13213`.

## Carried review findings

1. `macos/Sources/speak/main.swift` acceptance: FIXED. `AcceptanceVerdict` (RED: missing type; GREEN, full suite 357) now requires at least one applied partial (for texts over two words), non-clipboard insertion, and a readable target value containing the dictated text. The CLI itself still runs only against a real app and was not run here.
2. `JevControlBridge.swift` TYPE_TEXT boundary punctuation: FIXED with `JevTypeTextPunctuationTests` (RED: 3 assertion failures, then GREEN, full suite 352). Only a wrapping quote pair is dropped now.
3. `NotchInteraction.swift` collapse policy: outside-click collapse now calls `NotchCollapsePolicy`. Status and footer buttons still call the toggle directly and the controller has no test target, so this is only partly wired and unverified at runtime. OPEN (partial).

## Packaging proof (2026-10-02)

`macos/Scripts/package-app.sh` at head `404109d` built the release `SaysoNotch` product (210 s), assembled `.artifacts/Sayso Notch.app` and passed `codesign --verify --deep --strict`; `spctl` rejects it as expected (not notarized). The app was NOT launched: Stevie's installed `/Applications/Sayso Notch.app` is running and shares the automation socket, hotkeys and microphone, so a second instance would break the one-packaged-process rule. No runtime proof of any wired module exists.

## Review round 2026-10-02 (Opus x2, peer Opus)

Fixed with tests: ticker overwrote the change observer; ready notice restored "Downloading 100%"; vocabulary suggestions never cleared when resolved elsewhere; progress noise and unknown fraction. Fixed in app code without tests (build only): the expiry ticker is now attached; module status ranks below control status in Control mode; tapping the status runs the primary action (Retry/Remember/Stop) and the More menu has "Dismiss notification"; multilingual model retry installs for the current language. Cleanup module (`CleanupRoute`, `CleanupPipeline`) merged from peer branch by cherry-pick; its tests pass in the full suite (440).

Pre-existing hazard noticed, not fixed: `SaysoAutomationServer.makeSocket` also toggles process-wide `umask` during socket creation, which can race with other file creation at startup.

Still open: `ShortcutsModule` and `ShortcutIntentModule` double-fire if both are enabled next to the Carbon manager; the off-main key-down/up hop in `AppShortcutIntents` is two unordered tasks (unused today).

## Exact-head CI

PR #54 at `057f9d1` and again at `3110803` (exact head): `build` pass and `Test and package` pass (GitHub Actions). Later heads re-run CI; check the PR for the current state. Not proof of runtime behavior.

PR #54 review round 3 (peer Opus): Control approve/step binding, double or missing `ControlRunFinished`, tap-action allowlist assigned to peer; permission gate (`isGranted`, `capabilitiesChanged`) deliberately NOT enabled yet because it would flip Control/Dictation to permissionRequired and hide their activities; minors fixed here: boolean version rejected, external stack cap (32), cancelled install clears its card, shortcut intent switch lists every ignored edge. One commit (`7359cc9`) carried three test files because of a staging slip.

Control review fixes (peer, cherry-picked): confirmations bound to a step id (stale answers rejected), single `endControl` exit so exactly one `ControlRunFinished` per run, status tap runs only an allowlisted retry on the painted activity. One transient `index.lock` made my cherry-pick skip one commit; head `c622c0a` was pushed with an app build error for about a minute before `736151b` fixed it (474 pass, builds).

## Installed-app smoke, partial (2026-10-02, head `0f61b77`)

Stevie's installed app was not running, so a copy packaged to `macos/.artifacts` (not the `/Applications` app) was launched from tmux and quit by exact pid. OBSERVED: the app launches with all modules wired and no crash; `sayso status` returns ok (microphone granted, dictation idle); `sayso history` returns the existing history entries (data intact); with the opt-in default set, `modules.sock` appears and a real framed JSON session returned all 8 modules (vocabulary, models, shortcut-intents, dictation, control, external `ready`; tts and history `disabled` until first use because they enable lazily), `publish` returned ok and a `confirmation` publish was rejected `invalid_kind`. The temporary default and sockets were removed afterwards.

NOT OBSERVED: the status-line text of the published activity (the screenshot showed a collapsed Dictation pill and a partly hidden window, nothing conclusive), TTS audio, hotkeys, dictation into TextEdit/Arc/WhatsApp/Finder, Control approve/deny, model download progress. The batch-1 runbook is still unrun.

## Main merged in (2026-10-03)

`origin/main` (4d962cf: cloud STT providers, streaming transcripts with instant hotkey stop, minimize button) was merged by a peer on a side branch and fast-forwarded here as `ceedbf9`. Two trivial conflicts (property block, notch status model: main's `livePreviewText` is fed into `NotchStatusPolicy` so critical reviews and tap rules still apply). Verified by me: app builds, 538 tests pass in 3 suites. All eight history save sites still go through `appendToHistory`. NOT verified: that main's streaming and instant-stop paths behave with the module wiring at runtime.

## Review tooling

Codex review was attempted and failed on a usage limit until 2026-10-07; Opus `code-reviewer` is the substitute.

## Clipboard and File shelf review fixes (Opus, 2026-10-02)

Fixed with tests first (523 pass): full-pasteboard capture and verbatim restore (images, files, rich text, markers) via `ClipboardContents`; empty previous clipboard stays empty; sensitive previous item (marker types) is cleared, never restored; `pasteTemporarily` contract now states `perform` must verify the insertion before returning; wider marker types (AutoGenerated, Petermaurer transient, TypeIt4Me, 1Password) and a password-manager bundle-id deny-list (needs `sourceBundleID`, set from the frontmost app, an approximation of the copier); 256 KB text cap; clean-link offer bound to the copy's change count and dropped on any newer copy; polling uses a generation token (no double chain after stop/start); pending copies are drained before our own writes; adapter snapshot re-reads until count is stable; shelf: no grant survives a stop during `add`, stopped runtime detached, refresh decided under one lock, prune publishes once, per-grant counting in the fake so leaks fail.

Not fixed on purpose: `resolve` before `acquire` for bookmark-resolved URLs (no bookmark or persistent shelf flow exists yet; revisit when persistence is built); app-level source detection is still the frontmost app, not the true copier (NSPasteboard does not expose it); restoring other apps' promised/lazy data is best-effort (only data present at capture time is kept).

Still unwired and unrun: the `perform` verification contract is documented, not enforced by types, and the real Accessibility readback is not written.
