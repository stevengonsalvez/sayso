# Upstream Parity Report: justspeaktoit (2026-11-19)

- Date: 2026-11-19
- Upstream repository: https://github.com/crmitchelmore/justspeaktoit
- Upstream range: alpha-build-162 through alpha-build-166, all dated 2026-11-18. Only 162, 163 and 166 were published; 164 and 165 are drafts (the GitHub release API reports `isDraft: true`), so their notes describe unreleased builds.
- Baseline commit before range: `7fbeed1c00d1da180ff49595c088b2ff5bfbeb0e` (alpha-build-161 source)
- Tag commit SHAs reviewed:
  - alpha-build-162: `a80a0b96c49affdfc77416d2634a197f331e341b` (baseline `6eb1028a81bea5c8ae467a05648bbc71b6fb5e24`)
  - alpha-build-163: `f902cf27743ee7098f47982718306268a620af93` (baseline `eeb7c9bb3c580a54f118fec12e054d734485dad0`)
  - alpha-build-164: `fc7cd4c7549511e596ff5d47019f3e70f3f3f34c` (baseline `5384820e2987f9345ff010b45c62f0e8c7815886`)
  - alpha-build-165: `94c0eb7a315ffde9c49689b186b0000a103ad8b0` (baseline `fc7cd4c7549511e596ff5d47019f3e70f3f3f34c`)
  - alpha-build-166: `37d65a49a88ef62735c525b1120ac496f9e7bc2a` (baseline `e70b7e0ac950388557ab1d6937db507d4e46938a`)
- Evidence gathering method:
  - Public GitHub Releases API via `gh release view <tag> -R crmitchelmore/justspeaktoit`.
  - Tag objects, commit histories, PR bodies, and changed files queried via `gh api` across PRs #1830, #1831, #1832, #1834, #1835, #1816, #1836, #1838, #1839, #1840, #1841, #1842.
  - Upstream source files inspected in `Sources/SpeakCore/App/CloudSharingConsent.swift`, `Sources/SpeakCore/AppleUI/CloudSharingConsentSheet.swift`, `Sources/SpeakCore/TTS/Providers/RealtimeReadingCheck.swift`, and `Docs/research/sherpa-onnx-tts-spike.md`.
  - Local Sayso inspection across `macos/Package.swift`, `macos/Package.resolved`, `macos/Sources/`, and `docs/`.

## Summary

Ten distinct upstream changes were analyzed across alpha-build-162 through alpha-build-166. Sayso macOS partly implements one feature (coarse cloud consent booleans) and does not implement the remaining nine. The highest-priority candidate for Sayso is the per-provider, per-data-kind Cloud Sharing Consent architecture from SpeakCore, which would replace Sayso's coarse boolean flags. Upstream cites App Review guideline 5.1.2 for its own App Store builds; Sayso ships by Developer ID outside the Mac App Store (see `docs/macos-release-plan.md`), so for Sayso this is a privacy best practice, not a store requirement. The second candidate is the Sherpa-onnx local TTS evaluation (Pocket TTS) to expand Sayso's existing Sherpa integration beyond Punjabi ASR into offline voice output. The third candidate is the Realtime reading check sign and decimal disambiguation logic if Sayso implements read-aloud verification.

## Findings

1. **Per-provider Cloud Sharing Consent is the primary architectural gap.**
   Upstream PR #1835 (alpha-163) added `CloudSharingConsent`, `CloudSharingConsentStore`, `CloudSharingProviderCatalogue`, and `CloudSharingConsentSheet` to `SpeakCore`. PR #1840 (alpha-165, a draft build) added the Windows and Linux consent side (`CWindowsSupport`, `CLinuxSupport`, `SpeakDesktop/Shell/DesktopCloudSharingConsentStore.swift`), not the SpeakCore types. Sayso defines 22 cloud providers in [CloudProviderCatalog.swift](../../macos/Sources/SaysoCore/CloudProviderCatalog.swift#L150-L1026) but gates them only with coarse booleans (`cloudConsentGranted`, `byokConsentGranted`, `voiceEditCloudConsent`) in [Domain.swift](../../macos/Sources/SaysoCore/Domain.swift#L295-L297) and [SaysoNotchApp.swift](../../macos/Sources/SaysoNotch/SaysoNotchApp.swift#L1298). Sayso lacks per-provider granularity, per-data-kind separation (audio, transcript text, text-to-speak), privacy policy URLs, and first-upload consent sheets.

2. **Upstream researched in-process Sherpa-onnx TTS while Sayso uses Sherpa-onnx only for ASR.**
   Upstream PR #1836 (alpha-163) documented an in-process TTS spike using `sherpa-onnx` 2.0.1 C API with Pocket TTS, Kokoro, and ZipVoice in `Docs/research/sherpa-onnx-tts-spike.md`. Sayso pins `sherpa-onnx` exact 2.0.1 in [Package.swift](../../macos/Package.swift#L25-L27) and [Package.resolved](../../macos/Package.resolved#L58-L65), but exclusively uses it for local Punjabi ASR in [SherpaPunjabiModel.swift](../../macos/Sources/SaysoCore/SherpaPunjabiModel.swift#L1-L100). Sayso's TTS module in [TtsModule.swift](../../macos/Sources/SaysoCore/Tts/TtsModule.swift#L1-L50) and [SpeechSynthesizing.swift](../../macos/Sources/SaysoCore/Tts/SpeechSynthesizing.swift#L1-L12) delegates exclusively to system `AVSpeechSynthesizer`.

3. **Sayso's upstream dependency pin is a 2-commit branch that upstream main does not contain, so a plain bump is not safe.**
   In [Package.swift](../../macos/Package.swift#L18) and [Package.resolved](../../macos/Package.resolved#L27), Sayso pins `justspeaktoit` revision `bd06625ff62e0f9b3ae9743312723420adc966bc` from 2026-09-29. In [SpeakUpstreamBridge.swift](../../macos/Sources/SpeakUpstreamBridge/SpeakUpstreamBridge.swift#L7), an older constant references `0f0e92028a249e17b58349da3ee8033c73ffd219` (2026-09-19). Upstream checked 2026-11-19: `bd06625f` is not on upstream main. It sits on the unmerged branch `feat/speak-hotkeys-triple-tap`, two commits on top of `0f0e9202`, with no pull request, and upstream main is about 400 commits ahead. Sayso uses `.tripleTap` in `SaysoNotchApp.swift` and `ShortcutDomain.swift`, and upstream main at `37d65a49` has no `tripleTap` in `HotKeyTypes.swift` or `GestureDetector.swift`. So moving the pin to main would drop triple-tap, which is a known break. Getting upstream's `CloudSharingConsent` types therefore means either re-landing triple-tap upstream first, or copying the consent types into Sayso instead of bumping the dependency [inference].

4. **Multiple upstream changes are platform-specific to non-macOS targets or telemetry.**
   PR #1816 (iOS keyboard deep linking), PR #1838 (Android iCloud token restore), PR #1831 (CI token secret), PR #1832 (PostHog telemetry flushing and CI stamping), and PR #1839 (compact QA URL script) do not apply to Sayso macOS. Sayso has no telemetry code (no match for PostHog, telemetry or analytics in `macos/Sources`, searched 2026-11-19) and targets macOS only.

## Details

### Parity Table

| Feature | Upstream build and source | Does Sayso macOS have it (yes, partly, no, unknown) with the file or doc that shows it | Gap | Port order (1 = first) and a one-line reason |
|---|---|---|---|---|
| Per-provider and per-data-kind Cloud Sharing Consent gate and store | alpha-build-163 (PR #1835, commit `10e27bfe`; PR #1840 in draft build 165 adds only the Windows and Linux side). Files: `Sources/SpeakCore/App/CloudSharingConsent.swift`, `CloudSharingConsentStore.swift`, `Sources/SpeakCore/AppleUI/CloudSharingConsentSheet.swift`. | Partly. [Domain.swift](../../macos/Sources/SaysoCore/Domain.swift#L295-L297), [SaysoNotchApp.swift](../../macos/Sources/SaysoNotch/SaysoNotchApp.swift#L1298), [SaysoNotchApp.swift](../../macos/Sources/SaysoNotch/SaysoNotchApp.swift#L1622), [SaysoNotchApp.swift](../../macos/Sources/SaysoNotch/SaysoNotchApp.swift#L1843). | Sayso has 3 coarse global booleans (`cloudConsentGranted`, `byokConsentGranted`, `voiceEditCloudConsent`). Sayso lacks per-provider grants, per-data-kind isolation (audio vs transcript text vs text-to-speak), privacy policy URLs, and first-use consent modal sheet before uploading data. | 1. Essential privacy control for Sayso's 22 cloud providers. Upstream cites App Review 5.1.2 for its own App Store builds; Sayso is Developer ID, so this is a best practice rather than a store requirement. Do not bump the pin to get it (see finding 3). |
| Sherpa-onnx in-process TTS spike and architecture (Pocket TTS, Kokoro, ZipVoice) | alpha-build-163 (PR #1836, commit `f902cf27`). File: `Docs/research/sherpa-onnx-tts-spike.md`. | No. [Package.swift](../../macos/Package.swift#L25-L27), [SherpaPunjabiModel.swift](../../macos/Sources/SaysoCore/SherpaPunjabiModel.swift#L1-L100), [TtsModule.swift](../../macos/Sources/SaysoCore/Tts/TtsModule.swift#L1-L50), [SpeechSynthesizing.swift](../../macos/Sources/SaysoCore/Tts/SpeechSynthesizing.swift#L1-L12). | Sayso links `sherpa-onnx` 2.0.1 but uses it only for Punjabi ASR. Sayso's TTS uses local system `AVSpeechSynthesizer` only, with no in-process neural TTS engine. | 2. Could enable offline neural voice synthesis using Sayso's already linked `sherpa-onnx` runtime once licensing is resolved [inference]. |
| Realtime reading check decimal point and operator sign word rejection | alpha-build-162 (PR #1830, commit `aad604d4`). File: `Sources/SpeakCore/TTS/Providers/RealtimeReadingCheck.swift`. | No. [TtsModule.swift](../../macos/Sources/SaysoCore/Tts/TtsModule.swift#L1-L50), [CloudProviderCatalog.swift](../../macos/Sources/SaysoCore/CloudProviderCatalog.swift#L257). | Sayso does not implement OpenAI Realtime read-aloud verification or verbatim reading checks. | 3. Useful if Sayso adds audio reading verification or verbatim read-aloud checking. |
| Desktop cloud sharing consent manual QA check specifications | alpha-build-163 (PR #1834, commit `95b34f00`), alpha-build-166 (PR #1841, commit `e70b7e0a`). File: `Docs/manual-checks.yml`. | No. [PROOF_LEDGER.md](../../docs/ultimate-notch/PROOF_LEDGER.md) has manual and synthetic proof rows for other modules but none for cloud consent. | Sayso has a proof ledger and an E2E runbook, but no check rows for cloud provider consent gates and withdrawal. | 4. Complements the port of Feature 1 to ensure manual verification coverage. |
| Test isolation helper for cloud sharing consent (`CloudSharingConsentTestSupport`) | alpha-build-166 (PR #1842, commit `37d65a49`). File: `Tests/SpeakiOSTests/CloudSharingConsentTestSupport.swift`. | No. [SaysoCoreTests](../../macos/Tests/SaysoCoreTests/). | Sayso test suite does not include setup and teardown fixtures for cloud sharing consent states. | 5. Prevents test pollution when Sayso adopts granular consent checks in unit tests. |
| Desktop telemetry flush before exit (`finishCleanly`) and PostHog key stamping | alpha-build-162 (PR #1832, commit `a80a0b96`). Files: `Sources/SpeakDesktop/Telemetry/DesktopTelemetry.swift`, `.github/workflows/`. | No. No match for PostHog, telemetry or analytics in `macos/Sources` (searched 2026-11-19). | Sayso contains no telemetry, analytics, or PostHog code. | Not worth porting. Sayso has no telemetry or analytics code, and data leaves the Mac only through a cloud route the user enables, so telemetry would contradict the in-app privacy text. (`sentry-cocoa` is in `Package.resolved` transitively; no `macos/Sources` file imports it.) |
| iOS Keyboard Extension Connect deep link (`justspeaktoit://keyboard-connect`) | alpha-build-163 (PR #1816, commit `eeb7c9bb`). Files: `JustSpeakKeyboard/`, `Sources/SpeakCore/Keyboard/Apple/KeyboardConnectLink.swift`, `Sources/SpeakiOS/Services/DeepLinkRouter.swift`. | No. [Package.swift](../../macos/Package.swift#L5-L14). | Sayso is a macOS desktop notch app, not an iOS keyboard extension. | Not worth porting. iOS keyboard extension is outside Sayso macOS scope. |
| Android iCloud History sync restoration from auto-backup | alpha-build-164 (PR #1838, commit `5384820e`). Files: `sync/WebAuthTokenBackup.kt` and `WebAuthTokenRestoreTest.kt` under the Android app. | No. [HistoryStore.swift](../../macos/Sources/SaysoCore/HistoryStore.swift#L1-L50). | Sayso stores history in local JSON files only; it has no CloudKit sync and does not run on Android. | Not worth porting. Android and CloudKit sync are outside Sayso macOS architecture. |
| CloudKit token CI secret ingestion for automated builds | alpha-build-162 (PR #1831, commit `6eb1028a`). Files: `.github/workflows/alpha-release.yml`, `android.yml`. | No. [Package.swift](../../macos/Package.swift). | Sayso does not build or distribute CloudKit sync targets. | Not worth porting. Infrastructure concern for upstream multi-platform sync. |
| Compact QA verification ID encoding in landing page scripts | alpha-build-164 (PR #1839, commit `fc7cd4c7`). Files: `landing-page/qa/manual-checks.mjs`, `landing-page/qa/results-format.mjs`. | No. [PROOF_LEDGER.md](../../docs/ultimate-notch/PROOF_LEDGER.md). | Upstream-specific website URL length handling for manual QA links. | Not worth porting. Tooling for upstream website only. |

### Not Worth Porting

1. **Desktop Telemetry / PostHog Key Stamping (PR #1832, alpha-162):**
   A search of `macos/Sources` finds no PostHog, telemetry or analytics code, and individual module panes state that nothing is sent anywhere (for example the calculator, file tools and snippets text in the Notch & HUD pane). Cloud routes the user turns on are the exception. Adding telemetry would contradict that stated behaviour. [inference: the absence is a product choice rather than an oversight; no document states it as a rule.]

2. **iOS Keyboard Extension Connect Link (PR #1816, alpha-163):**
   This feature addresses a specific UIKit responder-chain limitation in iOS custom keyboard extensions. Sayso macOS is an AppKit/SwiftUI notch application on macOS v14+. It has no iOS keyboard extension target.

3. **Android iCloud History Sync Restoration (PR #1838, alpha-164):**
   This PR mirrors the CloudKit web authentication token into an Android Auto Backup file so it survives a device transfer; its body says it does not use Google Play Restore Credentials. Sayso does not run on Android and does not sync history to CloudKit; Sayso's `HistoryStore.swift` persists records to local application support storage.

4. **CloudKit Secret Ingestion from Main-Only CI Environments (PR #1831, alpha-162):**
   Upstream CI configuration for publishing and signing CloudKit tokens. Sayso does not use CloudKit sync.

5. **Compact QA Manual Test ID String Encoding (PR #1839, alpha-164):**
   Upstream landing page JavaScript fix to compress manual test URLs under 7500 characters. Sayso uses markdown proof ledgers (`docs/ultimate-notch/PROOF_LEDGER.md`).

### Unknown or Could Not Verify

1. **Pocket TTS Upstream Licensing Clarification:**
   Upstream's research in `Docs/research/sherpa-onnx-tts-spike.md` identified an unresolved contradiction in the `sherpa-onnx-pocket-tts-int8-2026-01-26` package between its CC-BY-4.0 LICENSE file and a non-commercial clause in its README. Whether this model can be distributed in commercial Sayso builds remains unverified without upstream confirmation.

2. **Sherpa-onnx In-Process TTS Benchmarks on macOS Apple Silicon:**
   Upstream tested Sherpa-onnx TTS only on Linux x64 (Intel Core i7-4870HQ). Latency, memory footprint, and real-time factor (RTF) on macOS arm64 Apple Silicon are marked pending in upstream documentation and could not be verified directly [inference: sherpa-onnx runs on the ONNX Runtime CPU path, so Apple Silicon is likely faster than a 2013 Intel x64 host, but this is unmeasured].

3. **Direct Swift Package Dependency Bump Compatibility:**
   Sayso pins `justspeaktoit` revision `bd06625ff62e0f9b3ae9743312723420adc966bc` in `macos/Package.swift`. Upgrading directly to `37d65a49a88ef62735c525b1120ac496f9e7bc2a` (alpha-build-166) may introduce breaking API changes in `SpeakHotKeys` or `SpeakAutomationKit`. The triple-tap difference above makes a break certain for hotkey code. Nothing was built to check anything else, so the rest of the bump's compile status is unverified.

## Unverified / Open Questions

1. **Does upstream SpeakCore `CloudSharingConsentSheet` render cleanly inside Sayso's floating Notch window?**
   `CloudSharingConsentSheet` is written in SwiftUI with a minimum macOS frame size of 440x320 points (`Sources/SpeakCore/AppleUI/CloudSharingConsentSheet.swift`). Sayso Notch operates in compact screen regions near the camera housing. Whether it should be presented as a standard AppKit sheet from `NotchPanelController` or within a dedicated settings window cannot be verified without UI execution.
2. **Has upstream settled the choice between Pocket TTS and ZipVoice?**
   The upstream spike document `Docs/research/sherpa-onnx-tts-spike.md` (lines 236 to 238) lists next steps as "Owner: settle Pocket TTS against ZipVoice-only using the licence facts" and "Ask the package exporter or Kyutai whether the sherpa Pocket TTS package may be used commercially". Upstream git history up to alpha-build-166 shows no follow-up commit closing these questions.
