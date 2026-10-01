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

## Carried review findings, not yet fixed

1. `macos/Sources/speak/main.swift`: mock dictation acceptance can pass without proving a partial insertion.
2. `JevControlBridge.swift`: TYPE_TEXT selection can strip boundary punctuation.
3. `NotchInteraction.swift`: collapse policy is not wired into the production controller.
