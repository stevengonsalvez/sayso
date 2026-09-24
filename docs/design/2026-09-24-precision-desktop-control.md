# Spec: Precision Desktop Control for Sayso Notch (Jev-Pattern Fast-Path)

**Date:** 2026-09-24
**Format:** diagram-first, table-second, no prose paragraphs
**Reference:** Pattern-inspired by savka777/jev-use (MIT License; see macos/LICENSES.md). No Jev-Use source code is copied; SaysoCore patterns and data types are extended directly.

## Problem

| Question | Answer |
|---|---|
| What? | High-speed, deterministic desktop control grounded in macOS Accessibility and Jev fast-path patterns |
| Why? | Maintain jev-use fast closed-vocabulary execution speed while preserving SaysoCore fail-closed safety invariants and state verification |
| Who? | macOS voice and automation power users demanding low-latency, verifiable desktop control |
| Precision Definition | "Precision" denotes deterministic desktop automation: exact candidate grounding, in-memory AX attribute pre-checks, fail-closed confirmation gates for destructive actions, and post-state verification whenever changes are observable via Accessibility |

## Users + use cases

| Persona | Goal | Primary use case |
|---|---|---|
| Precision User | Deterministic desktop control | Instant button click and text entry with badge overlays |
| Speed User | Low-latency macro execution | Fast chained commands via closed-vocab fast planner |
| Hands-Free User | Disambiguate without mouse | Spoken badge selection ("badge 2") |
| Power Navigator | Safe system menu navigation | Cross-process menu bar hierarchy navigation ("menu File > Save") |

## Approach

| Option | Summary | Tradeoff | Picked? |
|---|---|---|---|
| A | Jev Fast Path on SaysoCore | Low latency, deterministic, bounded AX assertions | Yes |
| B | Hierarchical Breadcrumb & Focus Traversal | Deep navigation, high interaction overhead | No |
| C | Multimodal Vision + AX Dual-Grounding | High resource cost, 1-2s latency, non-deterministic | No |

**Why A:** Integrates jev-use closed-vocabulary fast-path planner patterns into existing SaysoCore types, leveraging bounded cross-process AX queries and instant badge overlays while maintaining full safety guarantees.

## Architecture

```
┌───────────┐ Spoken / CLI  ┌─────────────────────────┐
│ Voice     │──────────────▶│ ControlPlanner          │ (open, click, menu,
│ Command   │               │ (Jev Closed-Vocab Fast) │  type, press, scroll)
└───────────┘               └────────────┬────────────┘
                                         │
                                         ▼
                            ┌─────────────────────────┐ AX Tree (Off-Main-Thread)
                            │ AXCandidateCapture      │◀───────── Frontmost Window
                            └────────────┬────────────┘  500ms Clock Check
                                         │
                                         ▼
                            ┌─────────────────────────┐
                            │ DesktopCandidateResolver│
                            └────────────┬────────────┘
                                         │
                   ambiguous (N matches)?│
                   ├──yes (interactive)─▶ [NotchHUD Badge Overlay (1..N)]
                   │                        │ (NSPanel .nonactivatingPanel)
                   │                        │ (Dictation suppressed; audio scoped to badge)
                   │                        ▼ (Spoken "badge 2" within 5s / VAD, max 15s)
                   │                      [Revalidation Capture: verify id & title]
                   │                        │ (Assert pid and windowTitle match before re-bind)
                   │                        │ (Re-bind expectedFingerprint for execute)
                   │                        ▼
                   ├──yes (headless)────▶ [Caller returns ambiguous error JSON]
                   │
                   no (1 match)
                   ▼────────────────────────┘
           ┌───────────────────┐ ControlPolicy check
           │ Confirmation Gate │──yes──▶ [NotchHUD Confirmation Banner]
           │ (isDestructive?)  │           │ user confirms ("confirm action" / "cancel action")
           └─────────┬─────────┘           │ (Dictation suppressed; 5s/15s VAD timeout, cancel on expire)
                     │ no (canAutoRun)     ▼
                     ▼─────────────────────┘
           ┌──────────────────────────────────────────────┐
           │ execute() Fresh Capture & Verification       │
           │ • Capture(s) with active target activation   │
           │ • Pre-flight check: isEnabled, !isProtected  │
           │ • Fingerprint comparison TOCTOU guard        │
           └──────────────────────┬───────────────────────┘
                                  │ pass
                                  ▼
           ┌───────────────────┐ Semantic AX Action (budget <4ms, timeout 250ms)
           │AXDesktopController│────────────┐ (press, select, focus, menu;
           └─────────┬─────────┘            │  .clickAt pointer and .key always confirm)
                     │               ┌──────▼──────┐
                     │               │ Target App  │
                     ▼               └──────┬──────┘
           ┌───────────────────┐            │
           │ ControlObservation│◀───────────┘ AX diff (1200ms hard deadline)
           └─────────┬─────────┘
                     │
                     ▼
           ┌───────────────────┐
           │ NotchHUD          │──▶ [Live Telemetry: target, outcome, latency]
           └─────────┬─────────┘
                     │
                     ▼
           ┌───────────────────┐
           │ ControlAuditStore │──▶ [Resilient per-entry JSON journal, newest 500]
           └───────────────────┘
```

## Component Mapping

| Existing Type | Target Layer | Role in Jev Fast-Path | Action |
|---|---|---|---|
| ControlPlanner | SaysoCore | Sub-15ms closed-vocab intent parsing alongside LLM fallback | Extended: > hierarchy parsed inside menu without splitting |
| AXCandidateCapture | SaysoCore | Bounded frontmost-window AX traversal (p50 < 20ms, p95 < 35ms) | Extended: off-main background task with 500ms monotonic clock deadline |
| DesktopCandidates | SaysoCore | Element representation: stable locator, role, state | Extended: bounds: CGRect? on DesktopCandidate and DesktopElement; bounds excluded from fingerprint hash |
| DesktopCandidateResolver | SaysoCore | Exact title and row resolution, badge overlay indexing | Extended: anchored row-bucket spatial sorting (anchor Y ±4pt threshold); returns .ambiguous |
| ControlPolicy | SaysoCore | Fail-closed destructive classification and review gating | Extended: explicit .menu case in isDestructive and all switches; compiler eliminates default: fallbacks; destructive check wins |
| AXDesktopController | SaysoCore | Semantic AX action dispatch and confirmation-gated pointer clicks | Extended: DesktopAction.menu(path:expectedApplicationTarget:) and 250ms timeout; maps AX timeouts to .noEffectObserved; menu traversal, leaf AXTitle re-check, and pre-flight run inside execute() after confirmation |
| ControlObservation | SaysoCore | Cross-process AX attribute diff and post-action verification | Extended: window-frame/attribute diff for menus; 1200ms monotonic soft ceiling (~1450ms worst case with in-flight AX overrun) |
| ControlSession | SaysoCore | Multi-step lifecycle, budget enforcement, and state transitions | Kept: ignores .effectUnknown without altering counter; halts fail-closed on 2 consecutive .noEffectObserved (including consecutive timeouts) |
| NotchHUD | SaysoNotch | Visual reticle, badge overlay, and telemetry breakdown | Extended: spatial badge rendering on nonactivating panel; spoken confirm/cancel banner with 5s/15s VAD timeout and audio ducking |
| ControlAuditStore | SaysoCore | Resilient persistent recording of newest 500 entries | Extended: Phase 1 per-entry decode via JSONSerialization preserving raw dictionary for every entry; ships ExecutionTelemetry; single control-audit.json.corrupt on whole-file JSON syntax failure |

## Migration Order & Schema Resilience for ControlAuditStore

| Phase | Scope | Deployment Rule & Disk Invariant |
|---|---|---|
| Current Build Vulnerability | Existing code exposure in DesktopControl.swift:1078 | Current builds use try? decode([ControlAuditEntry]) ?? [] and overwrite the whole journal on any decode failure or unknown enum value on the next append. Phase 1 seals this vulnerability immediately. |
| Phase 1: Storage Resilience | Ship per-entry decode in ControlAuditStore | Decodes array entries individually from disk via JSONSerialization and retains the raw JSON dictionary for EVERY entry alongside decoded structs. On save/append, updated fields are merged but all unknown keys/telemetry fields are preserved verbatim. ExecutionTelemetry ships in Phase 1 as part of the core resilient audit model. Unknown entry schemas or unrecognised enum values on downgrade/rollback decode into raw dictionary entries and NEVER trigger backups. If and only if the entire file fails to parse as valid JSON array, writes backup control-audit.json.corrupt (overwriting any previous corrupt backup file, capped at 1 file) before fallback. Minimum downgrade floor: Phase 1 release is the compatibility floor; rollback past Phase 1 is unsupported because pre-Phase-1 builds overwrite journal with empty array on decode failure. Ships in production release before Phase 2. |
| Phase 2: Action Extension | Ship DesktopAction.menu | Introduces .menu action type. Older builds running Phase 1 code safely preserve .menu entries on downgrade/rollback without failing full-array decode or dropping history on subsequent append. |

## Data model

```
┌─ DesktopCandidate ─────────┐         ┌─ ControlPlanStep ──────────┐
│ id       DesktopCandidateID│──1:1──▶ │ id         UUID            │
│ role     String            │         │ action     DesktopAction   │
│ title    String            │         │ confidence Double          │
│ bounds   CGRect?           │         │ reason     String          │
│ identifier String?         │         │ candidateTitle String?     │
│ state    CandState         │         │ requiresConfirmation Bool  │
│   isEnabled            Bool│         └─────────────┬──────────────┘
│   isProtected          Bool│                       │ 1:1
│   supportsPress        Bool│                       ▼
│   supportsFocus        Bool│         ┌─ ExecutionTelemetry ───────┐
│   supportsSelection    Bool│         │ stepId     UUID            │
│   supportsPointerClick Bool│         │ planMs     Double          │
└────────────────────────────┘         │ captureMs  Double          │
                                       │ dispatchMs Double          │
┌─ DesktopAction.menu ───────┐         │ verifyMs   Double          │
│ path     [String]          │──▶      │ totalMs    Double          │
│ expectedTarget AppIdentity │         │ stepResult StepResult      │
└────────────────────────────┘         └────────────────────────────┘
```

| Entity | Key Fields | Relationships |
|---|---|---|
| DesktopCandidate | id, role, title, bounds, identifier, state | Source for target resolution; bounds: CGRect? drives spatial badge layout (excluded from fingerprint) |
| DesktopElement | id, role, title, bounds, supportsPress... | Internal AX snapshot model extended with bounds: CGRect? (excluded from fingerprint) |
| DesktopCandidateID | processIdentifier, windowTitle, role, identifier, ancestry | Base64-encoded structural locator |
| DesktopCandidateState | isEnabled, isProtected, supportsPress, supportsFocus, supportsSelection, supportsPointerClick | Checked during PreFlightCheck |
| ControlPlanStep | id, action, confidence, reason, candidateTitle, requiresConfirmation | Action (.press, .select, .focus, .clickAt) carries elementID; executed by AXDesktopController |
| DesktopAction.menu | path: [String], expectedApplicationTarget: TargetApplicationIdentity | Traversed via AXMenuBar; bound to application target identity (bundleIdentifier + processIdentifier) rather than window AX element tree, preventing live-updating window contents from causing staleTarget failures |
| ExecutionTelemetry | stepId, planMs, captureMs, dispatchMs, verifyMs, totalMs, stepResult | Matches ControlPlanStep.id; decoded optionally in ControlAuditEntry |

## Latency Budget

| Phase | Happy-Path Target | Worst-Case Bound | Note |
|---|---|---|---|
| Intent Parsing | 8ms | 15ms | In-memory closed-vocabulary pattern match |
| Active Target & AX Capture | 40ms (2x 20ms p50) | 1500ms (2x 750ms) | Accounts for pre-activation and post-activation captures in execute(); 1500ms worst case represents 2 captures capped by 500ms soft clock check plus single 250ms in-flight call overrun each |
| Pre-flight Attribute Check | 4ms (2x 2ms) | 500ms (2x 250ms) | isEnabled and isProtected attribute checks (2 calls x 250ms timeout) |
| Semantic Action Dispatch | 4ms | 250ms | AXUIElementPerformAction (bounded by 250ms messaging timeout) |
| Post-assert Diff | 15ms (initial check) | 1450ms | Immediate check at 0ms sleep; 1200ms monotonic soft deadline ceiling (bounded by at most one 250ms in-flight AX call overrun = 1450ms worst-case abort). Attempts = min(8, deadline-limited) with 100ms soft check per attempt at 125ms intervals (~5-6 attempts max) |
| Total (Benign Fast-Path) | ~71ms | ~3.7s | Fast-path p50 target ~71ms; worst-case bounded by timeouts |

## Interface

```
┌────────────────────────────────────────────────────────┐
│ Sayso Notch Telemetry (Jev Fast-Path)                  │
├────────────────────────────────────────────────────────┤
│ Target: [Menu: Window > Zoom]        Badge: [N/A]      │
│ Resolution: Full path allowlist      Risk: Benign      │
│ Pre: Enabled, Unprotected, Timeout 250ms [PASS]        │
│ Action: AXUIElementPerformAction [DISPATCHED in 2ms]   │
│ Post: Window Frame Resized [VERIFIED in 15ms]          │
│ Target Budget: Plan 8ms, Capture 40ms, Exec 23ms       │
└────────────────────────────────────────────────────────┘
```

```
Badge Overlay (Ambiguous Candidates Only):
┌──────────────────────────────────────┐
│  ┌─[1]──────────┐   ┌─[2]─────────┐  │
│  │ Cancel       │   │ Save Draft  │  │
│  └──────────────┘   └─────────────┘  │
└──────────────────────────────────────┘
```

| Surface | Trigger | Shape |
|---|---|---|
| Notch HUD | Action dispatch and assert | Compact target reticle, auto-expanding diff |
| Badge Overlay | Multiple candidates match title | Non-activating NSPanel window, row-bucket sorted badges |
| Menu Traversal | Spoken "menu File > Save" | Cross-process AXMenuBar item press with confirmation banner |
| Automation CLI | sayso status / transcribe / control | JSON response with latency breakdown |

## Behavior

Fast path (Single unambiguous candidate, canAutoRun == true, semantic AX only):

```
[Voice Cmd] ──Plan (8ms)──▶ [AX Capture 2x (40ms)] ──Pre-check (4ms)──▶ [AX Dispatch (4ms)] ──Post-assert (15ms)──▶ [Done (~71ms target)]
```

Ambiguous match path (Multiple targets sharing label; destructive badge requires confirmation):

```
[Voice Cmd] ──Resolver (ambiguous)──▶ [Badge Overlay 1..N (max 15s)] ──voice "badge 1"──▶ [Revalidation Capture: verify id & title (implies pid/windowTitle)] ──▶ [Re-bind expectedFingerprint] ──▶ [Confirmation Gate: "Cancel" requires review] ──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() Fresh Capture + PreFlightCheck isEnabled] ──▶ [Dispatch] ──▶ [Done]
```

Menu hierarchy path (Unlisted / destructive menu requires confirmation):

```
["menu File > Save"] ──Static Path & Confirmation Gate (unlisted/destructive)──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() AXMenuBar Traversal + Leaf AXTitle Re-check + PreFlightCheck isEnabled] ──▶ [AXPress Leaf] ──▶ [Post-assert] ──▶ [Done]
```

Multi-step chain execution semantics:

| Outcome Step Result | Mapped From | Handling in Multi-Step Chains |
|---|---|---|
| .effectObserved | ControlEffect.observed, .alreadySatisfied | State change verified. Reset consecutiveNoEffectCount to 0. Proceed to step k+1 |
| .effectUnknown | ControlEffect.unknown, kAXErrorCannotComplete | Benign unobservable completion (.key, .select, or modal open). Tolerated without modifying consecutiveNoEffectCount. Proceed to step k+1 |
| .noEffectObserved | ControlEffect.notObserved, AX timeout | State unchanged or AX messaging timeout. Increment consecutiveNoEffectCount. Proceed if counter < maxConsecutiveNoEffect (2); halt chain if counter == 2 |
| .actionFailed | Hard OS/AX error | Hard structural failure (invalidUIElement, apiDisabled). AXDesktopController / caller explicitly calls session.fail() to halt chain immediately |
| Budget Cap | Session counter | Session halts immediately if total actions reach maxActions (default 12) |

## Safety Invariants

| Guard | Rule | Enforcement Mechanism |
|---|---|---|
| Protected Fields | Never synthesize input into secure fields | Excluded by DesktopCandidateState.isProtected |
| Exact Matching | Single unconfirmed action requires 1 exact match | DesktopCandidateResolver flags ambiguity; headless caller returns ambiguity error JSON; interactive caller shows badge overlay |
| Interactive Disambiguation | Multiple matches display numbered badges | App controller catches ambiguous resolution and shows overlay |
| Badge Disambiguation Only | Badge selection disambiguates target, never confirms | Destructive badge targets (e.g. Cancel) still require confirmation banner |
| Non-Activating Overlay | Badge window must not steal target focus | NSPanel with .nonactivatingPanel style mask preserves active app |
| Badge Dictation Suppression | Suppress dictation text insertion during badge overlay | While badge overlay NSPanel is active, speech recognition text insertion into target app is suppressed; audio stream is scoped exclusively to badge grammar ("badge <N>" or "cancel badges") |
| Spatial Badge Ordering | Badges ordered by anchored row-buckets then X | Grouped by anchor Y (±4pt threshold), then sorted by bounds.origin.x |
| Coordinate Conversion | Top-left AX bounds converted to Cocoa screen | cocoaY = NSScreen.screens[0].frame.maxY - axY - axHeight |
| Badge Candidate Revalidation | Re-asserts candidateID & title match on frontmost window | Candidate revalidation verifies candidateID and title against frontmost window; DesktopCandidateID equality inherently guarantees processIdentifier and windowTitle match before re-binding expectedFingerprint. Absolute screen bounds are not pinned to ±2pt so window move/resize does not trigger false rejection |
| Badge Overlay TOCTOU Window | Known trade-off during disambiguation overlay | Up-to-15s overlay window accepts background window mutation provided pid, windowTitle, and chosen candidate ID/title match. Bounds are excluded from the fingerprint, so .clickAt pointer actions must dynamically re-query fresh element bounds at dispatch time from the active AX element rather than using plan-time bounds |
| Pre-flight Verification Timing | Pre-flight checks and fingerprint guard run after confirmation | PreFlightCheck (isEnabled, !isProtected) and expectedFingerprint comparison execute inside execute() immediately prior to action dispatch, ensuring checks remain fresh even after long confirmation pauses |
| Fingerprint Bounds Exclusion | Snapshot fingerprint invariant | bounds: CGRect? on DesktopCandidate and DesktopElement are excluded from window snapshot fingerprint hash, ensuring window move or resize does not trigger false TOCTOU mismatch |
| Badge Grammar Prefix | Spoken badge selection requires prefix | "badge <N>" required; "cancel badges" dismisses overlay; bare digits and bare words ("cancel") are rejected on open mic to prevent ambiguity with candidate titles |
| Badge VAD Timeout | Overlay dismisses after 5s silence or 15s max | 5.0s timer extended on voice activity detection; hard cap of 15.0s overlay lifetime prevents mic chatter lock |
| Confirmation Banner Spoken Safety | Disambiguated spoken grammar with audio ducking and energy check | Spoken "confirm action" or "approve action" confirms; "cancel action" or "abort action" aborts. Bare words ("yes", "no", "cancel") are rejected on open mic. During confirmation banner, Sayso ducks system audio output (CoreAudio ducking) and enforces speech recognition energy threshold to prevent speaker echo or background media playback from triggering confirmation. Dictation insertion into target app is suppressed while banner is active |
| Confirmation Banner Timeout | Banner auto-dismisses and cancels on timeout | 5.0s timer extended on voice activity detection; hard cap of 15.0s maximum banner lifetime. On timeout, action is automatically cancelled fail-closed and banner dismisses |
| Destructive Actions | Actions in ControlPolicy.destructiveWords require review | ControlPolicy.requiresConfirmation gates execution |
| Pointer Click Safety | Raw CGEvent mouse clicks always require review | Kept: DesktopAction.isDestructive returns true for .clickAt (:386-388) |
| Keystroke Safety | Keyboard shortcuts always require review | Kept: DesktopAction.isDestructive returns true for .key (:386-388) |
| Fail-Closed Menu Policy | Explicit .menu case; allowlist check must be non-destructive | safeMenuAllowlist.contains(path) && !isDestructiveControlTitle(leaf) |
| Menu Destructive Classification | Explicit .menu case in DesktopAction.isDestructive | In DesktopAction.isDestructive, .menu(path: _, expectedApplicationTarget: _) explicitly evaluates !safeMenuAllowlist.contains(path) \|\| isDestructiveControlTitle(leaf), eliminating default: false fallbacks |
| Menu Exhaustive Switches | Enumerate all DesktopAction cases via compiler | Eliminate default: fallbacks across all action switches (including isDestructive, requiresConfirmation, requiresActiveTarget, validatedNextTargetBundleIdentifier, execute); compiler enforces explicit handling |
| Menu Application Target Guard | Menu actions bound to target application identity | DesktopAction.menu binds to target application identity (bundleIdentifier and processIdentifier) rather than full window AX element tree, preventing live-updating window controls (timers, chat feeds) from causing false staleTarget rejections. Traversal proceeds at AXApplication level even if no window is currently focused |
| Active Menu Target | Menus only target frontmost application | ControlPolicy.requiresActiveTarget returns true for .menu |
| Menu Traversal Execution Timing | Menu traversal executes inside execute() after confirmation | Confirmation gate statically inspects menu path against allowlist and destructive stems without opening menus. AXMenuBar traversal (depth ≤3) runs inside execute() post-approval, preventing open menus from shifting focusedRole/focusedValue or timing out during user confirmation |
| Menu Leaf Verification in execute() | Re-verify resolved leaf title against confirmation and allowlist | Inside execute() post-traversal, re-run safeMenuAllowlist and isDestructiveControlTitle against the actual resolved AXMenuItem title attribute (canonicalizing ellipsis … vs ...). If resolved leaf title differs from confirmed leaf or matches destructive stems, abort fail-closed with menuLeafMismatch |
| AX Timeout Mapping | Timeouts map to .noEffectObserved; only hard errors fail | AXUIElementPerformAction timeouts map to .noEffectObserved, incrementing consecutiveNoEffectCount (2 consecutive timeouts halt session fail-closed). Benign completions without AX diff (.key, .select) or kAXErrorCannotComplete map to .effectUnknown and are tolerated without altering counter. Only hard structural errors (kAXErrorInvalidUIElement, kAXErrorAPIDisabled, kAXErrorActionUnsupported) map to .actionFailed and halt session via explicit session.fail() |
| Key/Select Chain Tolerance | Tolerates unverified keystrokes and selection actions | .effectUnknown outcomes (.key, .select) do not alter consecutiveNoEffectCount, preserving multi-key/select chains (e.g. repeated tab navigation); only .noEffectObserved (or AX timeout) increments toward halt |
| Bounded AX Timeout | Cross-process AX queries cannot hang UI | AXUIElementSetMessagingTimeout 0.25s per call, 500ms soft clock check |
| Resilient Audit Storage | Journal schema changes must never wipe history | ControlAuditStore decodes entries individually, preserving raw dictionary for every entry. Phase 1 per-entry decode deploys before Phase 2 (.menu). Raw entries count toward 500-entry cap and are preserved on re-save. Unrecognised entries decode as raw dictionaries without backups; backup control-audit.json.corrupt (overwrites previous corrupt backup, capped at 1 file) is written only on whole-file JSON syntax parse failure |
| Observation Polling | State diff observation capped at 1200ms monotonic soft ceiling | Polling terminates as soon as 1200ms soft ceiling elapses (with at most one in-flight 250ms AX call overrun = 1450ms worst-case cutoff); attempts = min(8, deadline-limited) with 100ms soft check per attempt at 125ms intervals (~5-6 attempts max); initial check at 0ms sleep |
| Chain No-Effect Limit | Consecutive no-effect actions capped at 2 | Tolerates 1 no-effect step; halts on 2 consecutive .noEffectObserved |

Safe menu allowlist (exact full path match, standard AppKit):
`[["View", "Zoom In"], ["View", "Zoom Out"], ["View", "Actual Size"], ["Window", "Zoom"]]`
Rule: Destructive check always wins. Even if in allowlist, any title matching destructive stems requires confirmation. Non-English menu paths fail-safe to requiring confirmation banner.

## Errors

| Failure mode | User-visible surface | Recovery |
|---|---|---|
| AX API Timeout | Notch HUD warning banner | Map to .noEffectObserved; increment consecutiveNoEffectCount; 2 consecutive timeouts halt session fail-closed |
| Stale Target on Badge | Notch HUD alert banner | Abort dispatch when candidateID or title mismatch (ID equality ensures pid and windowTitle match); refresh list |
| Sibling Insertion on Badge | Notch HUD alert banner | Structural ancestry index shift rejects candidate fail-closed; dismiss overlay and refresh candidates |
| Menu Leaf Mismatch | Notch HUD alert banner | Resolved AXMenuItem title differs from confirmed leaf or matches destructive stem; aborts dispatch fail-closed |
| Badge Overlay Timeout | Overlay dismisses silently | Auto-dismiss after 5s silence or 15s hard cap, record timeout in audit |
| Confirmation Banner Timeout | Notch HUD banner dismisses | Auto-cancels action fail-closed after 5s silence or 15s hard cap; records cancellation in audit |
| Post-assert Timeout | Notch HUD failed assertion | Report unobserved state after 1200ms observe deadline, offer manual retry |
| Invalid Menu Path | Notch HUD path error | List available items under parent menu (non-destructive inspection up to depth 3; dismisses menu on cancel/failure) |

## Testing strategy

| Layer | Scope | Gate |
|---|---|---|
| Unit | Menu hierarchy step parsing | "menu File > Save then click Confirm" splits on " then " (case-insensitive) into 2 steps while preserving ">" within the menu path. Menu path syntax rule: menu commands consume path tokens until explicit " then " chain delimiter; menu items containing literal " then " must be quoted (e.g. menu "File > Export then Print") |
| Unit | Desktop candidate filtering and protection | All protected fields rejected |
| Unit | Menu allowlist explicit classification | ["View","Zoom In"] auto-runs; ["File","Export"] triggers confirmation |
| Unit | Menu application target verification | Application switch before menu dispatch aborts execution; live-updating window content within target app does not invalidate menu action |
| Unit | Menu leaf title mismatch aborts execution | Resolved AXMenuItem title differing from confirmed path or matching destructive stem aborts dispatch fail-closed |
| Unit | Destructive badge confirmation gate | Picking destructive badge "Cancel" prompts confirmation banner |
| Unit | Immediate chain failure on .actionFailed | Caller explicitly invokes session.fail() on .actionFailed, halting multi-step chain immediately |
| Unit | Badge revalidation and drift check | Stale candidate ID or title mismatch aborts dispatch; PID/windowTitle mismatch prevents re-binding |
| Unit | Pre-flight timing verification | PreFlightCheck validates isEnabled and !isProtected inside execute() after approval |
| Unit | Badge dictation suppression | Target application dictation insertion suppressed during badge overlay |
| Unit | Confirmation banner spoken safety | Spoken "confirm action" / "approve action" / "cancel action" / "abort action" recognized; bare words rejected; CoreAudio ducking and speech energy threshold enforced |
| Unit | Confirmation banner timeout | Auto-cancels fail-closed after 5s silence or 15s hard cap |
| Unit | Multi-key effectUnknown chain tolerance | 3 consecutive .key actions (.effectUnknown, each requiring individual confirmation banner unless pre-approved) succeed without triggering no-effect halt; 2 consecutive .noEffectObserved halt chain fail-closed |
| Unit | Consecutive AX timeouts halt session | 2 consecutive AX call timeouts map to .noEffectObserved and halt multi-step chain fail-closed |
| Unit | Spatial row-bucket badge ordering | Badges 1..N order by anchored row (Y ±4pt threshold), then X |
| Unit | Resilient audit journal decoding | Corrupt or unknown action entries preserved without wiping 500-entry journal; single backup control-audit.json.corrupt overwritten only on whole-file JSON syntax corruption |
| Integration | Badge overlay coordinate mapping | AX top-left to Cocoa primary screen bottom-left conversion across screens |
| Integration | AXMenuBar hierarchy traversal | Native macOS menu bar resolution with lazy-menu fallback (depth ≤3) |
| Benchmark | Fast-path execution latency | Target composite pipeline latency p50 < 85ms, p95 < 140ms directly measured on standard AppKit target (intent parse + active target capture + pre-flight + semantic dispatch + immediate verification). Component capture p50 < 20ms, p95 < 35ms on Apple Silicon M-series |
| E2E | Computer-use automated validation | Tab navigation, state inspection, and audio transcribe round-trip |

## Out of scope

- OCR-based vision control for non-accessibility games and full-screen streaming.
- Cross-machine network desktop control.
- Hardware-level mouse emulation outside CGEvent and AX APIs.
