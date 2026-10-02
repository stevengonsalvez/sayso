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
| Dictation module (phases as one activity, failure notice) | `DictationModuleTests` (incl. harness) | missing types | 446 | thin slice only: the app still owns the whole pipeline and just publishes `DictationPhaseChanged` from `transcriber.$phase/$error`; the module shows nothing while live (notch already shows live text). Dictation is NOT extracted. | none yet |
| Control module (run, clarification, review activities + typed answers) | `ControlModuleTests` (incl. generic harness) | missing event/module types | 446 | wired at the existing `controlStatus` sites in `SaysoAppModel`: run/step/clarification/review/finish events out, cancel/approve/deny/choice answers routed back to `cancelControl`, `approvePendingControl`/`discardPendingControl`, `runControl`; app builds; no live Control run, no Jev call, no AX action tested; guarded execution path untouched | none yet |

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

Still open: `ShortcutsModule` and `ShortcutIntentModule` double-fire if both are enabled next to the Carbon manager; the off-main key-down/up hop in `AppShortcutIntents` is two unordered tasks (unused today).

## Review tooling

Codex review was attempted and failed on a usage limit until 2026-10-07; Opus `code-reviewer` is the substitute.
