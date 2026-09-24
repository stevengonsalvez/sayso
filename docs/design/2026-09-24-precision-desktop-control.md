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
           │ (isDestructive?)  │           │ user confirms ("confirm" / "cancel")
           └─────────┬─────────┘           │ (Dictation suppressed; audio scoped to banner)
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
| ControlPolicy | SaysoCore | Fail-closed destructive classification and review gating | Extended: explicit .menu case across switches; compiler eliminates default: fallbacks; destructive check wins |
| AXDesktopController | SaysoCore | Semantic AX action dispatch and confirmation-gated pointer clicks | Extended: DesktopAction.menu(path:expectedFingerprint:) and 250ms timeout; maps AX timeouts to .effectUnknown; pre-flight runs inside execute() |
| ControlObservation | SaysoCore | Cross-process AX attribute diff and post-action verification | Extended: window-frame/attribute diff for menus; 1200ms hard deadline ceiling |
| ControlSession | SaysoCore | Multi-step lifecycle, budget enforcement, and state transitions | Extended: halts fail-closed on 2 consecutive unknown effects; effectUnknown preserves no-effect budget |
| NotchHUD | SaysoNotch | Visual reticle, badge overlay, and telemetry breakdown | Extended: spatial badge rendering on nonactivating panel; spoken confirm/cancel banner |
| ControlAuditStore | SaysoCore | Resilient persistent recording of newest 500 entries | Extended: Phase 1 per-entry decode via JSONSerialization preserving raw Data on unknown cases; corrupt backup |

## Migration Order & Schema Resilience for ControlAuditStore

| Phase | Scope | Deployment Rule & Disk Invariant |
|---|---|---|
| Phase 1: Storage Resilience | Ship per-entry decode in ControlAuditStore | Decodes array entries individually from disk via JSONSerialization. Unrecognized actions or schema variants are parsed as RawControlAuditEntry (preserving raw JSON Data). ExecutionTelemetry enums use RawRepresentable with unknown fallbacks. On write, raw entries are preserved and re-serialized in original sequence. Raw entries count toward the 500-entry retention cap. On decode failure, writes timestamped backup control-audit.json.corrupt-<timestamp> before fallback. Minimum downgrade floor: Phase 1 release is the compatibility floor; rollback past Phase 1 is unsupported because pre-Phase-1 builds overwrite journal with empty array on decode failure. Ships in production release before Phase 2. |
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
│ expectedFingerprint String │         │ stepResult StepResult      │
└────────────────────────────┘         └────────────────────────────┘
```

| Entity | Key Fields | Relationships |
|---|---|---|
| DesktopCandidate | id, role, title, bounds, identifier, state | Source for target resolution; bounds: CGRect? drives spatial badge layout (excluded from fingerprint) |
| DesktopElement | id, role, title, bounds, supportsPress... | Internal AX snapshot model extended with bounds: CGRect? (excluded from fingerprint) |
| DesktopCandidateID | processIdentifier, windowTitle, role, identifier, ancestry | Base64-encoded structural locator |
| DesktopCandidateState | isEnabled, isProtected, supportsPress, supportsFocus, supportsSelection, supportsPointerClick | Checked during PreFlightCheck |
| ControlPlanStep | id, action, confidence, reason, candidateTitle, requiresConfirmation | Action (.press, .select, .focus, .clickAt) carries elementID; executed by AXDesktopController |
| DesktopAction.menu | path: [String], expectedFingerprint: String | Traversed via AXMenuBar; protected by expectedFingerprint TOCTOU guard |
| ExecutionTelemetry | stepId, planMs, captureMs, dispatchMs, verifyMs, totalMs, stepResult | Matches ControlPlanStep.id; decoded optionally in ControlAuditEntry |

## Latency Budget

| Phase | Happy-Path Target | Worst-Case Bound | Note |
|---|---|---|---|
| Intent Parsing | 8ms | 15ms | In-memory closed-vocabulary pattern match |
| Active Target & AX Capture | 40ms (2x 20ms p50) | 1500ms (2x 750ms) | Accounts for pre-activation and post-activation captures in execute() |
| Pre-flight Attribute Check | 4ms (2x 2ms) | 500ms (2x 250ms) | isEnabled and isProtected attribute checks |
| Semantic Action Dispatch | 4ms | 250ms | AXUIElementPerformAction (bounded by 250ms messaging timeout) |
| Post-assert Diff | 15ms (initial check) | 1200ms | Immediate check at 0ms sleep; 1200ms total observe deadline (up to 8 captures, 100ms cap each) |
| Total (Benign Fast-Path) | ~71ms | ~3.5s | Fast-path p50 target ~71ms; worst-case bounded by timeouts |

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
[Voice Cmd] ──Resolver (ambiguous)──▶ [Badge Overlay 1..N (max 15s)] ──voice "badge 1"──▶ [Revalidation Capture: verify id & title] ──Assert pid & windowTitle match──▶ [Re-bind expectedFingerprint] ──▶ [Confirmation Gate: "Cancel" requires review] ──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm" / "cancel")──▶ [execute() Fresh Capture + PreFlightCheck isEnabled] ──▶ [Dispatch] ──▶ [Done]
```

Menu hierarchy path (Unlisted / destructive menu requires confirmation):

```
["menu File > Save"] ──Non-destructive AXMenuBar Traversal (depth ≤3)──▶ [Locate Leaf AXMenuItem] ──▶ [Confirmation Gate (unlisted/destructive)] ──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm" / "cancel")──▶ [execute() Fresh Capture + PreFlightCheck isEnabled] ──▶ [AXPress Leaf] ──▶ [Post-assert] ──▶ [Done]
```

Multi-step chain execution semantics:

| Outcome Step Result | Mapped From | Handling in Multi-Step Chains |
|---|---|---|
| .effectObserved | ControlEffect.observed, .alreadySatisfied | State change verified. Reset consecutiveNoEffectCount and consecutiveUnknownCount to 0. Proceed to step k+1 |
| .effectUnknown | ControlEffect.unknown, AX timeout/cannotComplete | Allowed menu/key without diff, or AX timeout. Increment consecutiveUnknownCount. Proceed if counter < maxConsecutiveUnknown (2); halt chain if counter == 2. consecutiveNoEffectCount remains unchanged |
| .noEffectObserved | ControlEffect.notObserved | Increment consecutiveNoEffectCount by 1. Proceed if counter < maxConsecutiveNoEffect (2); halt chain if counter == 2 |
| .actionFailed | Hard OS/AX error | Hard structural failure (invalidUIElement, apiDisabled). Halt chain immediately via session.fail() |
| Budget Cap | Session counter | Session halts immediately if total actions reach maxActions (default 12) |

## Safety Invariants

| Guard | Rule | Enforcement Mechanism |
|---|---|---|
| Protected Fields | Never synthesize input into secure fields | Excluded by DesktopCandidateState.isProtected |
| Exact Matching | Single unconfirmed action requires 1 exact match | DesktopCandidateResolver flags ambiguity; headless caller returns ambiguity error JSON; interactive caller shows badge overlay |
| Interactive Disambiguation | Multiple matches display numbered badges | App controller catches ambiguous resolution and shows overlay |
| Badge Disambiguation Only | Badge selection disambiguates target, never confirms | Destructive badge targets (e.g. Cancel) still require confirmation banner |
| Non-Activating Overlay | Badge window must not steal target focus | NSPanel with .nonactivatingPanel style mask preserves active app |
| Badge Dictation Suppression | Suppress dictation text insertion during badge overlay | While badge overlay NSPanel is active, speech recognition text insertion into target app is suppressed; audio stream is scoped exclusively to badge grammar ("badge <N>" or "cancel") |
| Spatial Badge Ordering | Badges ordered by anchored row-buckets then X | Grouped by anchor Y (±4pt threshold), then sorted by bounds.origin.x |
| Coordinate Conversion | Top-left AX bounds converted to Cocoa screen | cocoaY = NSScreen.screens[0].frame.maxY - axY - axHeight |
| Badge Candidate Revalidation | Re-asserts candidateID & title match on frontmost window | Candidate revalidation verifies candidateID and title against frontmost window; asserts processIdentifier and windowTitle match before re-binding expectedFingerprint. Absolute screen bounds are not pinned to ±2pt so window move/resize does not trigger false rejection |
| Pre-flight Verification Timing | Pre-flight checks and fingerprint guard run after confirmation | PreFlightCheck (isEnabled, !isProtected) and expectedFingerprint comparison execute inside execute() immediately prior to action dispatch, ensuring checks remain fresh even after long confirmation pauses |
| Fingerprint Bounds Exclusion | Snapshot fingerprint invariant | bounds: CGRect? on DesktopCandidate and DesktopElement are excluded from window snapshot fingerprint hash, ensuring window move or resize does not trigger false TOCTOU mismatch |
| Badge Grammar Prefix | Spoken badge selection requires prefix | "badge <N>" required; bare digits ignored on open mic |
| Badge VAD Timeout | Overlay dismisses after 5s silence or 15s max | 5.0s timer extended on voice activity detection; hard cap of 15.0s overlay lifetime prevents mic chatter lock |
| Confirmation Banner Grammar | Spoken confirmation vocabulary with dictation suppression | Spoken "confirm", "approve", or "yes" confirms; "cancel", "deny", or "no" aborts. Dictation insertion into target app is suppressed while banner is active |
| Destructive Actions | Actions in ControlPolicy.destructiveWords require review | ControlPolicy.requiresConfirmation gates execution |
| Pointer Click Safety | Raw CGEvent mouse clicks always require review | Kept: DesktopAction.isDestructive returns true for .clickAt (:386-388) |
| Keystroke Safety | Keyboard shortcuts always require review | Kept: DesktopAction.isDestructive returns true for .key (:386-388) |
| Fail-Closed Menu Policy | Explicit .menu case; allowlist check must be non-destructive | safeMenuAllowlist.contains(path) && !isDestructiveControlTitle(leaf) |
| Menu Exhaustive Switches | Enumerate all DesktopAction cases via compiler | Eliminate default: fallbacks across all action switches (including isDestructive, requiresConfirmation, requiresActiveTarget, validatedNextTargetBundleIdentifier, execute); compiler enforces explicit handling |
| Menu Fingerprint Guard | Menu actions bound to planned window | DesktopAction.menu carries expectedFingerprint to prevent TOCTOU mismatch |
| Active Menu Target | Menus only target frontmost application | ControlPolicy.requiresActiveTarget returns true for .menu |
| Menu Inspection Traversal | Opening parent menu for dynamic children allowed without confirmation | Opening menu bar item or submenu for lazy evaluation (menuNeedsUpdate) is non-destructive navigation (no confirmation required; max depth 3). If cancelled, timed out, or unlocated, controller dismisses menu cleanly via AXCancel or Escape |
| AX Timeout Mapping | Timeouts map to .effectUnknown; only hard errors fail | AXUIElementPerformAction timeouts or kAXErrorCannotComplete (common on modal-opening controls) map to .effectUnknown and proceed to observation. Only hard structural errors (kAXErrorInvalidUIElement, kAXErrorAPIDisabled, kAXErrorActionUnsupported) map to .actionFailed and halt session |
| Consecutive Unknown Effect Cap | Unresponsive target application guard | Multi-step chains halt immediately if 2 consecutive actions yield .effectUnknown (e.g. repeated AX timeouts or kAXErrorCannotComplete), preventing session stall |
| Bounded AX Timeout | Cross-process AX queries cannot hang UI | AXUIElementSetMessagingTimeout 0.25s per call, 500ms soft clock check |
| Resilient Audit Storage | Journal schema changes must never wipe history | ControlAuditStore decodes entries individually, preserving raw un-decodable entries as raw Data. Phase 1 per-entry decode deploys before Phase 2 (.menu). Raw entries count toward 500-entry cap and are preserved on re-save. On decode failure, writes timestamped backup |
| Observation Polling | State diff observation capped at 1200ms hard deadline | Polling terminates as soon as 1200ms hard ceiling elapses regardless of attempt count (up to 8 captures with 100ms cap and 125ms intervals); initial check at 0ms sleep |
| Chain No-Effect Limit | Consecutive no-effect actions capped at 2 | Tolerates 1 no-effect step; halts on 2 consecutive no-effects |

Safe menu allowlist (exact full path match, standard AppKit):
`[["View", "Zoom In"], ["View", "Zoom Out"], ["View", "Actual Size"], ["Window", "Zoom"]]`
Rule: Destructive check always wins. Even if in allowlist, any title matching destructive stems requires confirmation. Non-English menu paths fail-safe to requiring confirmation banner.

## Errors

| Failure mode | User-visible surface | Recovery |
|---|---|---|
| AX API Timeout | Notch HUD warning banner | Map to .effectUnknown, observe for modal/sheet appearance; alert in HUD if diff unobserved after 1200ms |
| Stale Target on Badge | Notch HUD alert banner | Abort dispatch when candidateID, title, or bounds (±2pt) mismatch; refresh list |
| Badge Overlay Timeout | Overlay dismisses silently | Auto-dismiss after 5s silence or 15s hard cap, record timeout in audit |
| Post-assert Timeout | Notch HUD failed assertion | Report unobserved state after 1200ms observe deadline, offer manual retry |
| Invalid Menu Path | Notch HUD path error | List available items under parent menu (non-destructive inspection up to depth 3; dismisses menu on cancel/failure) |

## Testing strategy

| Layer | Scope | Gate |
|---|---|---|
| Unit | Menu hierarchy step parsing | "menu File > Save then click Confirm" splits into 2 steps |
| Unit | Desktop candidate filtering and protection | All protected fields rejected |
| Unit | Menu allowlist explicit classification | ["View","Zoom In"] auto-runs; ["File","Export"] triggers confirmation |
| Unit | Menu expectedFingerprint verification | Window switch before menu dispatch aborts execution |
| Unit | Destructive badge confirmation gate | Picking destructive badge "Cancel" prompts confirmation banner |
| Unit | Immediate chain failure on .actionFailed | Action failure at AX level halts multi-step chain immediately |
| Unit | Badge revalidation and drift check | Stale candidate ID or title mismatch aborts dispatch; PID/windowTitle mismatch prevents re-binding |
| Unit | Pre-flight timing verification | PreFlightCheck validates isEnabled and !isProtected inside execute() after approval |
| Unit | Badge dictation suppression | Target application dictation insertion suppressed during badge overlay |
| Unit | Confirmation banner spoken grammar | Spoken confirm/cancel recognized; dictation suppressed during confirmation banner |
| Unit | Consecutive unknown effect cap | 2 consecutive .effectUnknown outcomes halt multi-step chain fail-closed |
| Unit | Spatial row-bucket badge ordering | Badges 1..N order by anchored row (Y ±4pt threshold), then X |
| Unit | Resilient audit journal decoding | Corrupt or unknown action entries preserved without wiping 500-entry journal |
| Integration | Badge overlay coordinate mapping | AX top-left to Cocoa primary screen bottom-left conversion across screens |
| Integration | AXMenuBar hierarchy traversal | Native macOS menu bar resolution with lazy-menu fallback (depth ≤3) |
| Benchmark | Fast-path execution latency | Target p50 < 75ms, p95 < 125ms for full execution (intent parse + active target capture + pre-flight + semantic dispatch + immediate verification on standard AppKit target). Component capture p50 < 20ms, p95 < 35ms on Apple Silicon M-series |
| E2E | Computer-use automated validation | Tab navigation, state inspection, and audio transcribe round-trip |

## Out of scope

- OCR-based vision control for non-accessibility games and full-screen streaming.
- Cross-machine network desktop control.
- Hardware-level mouse emulation outside CGEvent and AX APIs.
