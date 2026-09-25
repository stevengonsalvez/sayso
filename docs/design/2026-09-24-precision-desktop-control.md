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
| ControlPolicy | SaysoCore | Fail-closed destructive classification and review gating | Extended: explicit .menu case in isDestructive and all switches; compiler eliminates default: fallbacks; .press classified by title (isDestructiveControlTitle) while .clickAt and .key remain blanket destructive; destructive check wins |
| AXDesktopController | SaysoCore | Semantic AX action dispatch and confirmation-gated pointer clicks | Extended: DesktopAction.menu(path:expectedApplicationTarget:) and 250ms timeout; runs post-action observation after cannotComplete/timeout; timed-out dispatches (>=250ms) are non-retryable; menu traversal, leaf AXTitle re-check, and pre-flight run inside execute() after confirmation |
| ControlObservation | SaysoCore | Cross-process AX attribute diff and post-action verification | Extended: window-frame/attribute diff for menus; runs after timeout to detect modal sheets; 1200ms monotonic soft ceiling (~1450ms worst case with in-flight AX overrun) |
| ControlSession | SaysoCore | Multi-step lifecycle, budget enforcement, and state transitions | Extended: record(.actionFailed) calls finish(.failed) directly; halts fail-closed on 2 consecutive unverified effects (.noEffectObserved or .timedOut) |
| NotchHUD | SaysoNotch | Visual reticle, badge overlay, and telemetry breakdown | Extended: spatial badge rendering on nonactivating panel; spoken confirm/cancel banner with 5s/15s VAD timeout and audio ducking |
| ControlAuditStore | SaysoCore | Resilient persistent recording of newest 500 entries | Extended: Phase 1 per-entry decode via JSONSerialization preserving raw dictionary for every entry; aborts append on read errors without overwrite; ships ExecutionTelemetry and .timedOut; retains initial corrupt backup control-audit.json.corrupt.initial and up to 2 timestamped backups (capped at 3 files) on whole-file JSON syntax failure |

## Migration Order & Schema Resilience for ControlAuditStore

| Phase | Scope | Deployment Rule & Disk Invariant |
|---|---|---|
| Current Build Vulnerability | Existing code exposure in DesktopControl.swift:1078 | Current builds use try? decode([ControlAuditEntry]) ?? [] and overwrite the whole journal on any decode failure or unknown enum value on the next append. Phase 1 seals this vulnerability immediately. |
| Phase 1: Storage Resilience | Ship per-entry decode in ControlAuditStore | Decodes array entries individually from disk via JSONSerialization and retains the raw JSON dictionary for EVERY entry alongside decoded structs. Distinguishes missing file (clean initial state, returns []) from read error (permissions, transient I/O); on read error, append aborts fail-closed and refuses to overwrite the disk journal. On save/append, updated fields are merged but all unknown keys/telemetry fields are preserved verbatim. ExecutionTelemetry and .timedOut ship in Phase 1 as part of the core resilient audit model. Unknown entry schemas or unrecognised enum values on downgrade/rollback decode into raw dictionary entries and NEVER trigger backups. If and only if the entire file fails to parse as valid JSON array, writes initial corrupt backup control-audit.json.corrupt.initial (preserved permanently) and rotates up to 2 timestamped backups control-audit.json.corrupt-<timestamp> (capped at 3 backup files total) before fallback. Minimum downgrade floor: Phase 1 release is the compatibility floor; rollback past Phase 1 is unsupported because pre-Phase-1 builds overwrite journal with empty array on decode failure. Ships in production release before Phase 2. |
| Phase 2: Action Extension | Ship DesktopAction.menu | Introduces .menu action type. Older builds running Phase 1 code safely preserve .menu entries on downgrade/rollback without failing full-array decode or dropping history on subsequent append. |

## Data model

```
┌─ DesktopCandidate ─────────┐         ┌─ ControlPlanStep ──────────┐
│ id       DesktopCandidateID│──1:1──▶ │ id         UUID            │
│ role     String            │         │ action     DesktopAction   │
│ title    String            │         │ confidence Double          │
│ bounds   CGRect?           │         │ reason     String          │
│ identifier String?         │         │ candidateTitle String?     │
│ state  DesktopCandidateState│         │ requiresConfirmation Bool  │
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
│ expectedApplicationTarget  │         │ stepResult StepResult      │
│   TargetAppIdentity        │         └────────────────────────────┘
└────────────────────────────┘
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
| Post-assert Diff | 15ms (initial check) | 1450ms | Immediate check at 0ms sleep; observation attempt cap (8 attempts spaced by 125ms intervals, ~1000ms total) is primary, with a 1200ms monotonic soft ceiling backstop for slow AX responses (bounded by at most one 250ms in-flight AX call overrun = 1450ms worst-case abort) |
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
[Voice Cmd] ──Resolver (ambiguous)──▶ [Badge Overlay 1..N (max 15s)] ──voice "badge 1"──▶ [Revalidation Capture: verify id & title (implies pid/windowTitle)] ──▶ [Confirmation Gate: "Cancel" requires review] ──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() Target Candidate Identity Check (id, title, isEnabled) + PreFlightCheck] ──▶ [Dispatch] ──▶ [Done]
```

Menu hierarchy path (Unlisted / destructive menu requires confirmation):

```
["menu File > Save"] ──Static Path & Confirmation Gate (unlisted/destructive)──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() AXMenuBar Traversal + Leaf AXTitle Re-check + PreFlightCheck isEnabled] ──▶ [AXPress Leaf] ──▶ [Post-assert] ──▶ [Done]
```

Multi-step chain execution semantics:

| Outcome Step Result | Mapped From | Handling in Multi-Step Chains |
|---|---|---|
| .effectObserved | ControlEffect.observed, .alreadySatisfied | State change verified (including modal sheets opened during AX timeout/cannotComplete). Reset consecutiveNoEffectCount to 0. Proceed to step k+1 |
| .effectUnknown | ControlEffect.unknown | Benign unobservable completion (.key, .select). Tolerated without modifying consecutiveNoEffectCount. Proceed to step k+1 |
| .noEffectObserved | ControlEffect.notObserved | State unchanged post-action. Increment consecutiveNoEffectCount. Proceed if counter < maxConsecutiveNoEffect (2); halt chain if counter == 2 |
| .timedOut | AX call timeout (elapsed >= 250ms) without observed diff | Call messaging timeout without state change. Never retried fail-closed. Increment consecutiveNoEffectCount; 2 consecutive unverified (.noEffectObserved or .timedOut) halt session |
| .actionFailed | Hard OS/AX error | Hard structural failure (invalidUIElement, apiDisabled). ControlSession.record(.actionFailed) invokes finish(.failed) to halt chain immediately |
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
| Badge Candidate Revalidation | Re-asserts candidateID & title match on frontmost window | Candidate revalidation verifies candidateID and title against frontmost window; DesktopCandidateID equality inherently guarantees processIdentifier and windowTitle match. Absolute screen bounds are not pinned to ±2pt so window move/resize does not trigger false rejection |
| Badge Overlay TOCTOU Window | Known trade-off during disambiguation overlay | Up-to-15s overlay window accepts background window mutation provided pid, windowTitle, and chosen candidate ID/title match. Bounds are excluded from the fingerprint, so .clickAt pointer actions must dynamically re-query fresh element bounds at dispatch time from the active AX element rather than using plan-time bounds |
| Candidate Action Fingerprint Scope | Actions retain expectedFingerprint bound to window snapshot | Candidate actions retain expectedFingerprint bound to window snapshot at plan time, and badge pick revalidation re-binds it. Ambient window mutations during confirmation pause (sibling insertion, document title mutation, or ancestry index shift) intentionally reject fail-closed with staleTarget as a safety invariant |
| Fingerprint Bounds Exclusion | Snapshot fingerprint invariant | bounds: CGRect? on DesktopCandidate and DesktopElement are excluded from window snapshot fingerprint hash, ensuring window move or resize does not trigger false TOCTOU mismatch |
| Badge Grammar Prefix | Spoken badge selection requires prefix | "badge <N>" required; "cancel badges" dismisses overlay; bare digits and bare words ("cancel") are rejected on open mic to prevent ambiguity with candidate titles |
| Badge VAD Timeout | Overlay dismisses after 5s silence or 15s max | 5.0s timer extended on voice activity detection; hard cap of 15.0s overlay lifetime prevents mic chatter lock |
| Confirmation Banner Spoken Safety | Disambiguated spoken grammar with audio ducking and energy check | Spoken "confirm action" or "approve action" confirms; "cancel action" or "abort action" aborts. Bare words ("yes", "no", "cancel") are rejected on open mic. Audio engine initializes with voice processing enabled at startup; during confirmation banner, Sayso configures AVAudioEngine voiceProcessingOtherAudioDuckingConfiguration (macOS 14+) on AVAudioInputNode without engine restart and enforces speech recognition energy threshold to prevent speaker echo or background media playback from triggering confirmation. Dictation insertion into target app is suppressed while banner is active |
| Confirmation Banner Timeout | Banner auto-dismisses and cancels on timeout | 5.0s timer extended on voice activity detection; hard cap of 15.0s maximum banner lifetime. On timeout, action is automatically cancelled fail-closed and banner dismisses |
| Destructive Actions | Actions in ControlPolicy.destructiveWords require review | ControlPolicy.requiresConfirmation gates execution |
| Button Press Classification | Title-classified destructive gating enables fast path | In DesktopAction.isDestructive, .press classifies by candidate title via isDestructiveControlTitle(candidate.title): destructive button titles require confirmation banner while benign button titles auto-run (~71ms fast path). DesktopAction.clickAt and .key remain blanket destructive |
| Pointer Click Safety | Raw CGEvent mouse clicks always require review | Kept: DesktopAction.isDestructive returns true for .clickAt (:386-388) |
| Keystroke Safety | Keyboard shortcuts always require review | Kept: DesktopAction.isDestructive returns true for .key (:386-388) |
| Fail-Closed Menu Policy | Explicit .menu case; allowlist check must be non-destructive | safeMenuAllowlist.contains(path) && !isDestructiveControlTitle(leaf) |
| Menu Destructive Classification | Explicit .menu case in DesktopAction.isDestructive | In DesktopAction.isDestructive, .menu(path: _, expectedApplicationTarget: _) explicitly evaluates !safeMenuAllowlist.contains(path) \|\| isDestructiveControlTitle(leaf), eliminating default: false fallbacks |
| Menu Exhaustive Switches | Enumerate all DesktopAction cases via compiler | Eliminate default: fallbacks across all action switches, explicitly enumerating .menu in isDestructive, requiresConfirmation, requiresActiveTarget, validatedNextTargetBundleIdentifier, and execute |
| Menu Application Target Guard | Menu actions bound to target application identity | DesktopAction.menu binds to target application identity (bundleIdentifier and processIdentifier) rather than full window AX element tree, preventing live-updating window controls (timers, chat feeds) from causing false staleTarget rejections. Traversal proceeds at AXApplication level even if no window is currently focused |
| Active Menu Target | Menus only target frontmost application | ControlPolicy.requiresActiveTarget returns true for .menu |
| Menu Traversal Execution Timing | Menu traversal executes inside execute() after confirmation | Confirmation gate statically inspects menu path against allowlist and destructive stems without opening menus. AXMenuBar traversal (depth ≤3) runs inside execute() post-approval, preventing open menus from shifting focusedRole/focusedValue or timing out during user confirmation |
| Menu Hierarchy Traversal Verification | Intermediate segments verified by exact title at each depth | AXMenuBar traversal navigates hierarchy step-by-step, verifying exact title match at each parent depth level (depth ≤3). Inside execute() post-traversal, re-run safeMenuAllowlist and isDestructiveControlTitle against the actual resolved AXMenuItem title attribute (canonicalizing ellipsis … vs ...). If resolved leaf title differs from confirmed leaf or matches destructive stems, abort fail-closed with menuLeafMismatch |
| Action Failure Session Halt | Fail-closed session halt on structural error | ControlSession.record(.actionFailed) automatically terminates session fail-closed via finish(.failed), eliminating reliance on caller convention |
| AX Diff-Based Outcome Classification | Classify by post-action diff; timeouts are non-retryable | After any kAXErrorCannotComplete or 250ms messaging timeout, post-action diff observation runs unconditionally. If attribute or window frame diff is observed (e.g. modal sheet opened), outcome is classified as .effectObserved. If no diff is observed after observation ceiling: dispatches taking >=250ms map to .timedOut and are non-retryable fail-closed; calls returning in <250ms without diff map to .noEffectObserved. Both .timedOut and .noEffectObserved increment consecutiveNoEffectCount (2 consecutive halt session fail-closed) |
| Key/Select Chain Tolerance | Tolerates unverified keystrokes and selection actions | .effectUnknown outcomes (.key, .select) do not alter consecutiveNoEffectCount, preserving multi-key/select chains (e.g. repeated tab navigation); only .noEffectObserved or .timedOut increments toward halt |
| Bounded AX Timeout | Cross-process AX queries cannot hang UI | AXUIElementSetMessagingTimeout 0.25s per call, 500ms soft clock check |
| Resilient Audit Storage | Journal schema changes and read errors must never wipe history | ControlAuditStore decodes entries individually, preserving raw dictionary for every entry. Distinguishes missing file from read error (transient I/O, permissions); read errors abort append fail-closed without overwriting the journal. Phase 1 per-entry decode deploys before Phase 2 (.menu). Raw entries count toward 500-entry cap and are preserved on re-save. Unrecognised entries decode as raw dictionaries without backups; on whole-file JSON syntax failure, writes permanent initial backup control-audit.json.corrupt.initial and rotates up to 2 timestamped backups control-audit.json.corrupt-<timestamp> (capped at 3 backup files total) |
| Observation Polling | Observation attempt cap is primary with 1200ms backstop | Polling starts with immediate check at 0ms, followed by attempts spaced by 125ms intervals with 100ms soft check per attempt. Observation attempt cap (8 attempts, ~1000ms total) is primary; 1200ms monotonic soft ceiling serves as backstop for slow AX responses, with at most one in-flight 250ms AX call overrun (~1450ms worst-case cutoff) |
| Chain No-Effect Limit | Consecutive no-effect actions capped at 2 | Tolerates 1 no-effect step; halts on 2 consecutive .noEffectObserved or .timedOut |

Safe menu allowlist (exact full path match, standard AppKit):
`[["View", "Zoom In"], ["View", "Zoom Out"], ["View", "Actual Size"], ["Window", "Zoom"]]`
Rule: Destructive check always wins. Even if in allowlist, any title matching destructive stems requires confirmation. Non-English menu paths fail-safe to requiring confirmation banner.

## Errors

| Failure mode | User-visible surface | Recovery |
|---|---|---|
| AX API Timeout | Notch HUD warning banner | Map to .timedOut; non-retryable; increment consecutiveNoEffectCount; 2 consecutive timeouts halt session fail-closed |
| Stale Target on Badge | Notch HUD alert banner | Abort dispatch when candidateID or title mismatch (ID equality ensures pid and windowTitle match); refresh list |
| Window Title Mutation on Badge | Notch HUD alert banner | Window title mutation during 15s badge overlay (e.g. document Edited marker or tab change) rejects candidate fail-closed via candidateID mismatch; refreshes candidates |
| Sibling Insertion on Badge | Notch HUD alert banner | Structural ancestry index shift rejects candidate fail-closed; dismiss overlay and refresh candidates |
| Menu Leaf Mismatch | Notch HUD alert banner | Resolved AXMenuItem title differs from confirmed leaf or matches destructive stem; aborts dispatch fail-closed |
| Badge Overlay Timeout | Overlay dismisses silently | Auto-dismiss after 5s silence or 15s hard cap, record timeout in audit |
| Confirmation Banner Timeout | Notch HUD banner dismisses | Auto-cancels action fail-closed after 5s silence or 15s hard cap; records cancellation in audit |
| Post-assert Timeout | Notch HUD failed assertion | Report unobserved state after observation deadline; manual retry means initiating a fresh command (new capture, new planning, fresh confirmation if destructive), never automatic re-execution of a non-idempotent timed-out dispatch |
| Invalid Menu Path | Notch HUD path error | List available items under parent menu (non-destructive inspection up to depth 3; dismisses menu on cancel/failure) |

## Testing strategy

| Layer | Scope | Gate |
|---|---|---|
| Unit | Menu hierarchy step parsing | "menu File > Save then click Confirm" splits on " then " (case-insensitive) into 2 steps while preserving ">" within the menu path. Segment quoting syntax is scoped to CLI and automation socket (e.g. menu File > "Export then Print"); spoken input uses unquoted token splitting and cannot generate quote characters |
| Unit | Desktop candidate filtering and protection | All protected fields rejected |
| Unit | Menu allowlist explicit classification | ["View","Zoom In"] auto-runs; ["File","Export"] triggers confirmation |
| Unit | Menu application target verification | Application switch before menu dispatch aborts execution; live-updating window content within target app does not invalidate menu action |
| Unit | Menu leaf title mismatch aborts execution | Resolved AXMenuItem title differing from confirmed path or matching destructive stem aborts dispatch fail-closed |
| Unit | Destructive badge confirmation gate | Picking destructive badge "Cancel" prompts confirmation banner |
| Unit | Candidate action fingerprint scope | Candidate actions retain expectedFingerprint bound to window snapshot at plan time; ambient window mutations or ancestry index shifts reject fail-closed with staleTarget |
| Unit | Immediate chain failure on .actionFailed | ControlSession.record(.actionFailed) directly invokes finish(.failed), halting multi-step chain immediately without caller convention |
| Unit | Badge revalidation and drift check | Stale candidate ID or title mismatch aborts dispatch; PID/windowTitle mismatch prevents re-binding |
| Unit | Pre-flight timing verification | PreFlightCheck validates isEnabled and !isProtected inside execute() after approval |
| Unit | Badge dictation suppression | Target application dictation insertion suppressed during badge overlay |
| Unit | Confirmation banner spoken safety | Spoken "confirm action" / "approve action" / "cancel action" / "abort action" recognized; bare words rejected; AVAudioEngine voiceProcessing ducking and speech energy threshold enforced |
| Unit | Confirmation banner timeout | Auto-cancels fail-closed after 5s silence or 15s hard cap |
| Unit | Multi-key effectUnknown chain tolerance | 3 consecutive .key actions (.effectUnknown, each requiring individual confirmation banner) succeed without triggering no-effect halt; 2 consecutive .noEffectObserved or .timedOut halt chain fail-closed |
| Unit | Post-action observation runs after AX timeout | Post-action diff observation runs after AX timeout/cannotComplete; modal sheet appearance verifies as .effectObserved; absence of diff verifies as .timedOut and prevents action retry |
| Unit | Consecutive AX timeouts halt session | 2 consecutive .timedOut outcomes halt multi-step chain fail-closed |
| Unit | Spatial row-bucket badge ordering | Badges 1..N order by anchored row (Y ±4pt threshold), then X |
| Unit | Resilient audit journal decoding | Corrupt or unknown action entries preserved without wiping 500-entry journal; transient read errors abort append without overwrite; initial corrupt backup control-audit.json.corrupt.initial and up to 2 timestamped backups (capped at 3 files) written on whole-file JSON syntax corruption |
| Integration | Badge overlay coordinate mapping | AX top-left to Cocoa primary screen bottom-left conversion across screens |
| Integration | AXMenuBar hierarchy traversal | Native macOS menu bar resolution with lazy-menu fallback (depth ≤3) |
| Benchmark | Fast-path execution latency | Target composite pipeline latency p50 < 85ms, p95 < 140ms directly measured on standard AppKit target (intent parse + active target capture + pre-flight + semantic dispatch + immediate verification). Component capture p50 < 20ms, p95 < 35ms on Apple Silicon M-series |
| E2E | Computer-use automated validation | Tab navigation, state inspection, and audio transcribe round-trip |

## Out of scope

- OCR-based vision control for non-accessibility games and full-screen streaming.
- Cross-machine network desktop control.
- Hardware-level mouse emulation outside CGEvent and AX APIs.
