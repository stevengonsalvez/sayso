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
                   │                        ▼ (Spoken "badge 2" within 5s / VAD)
                   │                      [Re-capture AX + verify id, title, bounds]
                   │                        │ (Re-bind expectedFingerprint)
                   │                        ▼
                   │                      [Destructive Gate?]──yes──▶ [NotchHUD Banner]
                   │                        │ no                       │ user confirms
                   │                        ▼──────────────────────────┘
                   │                        │
                   ├──yes (headless)────▶ [Caller returns ambiguous error JSON]
                   │
                   no (1 match)
                   ▼────────────────────────┘
           ┌───────────────────┐ Pre-flight check (budget <2ms, timeout 250ms)
           │ PreFlightCheck    │ (isEnabled, !isProtected, 250ms per-call timeout)
           └─────────┬─────────┘
                     │ pass
                     ▼
           ┌───────────────────┐ ControlPolicy check
           │ Destructive Gate? │──yes──▶ [NotchHUD Confirmation Banner]
           └─────────┬─────────┘           │ user confirms
                     │ no (canAutoRun)     ▼
                     ▼─────────────────────┘
           ┌───────────────────┐ Semantic AX Action (budget <3ms)
           │AXDesktopController│────────────┐ (press, select, focus, menu;
           └─────────┬─────────┘            │  .clickAt pointer and .key always confirm)
                     │               ┌──────▼──────┐
                     │               │ Target App  │
                     ▼               └──────┬──────┘
           ┌───────────────────┐            │
           │ ControlObservation│◀───────────┘ AX diff (8 captures / 875ms poll)
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
| AXCandidateCapture | SaysoCore | Bounded frontmost-window AX traversal (<25ms) | Extended: off-main background task with 500ms monotonic clock deadline |
| DesktopCandidates | SaysoCore | Element representation: stable locator, role, state | Extended: bounds: CGRect? for spatial badge layout |
| DesktopCandidateResolver | SaysoCore | Exact title and row resolution, badge overlay indexing | Extended: anchored row-bucket spatial sorting (anchor Y + 4pt) |
| ControlPolicy | SaysoCore | Fail-closed destructive classification and review gating | Extended: explicit .menu case in all 7 switches; destructive check wins |
| AXDesktopController | SaysoCore | Semantic AX action dispatch and confirmation-gated pointer clicks | Extended: DesktopAction.menu(path:expectedFingerprint:) and 250ms timeout |
| ControlObservation | SaysoCore | Cross-process AX attribute diff and post-action verification | Extended: window-frame/attribute diff for menus; unverified yields .effectUnknown |
| ControlSession | SaysoCore | Multi-step lifecycle, budget enforcement, and state transitions | Kept: orchestrator calls fail() immediately on action failure |
| NotchHUD | SaysoNotch | Visual reticle, badge overlay, and telemetry breakdown | Extended: spatial badge rendering on nonactivating panel using Cocoa coordinates |
| ControlAuditStore | SaysoCore | Resilient persistent recording of newest 500 entries | Extended: per-entry decode preserving raw data on unknown action cases |

## Data model

```
┌─ DesktopCandidate ─────────┐         ┌─ ControlPlanStep ──────────┐
│ id       DesktopCandidateID│──1:1──▶ │ id         UUID            │
│ role     String            │         │ action     DesktopAction   │
│ title    String            │         │ confidence Double          │
│ bounds   CGRect?           │         │ reason     String          │
│ identifier String?         │         │ candidateTitle String?     │
│ state    CandState         │         │ candidateID CandidateID?   │
│   isEnabled            Bool│         │ requiresConfirmation Bool  │
│   isProtected          Bool│         └─────────────┬──────────────┘
│   supportsPress        Bool│                       │ 1:1
│   supportsFocus        Bool│                       ▼
│   supportsSelection    Bool│         ┌─ ExecutionTelemetry ───────┐
│   supportsPointerClick Bool│         │ stepId     UUID            │
└────────────────────────────┘         │ planMs     Double          │
                                       │ captureMs  Double          │
┌─ DesktopAction.menu ───────┐         │ dispatchMs Double          │
│ path     [String]          │──▶      │ verifyMs   Double          │
│ expectedFingerprint String │         │ totalMs    Double          │
└────────────────────────────┘         │ stepResult StepResult      │
                                       └────────────────────────────┘
```

| Entity | Key Fields | Relationships |
|---|---|---|
| DesktopCandidate | id, role, title, bounds, identifier, state | Source for target resolution; bounds drives spatial badge layout |
| DesktopCandidateID | processIdentifier, windowTitle, role, identifier, ancestry | Base64-encoded structural locator |
| DesktopCandidateState | isEnabled, isProtected, supportsPress, supportsFocus, supportsSelection, supportsPointerClick | Checked during PreFlightCheck |
| ControlPlanStep | id, action, confidence, reason, candidateTitle, candidateID, requiresConfirmation | Extended with candidateID; executed by AXDesktopController |
| DesktopAction.menu | path: [String], expectedFingerprint: String | Traversed via AXMenuBar; protected by expectedFingerprint TOCTOU guard |
| ExecutionTelemetry | stepId, planMs, captureMs, dispatchMs, verifyMs, totalMs, stepResult | Matches ControlPlanStep.id; decoded optionally in ControlAuditEntry |

## Latency Budget

| Phase | Happy-Path Target | Worst-Case Bound | Note |
|---|---|---|---|
| Intent Parsing | 8ms | 15ms | In-memory closed-vocabulary pattern match |
| AX Candidate Capture | 12ms | 750ms | 500ms soft clock check plus single 250ms call overrun |
| Pre-flight Attribute Check | 2ms | 250ms | Single-element AXUIElementSetMessagingTimeout |
| Semantic Action Dispatch | 2ms | 10ms | Direct AXUIElementPerformAction |
| Post-assert Diff | 125ms (first poll tick) | 875ms | 8 captures with 7 intervals of 125ms |
| Total (Benign Fast-Path) | ~150ms | ~1.9s | ASR streaming audio transcription tracked separately |

## Interface

```
┌────────────────────────────────────────────────────────┐
│ Sayso Notch Telemetry (Jev Fast-Path)                  │
├────────────────────────────────────────────────────────┤
│ Target: [Menu: Window > Zoom]        Badge: [N/A]      │
│ Resolution: Full path allowlist      Risk: Benign      │
│ Pre: Enabled, Unprotected, Timeout 250ms [PASS]        │
│ Action: AXUIElementPerformAction [DISPATCHED in 2ms]   │
│ Post: Window Frame Resized [VERIFIED in 125ms]         │
│ Target Budget: Plan 8ms, Capture 12ms, Exec 130ms      │
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
[Voice Cmd] ──Plan (8ms)──▶ [AX Capture (12ms)] ──Pre-check (2ms)──▶ [AX Dispatch (2ms)] ──Post-assert (125ms)──▶ [Done (~150ms target)]
```

Ambiguous match path (Multiple targets sharing label; destructive badge requires confirmation):

```
[Voice Cmd] ──Resolver (ambiguous)──▶ [Badge Overlay 1..N] ──voice "badge 1"──▶ [Re-capture AX + verify id, title, bounds ±2pt] ──Re-bind fingerprint──▶ [Destructive Gate: "Cancel" requires review] ──▶ [NotchHUD Confirmation Banner] ──user confirms──▶ [Dispatch] ──▶ [Done]
```

Menu hierarchy path (Unlisted / destructive menu requires confirmation):

```
["menu File > Save"] ──Read-only AXMenuBar Traversal──▶ [Locate Leaf AXMenuItem] ──Pre-check isEnabled──▶ [NotchHUD Confirmation Banner] ──user confirms──▶ [AXPress Leaf] ──▶ [Post-assert] ──▶ [Done]
```

Multi-step chain execution semantics:

| Outcome Step Result | Handling in Multi-Step Chains |
|---|---|
| .effectObserved | State change verified. Reset no-effect counter to 0. Proceed to step k+1 |
| .effectUnknown | Allowed menu or key without distinct diff. Proceed, verify target on fresh snapshot |
| .noEffectObserved | Increment no-effect counter. Proceed if counter < 2; halt chain if counter == 2 |
| .actionFailed | Action failed at OS/AX level (e.g. element destroyed, timeout). Halt chain immediately via session.fail() |
| Budget Cap | Session halts immediately if total actions reach maxActions (default 12) |

## Safety Invariants

| Guard | Rule | Enforcement Mechanism |
|---|---|---|
| Protected Fields | Never synthesize input into secure fields | Excluded by DesktopCandidateState.isProtected |
| Exact Matching | Single unconfirmed action requires 1 exact match | ControlPlanner throws invalidAction on ambiguity in headless mode |
| Interactive Disambiguation | Multiple matches display numbered badges | App controller catches ambiguous resolution and shows overlay |
| Badge Disambiguation Only | Badge selection disambiguates target, never confirms | Destructive badge targets (e.g. Cancel) still require confirmation banner |
| Non-Activating Overlay | Badge window must not steal target focus | NSPanel with .nonactivatingPanel style mask preserves active app |
| Spatial Badge Ordering | Badges ordered by anchored row-buckets then X | Grouped by anchor Y (±4pt threshold), then sorted by bounds.origin.x |
| Coordinate Conversion | Top-left AX bounds converted to Cocoa screen | cocoaY = NSScreen.screens[0].frame.maxY - axY - axHeight |
| Triple Revalidation | UI changes during overlay abort action | Re-capture frontmost AX tree; assert candidateID, title, AND bounds (±2pt) |
| Fingerprint Re-binding | Re-bound snapshot fingerprint after overlay | Rebuild plan step with fresh expectedFingerprint to prevent TOCTOU rejection |
| Badge Grammar Prefix | Spoken badge selection requires prefix | "badge <N>" required; bare digits ignored on open mic |
| Badge VAD Timeout | Overlay dismisses after 5s or VAD silence | 5.0s timer extended on voice activity detection speech onset |
| Destructive Actions | Actions in ControlPolicy.destructiveWords require review | ControlPolicy.requiresConfirmation gates execution |
| Pointer Click Safety | Raw CGEvent mouse clicks always require review | ControlPolicy.requiresConfirmation returns true for .clickAt |
| Keystroke Safety | Keyboard shortcuts always require review | ControlPolicy.requiresConfirmation returns true for .key |
| Fail-Closed Menu Policy | Explicit .menu case; allowlist check must be non-destructive | safeMenuAllowlist.contains(path) && !isDestructiveControlTitle(leaf) |
| Menu Exhaustive Switches | Explicit .menu branches in all 7 switches; ban default | validatedNextTargetBundleIdentifier, isDestructive, requiresActiveTarget, requiresConfirmation, effect, result, execute |
| Menu Fingerprint Guard | Menu actions bound to planned window | DesktopAction.menu carries expectedFingerprint to prevent TOCTOU mismatch |
| Active Menu Target | Menus only target frontmost application | ControlPolicy.requiresActiveTarget returns true for .menu |
| Bounded AX Timeout | Cross-process AX queries cannot hang UI | AXUIElementSetMessagingTimeout 0.25s per call, 500ms soft clock check |
| Resilient Audit Storage | Journal schema changes must never wipe history | ControlAuditStore decodes entries individually, preserving raw un-decodable entries |
| Observation Polling | State diff observation capped at 875ms | 8 captures with 7 intervals of 125ms |
| Chain No-Effect Limit | Consecutive no-effect actions capped at 2 | Tolerates 1 no-effect step; halts on 2 consecutive no-effects |

Safe menu allowlist (exact full path match, standard AppKit):
`[["View", "Zoom In"], ["View", "Zoom Out"], ["View", "Actual Size"], ["Window", "Zoom"]]`
Rule: Destructive check always wins. Even if in allowlist, any title matching destructive stems requires confirmation. Non-English menu paths fail-safe to requiring confirmation banner.

## Errors

| Failure mode | User-visible surface | Recovery |
|---|---|---|
| AX API Timeout | Notch HUD warning banner | Abort action after capture clock deadline, alert in HUD |
| Stale Target on Badge | Notch HUD alert banner | Abort dispatch when candidateID, title, or bounds (±2pt) mismatch; refresh list |
| Badge Overlay Timeout | Overlay dismisses silently | Auto-dismiss after 5s VAD timeout, record timeout in audit |
| Post-assert Timeout | Notch HUD failed assertion | Report unobserved state after 875ms, offer manual retry |
| Invalid Menu Path | Notch HUD path error | List available items under parent menu (fallback to opening parent for lazy menus) |

## Testing strategy

| Layer | Scope | Gate |
|---|---|---|
| Unit | Menu hierarchy step parsing | "menu File > Save then click Confirm" splits into 2 steps |
| Unit | Desktop candidate filtering and protection | All protected fields rejected |
| Unit | Menu allowlist explicit classification | ["View","Zoom In"] auto-runs; ["File","Export"] triggers confirmation |
| Unit | Menu expectedFingerprint verification | Window switch before menu dispatch aborts execution |
| Unit | Destructive badge confirmation gate | Picking destructive badge "Cancel" prompts confirmation banner |
| Unit | Immediate chain failure on .actionFailed | Action failure at AX level halts multi-step chain immediately |
| Unit | Badge triple-revalidation race prevention | Stale candidate ID, title mismatch, or bounds shift (>2pt) aborts dispatch |
| Unit | Badge fingerprint re-binding | Re-captured candidate re-binds expectedFingerprint before dispatch |
| Unit | Spatial row-bucket badge ordering | Badges 1..N order by anchored row (Y + 4pt), then X |
| Unit | Resilient audit journal decoding | Corrupt or unknown action entries preserved without wiping 500-entry journal |
| Integration | Badge overlay coordinate mapping | AX top-left to Cocoa primary screen bottom-left conversion across screens |
| Integration | AXMenuBar hierarchy traversal | Native macOS menu bar resolution with lazy-menu fallback |
| Benchmark | Fast-path execution latency | Target p95 < 45ms, p50 < 30ms AX capture + dispatch on Apple Silicon M-series on standard AppKit target |
| E2E | Computer-use automated validation | Tab navigation, state inspection, and audio transcribe round-trip |

## Out of scope

- OCR-based vision control for non-accessibility games and full-screen streaming.
- Cross-machine network desktop control.
- Hardware-level mouse emulation outside CGEvent and AX APIs.
