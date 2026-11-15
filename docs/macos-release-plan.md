# macOS release plan (Sayso Notch)

Status: plan only. Nothing here has been run, bought or signed up for. No secret values appear in this file or the linked issue, only secret names.

Tags used below: **[verified]** = checked against a file in this repo or the packaged app at plan time. **[general knowledge]** = Apple or Sparkle behaviour from memory, not re-checked against docs here. Check those before building on them.

## Recommendation

Start Apple Developer Program enrolment now (it is the only blocking step and verification can take days [general knowledge]). In parallel build everything that does not need the account: version stamping, DMG script, release workflow with ad hoc fallback, Sparkle behind a flag, appcast generation. When the account lands, the remaining work is adding five environment secrets to `macos-release` and cutting one tag.

```
 now (no account)                     blocked (needs account)
 ┌────────────────────────┐           ┌──────────────────────────┐
 │ M1 stamp version,      │           │ M4 enrol, cert, secrets, │
 │    notary via API key  │           │    first notarised tag   │
 │ M2 DMG script + release│──────────▶│ M5 TCC survival test,    │
 │    workflow (ad hoc)   │           │    live Sparkle update   │
 │ M3 Sparkle behind flag │           │ M6 deltas, universal     │
 └────────────────────────┘           └──────────────────────────┘
```

## What exists today (verified)

| Fact | Source |
|---|---|
| App is built by `swift build -c release --product SaysoNotch`, then hand-assembled into `macos/.artifacts/Sayso Notch.app` (one Mach-O, Info.plist, AppIcon.icns). No Xcode project builds the app (`project.yml` only defines the UI test bundle). | `macos/Scripts/package-app.sh`, `macos/project.yml` |
| Signing identity order: `SAYSO_CODESIGN_IDENTITY`, else `-` (ad hoc) when `CI` is set, else first local "Apple Development" identity, else `-`. | `package-app.sh` |
| Already signs with `--options runtime --timestamp --entitlements macos/Resources/SaysoNotch.entitlements`. So hardened runtime is on. | `package-app.sh`; packaged app shows `flags=0x10000(runtime)` |
| Notarisation already scripted but only via `SAYSO_NOTARY_PROFILE` (a local `notarytool` keychain profile), zip submit, then `stapler staple`. Not usable in CI as is. | `package-app.sh` |
| `spctl --assess` result is swallowed (the command is followed by a forced `true`). | `package-app.sh` |
| Entitlements: `com.apple.security.device.audio-input` and `com.apple.security.automation.apple-events`. Nothing else. | `macos/Resources/SaysoNotch.entitlements` |
| Usage strings present: Microphone, Speech Recognition, Apple Events, Input Monitoring. Bundle id `ai.sayso.notch`. Version is hard-coded `1.0.0` / build `1`. Min macOS 14.2. | `macos/Resources/Info.plist` |
| App is not sandboxed (so Developer ID direct distribution, not Mac App Store). | `docs/ultimate-notch/PROOF_LEDGER.md` (File shelf entry) |
| Packaged app is a single arm64-only Mach-O with no embedded frameworks or non-system dylibs. | `otool -L` and `file` listing of an existing local package |
| CI: `macos.yml` builds, tests, packages ad hoc (`SAYSO_CODESIGN_IDENTITY: "-"`), checks the audio-input entitlement, uploads a 7-day artifact. Permissions `contents: read`. Actions are pinned by SHA. It also triggers on `v*` tags but has no release job. | `.github/workflows/macos.yml` |
| Android already releases on `v*` tags (`v1.0.32` is the latest GitHub release, assets are `.apk` and `.aab` only) using secrets named `SAYSO_KEYSTORE_B64`, `SAYSO_KEYSTORE_PASSWORD`, `SAYSO_KEY_ALIAS`, `SAYSO_KEY_PASSWORD`, `PLAY_STORE_JSON_KEY`. | `.github/workflows/android.yml`, `gh release list`, `gh secret list` |
| No Sparkle in `macos/Sources`. Sparkle 2.10.0 is pinned in `Package.resolved` only transitively, because upstream `justspeaktoit`'s `SpeakApp` target uses it; Sayso does not depend on that target. | `macos/Package.resolved`, upstream `Package.swift` in `.build/checkouts` |
| The Mac used for this plan has no "Developer ID Application" identity (only Apple Development and Apple Distribution identities). | `security find-identity -v -p codesigning` |

Two repo facts that shape the plan:

1. **Tag collision.** `v*` is already the Android release tag and GitHub's "Latest" release is an Android release. macOS needs its own prefix, `macos-v1.2.3`, and its own update feed location (see section 3). `macos.yml` should change its tag filter from `v*` to `macos-v*` when the release workflow lands.
2. **Version is not stamped.** `CFBundleVersion` is the literal `1`. Sparkle compares `CFBundleVersion`, so every release must stamp a strictly increasing value.

## 1. Developer ID signing and notarisation in CI

### Environment secrets in `macos-release` (names only)

All values below are stored as secrets of the GitHub Environment `macos-release`, NOT as repository secrets. A repository secret is readable by any workflow job on any branch or tag that can run, so it would bypass the environment's reviewer gate. An environment secret is released only to a job that declares `environment: macos-release` and passes that environment's protection rules.

Prefix `SAYSO_MACOS_` follows the existing `SAYSO_` Android convention.

| Name | Holds | Notes |
|---|---|---|
| `SAYSO_MACOS_CERT_P12_B64` | base64 of the exported Developer ID Application certificate and private key (.p12) | Android uses the same base64-file pattern |
| `SAYSO_MACOS_CERT_PASSWORD` | password of that .p12 | |
| `SAYSO_MACOS_NOTARY_KEY_P8_B64` | base64 of an App Store Connect API key (.p8) | Preferred over Apple ID plus app-specific password: revocable, no personal password in CI [general knowledge] |
| `SAYSO_MACOS_NOTARY_KEY_ID` | API key id | |
| `SAYSO_MACOS_NOTARY_ISSUER_ID` | API issuer id | A team key is required for an issuer id [general knowledge] |
| `SAYSO_SPARKLE_ED_KEY` | Sparkle EdDSA private key (exported text) | Needed from milestone 5; can be generated without an Apple account |

Repository variables (not secrets, not sensitive): `SAYSO_MACOS_SIGN_IDENTITY` (the exact `Developer ID Application: <name> (<team id>)` string) and `SAYSO_MACOS_TEAM_ID`.

Fallback if Stevie prefers an Apple ID flow: `SAYSO_MACOS_APPLE_ID` plus `SAYSO_MACOS_APP_PASSWORD` (app-specific password) plus the team id variable, passed to `notarytool` as `--apple-id --password --team-id`. API key is the recommendation.

The release job runs in a GitHub Environment named `macos-release`, configured as follows (settings made by Stevie or a repo admin):

- Required reviewers: Stevie, so no tag push can read the signing secrets without a click.
- Deployment branches and tags: "Selected branches and tags" with a single tag rule `macos-v*`, so a job on any other branch, tag or pull request is refused the environment and therefore every secret in it. Branch rules for `main` are not added.
- Secrets live only in this environment. No `SAYSO_MACOS_*` or Sparkle key exists as a repository secret, and the plan forbids adding one.
- The ad hoc fallback is a separate job with no `environment:` key. It cannot see any of these secrets, so it never signs with the Developer ID certificate and cannot publish to the update feed.

Pull requests from forks do not receive repository secrets, and a pull request cannot satisfy the `macos-v*` tag rule, so the existing PR job stays ad hoc and is unaffected [general knowledge].

### Job flow (tag `macos-v*` or `workflow_dispatch`)

```
 checkout ─▶ import cert into temp keychain ─▶ package-app.sh (Developer ID)
    ─▶ verify (codesign, entitlements) ─▶ ditto zip ─▶ notarytool submit --wait
    ─▶ stapler staple app ─▶ make-dmg.sh ─▶ sign DMG ─▶ notarise DMG ─▶ staple DMG
    ─▶ spctl + stapler validate ─▶ Sparkle zip + appcast ─▶ gh release upload
```

Steps in detail:

1. **Temp keychain** (runner-local, random password generated in the job, deleted in an `always()` step): `security create-keychain`, `security import` the decoded .p12 with `-T /usr/bin/codesign`, `security set-key-partition-list -S apple-tool:,apple: -s` so `codesign` is not prompted, add to the search list. Never `echo` the decoded files; write them under `$RUNNER_TEMP` and delete after. [general knowledge, standard pattern]
2. **Package**: `SAYSO_CODESIGN_IDENTITY="$SAYSO_MACOS_SIGN_IDENTITY" ./Scripts/package-app.sh`. Change `package-app.sh` so that when `SAYSO_RELEASE=1` it refuses to fall back to ad hoc or an Apple Development identity and requires the identity to contain `Developer ID Application`. Today the script silently falls back (verified above).
3. **Notarise**: `ditto -c -k --keepParent` the app, then `xcrun notarytool submit <zip> --key <p8 path> --key-id ... --issuer ... --wait --output-format json`. Parse `status`; on anything but `Accepted` run `xcrun notarytool log <id>` and fail. Extend the existing `SAYSO_NOTARY_PROFILE` branch in `package-app.sh` with this API-key branch rather than writing a second path.
4. **Staple** the app (`xcrun stapler staple`), then `xcrun stapler validate`.
5. **Gate on Gatekeeper**: in the release job `spctl --assess --type execute -vv` must print `accepted` and `source=Notarized Developer ID`. The existing PR-job `spctl` step is `continue-on-error` because ad hoc is expected to be rejected; the release job must not be.
6. **Entitlement guard** (also useful in the PR job): assert the exact entitlement set equals the two entries above, not just that audio-input is present as `macos.yml` does today.

### Hardened runtime and entitlements the app needs

| Capability | Mechanism | Present today |
|---|---|---|
| Microphone | entitlement `com.apple.security.device.audio-input` + `NSMicrophoneUsageDescription` | yes (verified) |
| Apple Events (Music/Spotify now playing, desktop control actions) | entitlement `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription` | yes (verified) |
| Speech Recognition | `NSSpeechRecognitionUsageDescription` only, no entitlement when unsandboxed [general knowledge] | string yes (verified) |
| Accessibility (`AXIsProcessTrusted`, desktop control, text tools) | TCC grant only, **no entitlement** | n/a |
| Input Monitoring (global hotkeys, `CGPreflightListenEventAccess`) | TCC grant only, no entitlement, plus `NSInputMonitoringUsageDescription` | string yes (verified) |

Call sites for the TCC-only permissions are in `macos/Sources/SaysoCore/Permissions.swift` (verified).

Not needed today, and not to be added speculatively: `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`. The packaged app is one Mach-O with no embedded dylibs (verified), so library validation has nothing to reject. **Unverified risk:** whether the on-device speech stacks (FluidAudio/CoreML, sherpa-onnx/onnxruntime) need a hardened-runtime exception at runtime. The ad hoc and Apple Development builds already run with `--options runtime` (verified), and E2E dictation has run on them, so the risk looks low, but the first Developer ID build should re-run a local dictation to confirm. Adding Sparkle (milestone 3) introduces an embedded framework and may change this, see section 3.

## 2. DMG packaging

**Recommendation: plain `hdiutil` in a new `macos/Scripts/make-dmg.sh`** for v1. Headless, no dependency, deterministic on a CI runner. Add a background image and icon layout later with `create-dmg` (its Finder layout step is AppleScript-driven and can be flaky on headless runners, `--skip-jenkins` exists for that [general knowledge]). `create-dmg` is not installed on this Mac (verified); pin a version if adopted.

Script outline:

1. Stage a folder with `Sayso Notch.app` (already stapled) and a symlink `Applications -> /Applications`.
2. `hdiutil create -volname "Sayso Notch" -srcfolder <stage> -ov -format UDZO <out>.dmg`.
3. `codesign --force --timestamp --sign "$IDENTITY" <out>.dmg` (Developer ID Application, same identity).
4. `xcrun notarytool submit <out>.dmg ... --wait`, then `xcrun stapler staple <out>.dmg`.
5. Verify: `xcrun stapler validate`, and `spctl --assess --type open --context context:primary-signature -vv <out>.dmg` [general knowledge].

Why two notarisation submissions (app first, then DMG): the app inside the DMG then carries its own stapled ticket, so first launch works offline after the user drags it out. Cost is one extra submit of a few minutes [general knowledge].

File names: `Sayso-Notch-<version>.dmg` for first installs. Updates use a separate zip (section 3). Unnotarised ad hoc DMGs from the fallback path are named `...-adhoc.dmg` and must never be put on the feed.

## 3. Update channel: Sparkle 2

**Recommendation: Sparkle 2.10.0** (already the version in `Package.resolved`, so pinning `exact: "2.10.0"` as a direct dependency should not create `Package.resolved` drift, which `macos.yml` fails on; this is an inference, confirm on the first PR).

- **Integration**: add the Sparkle package as a direct dependency of `SaysoNotch`; hold an `SPUStandardUpdaterController` in the app; "Check for Updates" menu/settings item; Info.plist keys `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`. Ship **behind a flag** (feed URL empty and updater not started unless the key is present) so ad hoc and dev builds never poll.
- **Packaging work is the real cost**: `package-app.sh` currently copies one binary. Sparkle needs `Sparkle.framework` copied into `Contents/Frameworks`, an rpath of `@executable_path/../Frameworks`, and inside-out signing (each XPC service and helper app, then the framework, then the app) with the same Developer ID identity and `--options runtime`. Do not use `codesign --deep` for signing [general knowledge]. Because Sayso is not sandboxed, Sparkle's XPC services may be removable [general knowledge, check Sparkle docs]. Re-signing the framework with our identity keeps library validation satisfied without `disable-library-validation` (test this).
- **Keys**: `generate_keys` (ships with Sparkle) creates the EdDSA key pair in the login keychain; the public key goes in Info.plist (safe to commit), the exported private key goes in `SAYSO_SPARKLE_ED_KEY` and in an offline backup. **Losing or rotating this key strands every installed copy**, so back it up before the first public release [general knowledge].
- **Feed location**: the obvious `releases/latest/download/appcast.xml` is wrong here because "latest" is the Android release. Options:
  - (Recommended) A fixed release tagged `macos-feed` holding only `appcast.xml`, replaced by CI on each macOS release: `https://github.com/stevengonsalvez/sayso/releases/download/macos-feed/appcast.xml`. Needs only `contents: write`, no repo setting changes.
  - GitHub Pages (`.../sayso/macos/appcast.xml`): cleaner URL, but needs Pages enabled.
  Release payloads (zip, DMG) live on the versioned `macos-vX.Y.Z` GitHub release; the appcast `enclosure url` points there. Both hosts are free for a public repo.
- **Appcast generation**: `generate_appcast` over a directory of update zips signs each with the EdDSA key and, if prior versions are present in that directory, produces delta updates. CI must therefore download the previous N zips from earlier `macos-v*` releases before running it. Ship full updates first, add deltas in milestone 6.
- **Update artifact**: a zip of the stapled `.app` (`ditto -c -k --sequesterRsrc --keepParent`) is Sparkle's canonical input [general knowledge]; the DMG remains for first install.
- **Versioning**: CI derives `CFBundleShortVersionString` from the tag and `CFBundleVersion` from a monotonic counter (`GITHUB_RUN_NUMBER` or commit count) via `plutil -replace` on the copied Info.plist in `package-app.sh`. Never edit the committed plist per release.
- **Ad hoc update caveat**: whether Sparkle will apply an update to an ad hoc signed app on EdDSA alone is not verified; do not rely on testing the update path with ad hoc builds. Real update tests wait for milestone 5.

## 4. TCC grants across updates (Accessibility, Microphone, Input Monitoring)

How macOS keys grants [general knowledge, standard TCC behaviour]: a grant is stored against the bundle identifier and a code requirement derived from the signature at grant time. An update keeps its grants if the new binary still satisfies that stored requirement.

| Signing | Designated requirement | Survives rebuild/update? |
|---|---|---|
| Ad hoc (`-`) | pinned to the exact `cdhash`, changes every build | **No**: grants invalidated each rebuild. Accessibility can show "on" in Settings while `AXIsProcessTrusted()` returns false. Documented in `docs/ultimate-notch/E2E_BATCH_1.md` (line 29). |
| Apple Development | `identifier "ai.sayso.notch" and anchor apple generic and certificate leaf[subject.CN] = "<that cert>"` (verified on the local package) | Yes between builds with the same cert, but tied to one developer's personal cert |
| Developer ID Application | `identifier "ai.sayso.notch" and anchor apple generic and ... certificate leaf[subject.OU] = "<team id>"` [general knowledge on the exact clauses] | **Yes**, as long as the bundle id stays `ai.sayso.notch` and the Developer ID certificate team stays the same |

Rules to keep, in this order of importance:

1. Never change `CFBundleIdentifier` (`ai.sayso.notch`, verified). Rename the display name freely.
2. Sign every release with a certificate from the same Developer ID team. A renewed certificate under the same team keeps the team-id-based requirement [general knowledge, confirm in the test below].
3. Never ship an ad hoc build as an update to a Developer ID install.
4. Do not move the signing identity casually: the first Developer ID build **will** invalidate grants made to an Apple Development build, because the leaf-certificate clause differs. Expect Stevie to re-grant once; document it in the release notes.

Also affected (by the same mechanism, inference): Keychain items stored under service `ai.sayso.notch` by `macos/Sources/SaysoCore/KeychainStore.swift` carry an access list tied to the creating signature, so provider API keys saved by an Apple Development or ad hoc build may trigger a Keychain prompt, or read as missing, after the switch to Developer ID. Test and document.

### What to test (milestone 5, needs a real Developer ID)

1. Build and notarise `1.0.0` and `1.0.1` with the same identity. `codesign -d -r- "Sayso Notch.app"` on both: requirements must be identical.
2. Clean state: `tccutil reset` for the service categories against `ai.sayso.notch` (Microphone, Accessibility, ListenEvent, SpeechRecognition, AppleEvents), remove old installs.
3. Install `1.0.0` from the DMG into `/Applications`. Grant Microphone, Accessibility, Input Monitoring, Speech Recognition, and one Apple Events target. Record `PermissionKind` states from the in-app Permissions pane (`Permissions.swift`), all `granted`.
4. Update to `1.0.1` through the real Sparkle path (feed on a local or staging URL), not by copying files.
5. Relaunch. Expect all permission states still `granted` with no prompts; a global hotkey fires; dictation records; a Control step using AX runs; a saved provider key still reads without a Keychain prompt.
6. Negative control: ad hoc `1.0.1` over `1.0.0`, confirm grants are lost (proves the test can fail).
7. Optional: second certificate from the same team (renewal) to check rule 2.

## 5. Blocked on Stevie's Apple Developer account vs doable now

### Blocked (needs the account, some cost)

| Item | Why blocked |
|---|---|
| Enrol in the Apple Developer Program (about USD 99/year) | Account creation and payment; Stevie only |
| Developer ID Application certificate | Issued by the account (certificate signing request from a Mac, created in the developer portal or Xcode); export as .p12 |
| Notarisation credentials | App Store Connect API key (preferred) or an app-specific password |
| Creating the `macos-release` environment (required reviewer Stevie, deployment tags limited to `macos-v*`), adding the five `SAYSO_MACOS_*` secrets to it (not to the repository), and the two repository variables | Needs the values above; Stevie or a repo admin |
| First notarised release, `spctl` "Notarized Developer ID" proof | Needs a real signature |
| TCC survival test (section 4), live Sparkle update test | Needs two real Developer ID builds |
| Generating the production Sparkle EdDSA key | Not Apple-blocked, but it is a secret that only Stevie should create and back up |

### Doable now, no account, no spend

| Item | Result |
|---|---|
| Version stamping in `package-app.sh` (`SAYSO_VERSION`, `SAYSO_BUILD`) | Monotonic `CFBundleVersion` ready for Sparkle |
| `SAYSO_RELEASE=1` guard and API-key notarise branch in `package-app.sh` | Code path exists, untested until M4 |
| `macos/Scripts/make-dmg.sh` | Build and mount-check an ad hoc DMG locally |
| `.github/workflows/macos-release.yml` with ad hoc fallback | Two jobs: an ad hoc job with no `environment:` key that always produces an `-adhoc` DMG artifact, clearly labelled and never published to the feed, and a signed job that declares `environment: macos-release` (tags `macos-v*` only) and is the only one that can read the secrets. |
| Exact-entitlement-set CI assertion | Protects section 1 table |
| Sparkle direct dependency + `SPUStandardUpdaterController` behind a flag | Off by default, no feed URL |
| Appcast generation script and a local test (`python3 -m http.server`, throwaway test EdDSA key) | Feed format proven before any account exists |
| `macos.yml` tag filter `v*` to `macos-v*` | Removes the Android tag collision |

## 6. Milestones (in order)

| # | Milestone | Needs account | Done when |
|---|---|---|---|
| M0 | Stevie starts Apple Developer Program enrolment (lead time) | yes | Enrolment submitted |
| M1 | `package-app.sh`: version stamping, `SAYSO_RELEASE` guard, notary API-key branch; exact-entitlements CI check | no | PR green; ad hoc build still passes existing `macos.yml` |
| M2 | `make-dmg.sh` + `macos-release.yml` (ad hoc fallback, `macos-v*` tags, `macos.yml` tag filter) | no | `workflow_dispatch` produces a mountable `-adhoc` DMG artifact |
| M3 | Sparkle behind a flag, framework embedding and inside-out signing, appcast script, local feed test | no | App built with the flag on offers a test update from a local feed; flag off changes nothing |
| M4 | Cert, secrets, environment; tag `macos-v1.0.0` | yes | Release has a stapled DMG; `spctl` says Notarized Developer ID; `stapler validate` passes |
| M5 | TCC survival test and live Sparkle `1.0.0` to `1.0.1` update; generate and back up EdDSA key; publish feed | yes | All section 4 checks pass and results recorded in `docs/ultimate-notch/PROOF_LEDGER.md` |
| M6 | Delta updates, decide universal (arm64 + x86_64) vs arm64-only, enable automatic checks by default | partly | Decision recorded; first delta applied |

M1 to M3 can be done as three small independent PRs. M4 onward waits on M0.

## Open questions and unverified items

- Whether the on-device speech stacks need any hardened-runtime exception (re-run dictation on the first Developer ID build).
- Whether sherpa-onnx / onnxruntime / FluidAudio slices build for x86_64; the current package is arm64-only. Recommendation until checked: ship arm64-only and say so (min macOS is 14.2).
- Whether `Package.resolved` stays unchanged when Sparkle becomes a direct dependency.
- Whether Sparkle can update an ad hoc signed app, and which Sparkle XPC services can be dropped for an unsandboxed app.
- Exact Developer ID designated-requirement clauses, and certificate renewal behaviour (checked in the M5 test, not assumed).
- Whether the `sayso` and `sayso-mcp` CLI products should ship with the app. `package-app.sh` bundles only `SaysoNotch` (verified); any extra binary must be signed with the same identity and notarised, out of scope here.
- Apple Developer Program price and lead time are as given in issue #84 / general knowledge; confirm on Apple's site at enrolment.
