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
| Hands-Free User | Disambiguate without mouse | Spoken badge selection ("badge 2") and spoken confirmation for .spokenOrPhysical review tier (including navigation keys); confirms .physical tier via macOS Accessibility (Voice Control, Switch Control, Dwell Click) |
| Power Navigator | Safe system menu navigation | Cross-process menu bar hierarchy navigation ("menu File > Save") |

## Approach

| Option | Summary | Tradeoff | Picked? |
|---|---|---|---|
| A | Jev Fast Path on SaysoCore | Low latency, deterministic, bounded AX assertions | Yes |
| B | Hierarchical Breadcrumb & Focus Traversal | Deep navigation, high interaction overhead | No |
| C | Multimodal Vision + AX Dual-Grounding | High resource cost, 1-2s latency, non-deterministic | No |

**Why A:** Integrates jev-use closed-vocabulary fast-path planner patterns into existing SaysoCore types, leveraging bounded cross-process AX queries and instant badge overlays while maintaining full safety guarantees. Residual Risk: macOS accessibility architecture allows any local process with system-wide Accessibility trust (AXIsProcessTrusted) to post events to AppKit windows. This risk is accepted because obtaining Accessibility trust already grants arbitrary desktop control.

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
           │ execute() Fresh Pre-Dispatch Verification    │
           │ • Element actions: capture & fingerprint check │
           │ • Menu / app actions: target bundle ID check │
           │ • Pre-flight check: isEnabled, !isProtected  │
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
           │ ControlObservation│◀───────────┘ AX diff (1200ms soft ceiling)
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
| ControlPlanner | SaysoCore | Sub-15ms closed-vocab intent parsing alongside LLM fallback | Extended: spoken grammar parses menu hierarchy using "choose" (e.g. "menu File choose Save"); CLI and automation socket use ">"; path length < 2 or > 3 rejects fail-closed with invalidMenuPath (e.g. ["File"] rejected) before confirmation; during execution post-confirmation, if a leaf item is missing under an existing parent, execute() fails with menuItemNotFound and can inspect parent menu items |
| AXCandidateCapture | SaysoCore | Bounded frontmost-window AX traversal (p50 < 20ms, p95 < 35ms) | Extended: off-main background task with 500ms monotonic clock deadline |
| DesktopCandidates | SaysoCore | Element representation: stable locator, role, state | Extended: bounds: CGRect? on DesktopCandidate and DesktopElement; bounds excluded from fingerprint hash |
| DesktopCandidateResolver | SaysoCore | Exact title and row resolution, badge overlay indexing | Extended: anchored row-bucket spatial sorting (anchor Y ±4pt threshold); returns .ambiguous |
| ControlPolicy | SaysoCore | Fail-closed destructive classification and review gating | Formalized invariant: compiler eliminates default: fallbacks; DesktopAction.isDestructive for .menu checks path.contains(where: { isDestructiveControlTitle($0) }) for intrinsic reporting; ControlPolicy.requiresConfirmation gates unlisted menus (!safeMenuAllowlist.contains(path)), non-English target application effective localization (checked via target bundle preferred localization or AppleLanguages override, falling back to system locale), non-ASCII candidate titles, or destructive titles; isDestructiveControlTitle uses two-pass matcher over single words/compounds (signout, logout, quit, disconnect, leave) and adjacent word bigrams (sign out, log out); resend is an explicit entry in destructiveWords and physicalConfirmationWords; ControlPolicy.confirmationTier(step) returns .autoRun iff canAutoRun(step) is true; if canAutoRun is false, exhaustively maps all 13 DesktopAction cases: .quit, .clickAt, and mutating keys (.return, .escape, .space, .undo, .redo) map to .physical; .key for navigation keys (.tab, .up, .down, .left, .right) maps to .spokenOrPhysical; .press, .select, and .menu map to .physical if matching physicalConfirmationWords (pay, purchase, transfer, send, delete, erase, trash, empty, quit, reset, revoke, deactivate, uninstall, remove, clear, discard, order, book, publish, post, share, confirm, approve, sign out, log out, signout, logout) or unclassified destructive stems, else .spokenOrPhysical; .type, .focus, .scroll, .open, .openFolder, .activate, and .activateApplication map to .spokenOrPhysical; for headless CLI/socket callers, ALL confirmation-gated actions enforce .physical pointer confirmation; physical tier wins on multi-word matches; destructive check wins |
| AXDesktopController | SaysoCore | Semantic AX action dispatch and confirmation-gated pointer clicks | Extended: DesktopAction.menu(path:expectedApplicationTarget:) and 250ms timeout; scopes AXUIElementSetMessagingTimeout 0.25s per call to target application element and traversed elements (leaving system-wide AX and TextTools dictation unaffected); runs post-action observation after cannotComplete/timeout; timed-out dispatches are non-retryable; on any AX timeout or cannotComplete without diff (regardless of elapsed time), execute() returns ControlObservationResult with effect = .timedOut rather than throwing an un-audited error; menu traversal, leaf AXTitle re-check, and in-memory pre-flight run inside execute() after confirmation; if menu traversal times out, performs kAXCancelAction or verifies AXExpanded/AXSelected before kAXPressAction on opened parent menu item to dismiss menus without reopening (never synthesizes raw CGEvent Escape keys without confirmation); if dismissal fails, shows non-fatal HUD alert "Menu Left Open" and logs menuDismissalFailed to audit |
| ControlObservation | SaysoCore | Cross-process AX attribute diff and post-action verification | Extended: window-frame/attribute diff for menus; runs after timeout to detect modal sheets; 1200ms monotonic soft ceiling (~1450ms worst case with in-flight AX overrun); ControlOutcome diff evaluates state-mutating actions (.press, .type, .clickAt, .scroll, .focus, unlisted .menu) against post-action snapshot diff; allowlisted menus (.menu matching safeMenuAllowlist) and unobservable actions (.key, .select) map to .effectUnknown and do not increment consecutiveNoEffectCount; ControlEffect.timedOut added to ControlEffect in Phase 1 scope and maps to ControlSessionStepResult.timedOut |
| ControlSession | SaysoCore | Multi-step lifecycle, budget enforcement, and state transitions | Extended: ControlSessionStepResult.init(_ effect:) maps ControlEffect.timedOut to .timedOut; in record(), terminal outcomes (.actionFailed, .timedOut) immediately invoke finish(.failed) with early return before budget check, prioritizing .failed over .actionBudgetExhausted on 12th action; halts fail-closed on single .timedOut or on 2 consecutive .noEffectObserved; existing fail() call sites in SaysoNotchApp and tests updated accordingly |
| NotchHUD | SaysoNotch | Visual reticle, badge overlay, and telemetry breakdown | Extended: spatial badge rendering on nonactivating panel; confirmation banner requires interactive user event (pointer click on HUD banner or macOS Accessibility assistive tools: Voice Control, Switch Control, Dwell Click; headless background CLI/socket programmatic self-approval rejected fail-closed, as headless callers have no programmatic approval endpoint; for headless-originated steps, spoken confirmation is barred, requiring physical pointer approval to prevent audio injection e.g. via local TTS); no key capture on non-key panel, avoiding focus stealing and target app default button activation; benign review actions in voice sessions allow spoken confirm/cancel banner with 5s/15s VAD timeout under active AEC or pointer click |
| ControlAuditStore | SaysoCore | Resilient persistent recording of newest 500 entries | Extended: Phase 1 per-entry decode via JSONSerialization preserving raw JSON values (dictionaries, arrays, strings, numbers, nulls) for every entry guarantees forward and backward schema compatibility without external sidecars; single transient disk read/write error is handled best-effort in-memory with HUD warning banner; 2 consecutive failed disk writes or read errors transition store to .degradedBlocked, blocking all subsequent confirmation-gated actions and multi-step sessions fail-closed with auditStorageUnavailable until disk I/O recovers; ships ExecutionTelemetry, ControlEffect.timedOut, and ControlSessionStepResult.timedOut; retains initial corrupt backup and up to 2 timestamped backups (capped at 3 files) on whole-file JSON syntax failure (see Safety Invariants) |

## Migration Order & Schema Resilience for ControlAuditStore

| Phase | Scope | Deployment Rule & Disk Invariant |
|---|---|---|
| Current Build Vulnerability | Existing code exposure in DesktopControl.swift ControlAuditStore.append | Current builds use try? decode([ControlAuditEntry]) ?? [] and overwrite the whole journal on any decode failure or unknown enum value on the next append. Phase 1 seals this vulnerability immediately. |
| Phase 1: Storage Resilience | Ship per-entry decode in ControlAuditStore | Decodes array entries individually from disk via JSONSerialization and retains the raw JSON value (dictionary, array, string, number, null) for EVERY entry alongside decoded structs. Distinguishes missing file (clean initial state, returns []) from read error (permissions, transient I/O); single transient write/read failure logs in-memory with HUD alert; 2 consecutive failed disk writes or read errors enter .degradedBlocked state, blocking confirmation-gated actions and multi-step sessions fail-closed with auditStorageUnavailable until disk recovers. Preserving raw JSON values on disk provides complete forward and backward compatibility on rollback without sidecar files. ExecutionTelemetry, ControlEffect.timedOut, and ControlSessionStepResult.timedOut ship in Phase 1 as part of the core resilient audit model. Unknown entry schemas or unrecognised enum values (actions, effects, stepResult) on downgrade/rollback decode into raw entries and NEVER trigger backups. If and only if the entire file fails to parse as valid JSON array, writes initial corrupt backup and up to 2 timestamped backups (capped at 3 backup files total) before fallback; if writing backup file fails, aborts append fail-closed without overwriting disk journal (see Safety Invariants). Minimum downgrade floor: Phase 1 release is the compatibility floor; rollback past Phase 1 is unsupported because pre-Phase-1 builds overwrite journal with empty array on decode failure. Ships in production release before Phase 2. |
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
│ expectedApplicationTarget  │         │ stepResult ControlSessionStepResult │
│   TargetApplicationIdentity│         └────────────────────────────┘
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
| ExecutionTelemetry | stepId, planMs, captureMs, dispatchMs, verifyMs, totalMs, stepResult | Matches ControlPlanStep.id; stepResult is ControlSessionStepResult (.effectObserved, .effectUnknown, .noEffectObserved, .timedOut, .actionFailed); decoded optionally in ControlAuditEntry; raw dictionary retains unknown values on rollback |

## Latency Budget

| Phase | Happy-Path Target | Worst-Case Bound | Note |
|---|---|---|---|
| Intent Parsing | 8ms | 15ms | In-memory closed-vocabulary pattern match |
| Active Target & AX Capture | 40ms (2x 20ms p50) | 500ms | Fresh pre-dispatch AX capture #1 (20ms p50, 500ms bound matching AXCandidateCapture deadline) checks expectedFingerprint equality (TOCTOU guard) and frontmost window/PID on both auto-run and confirmed flows; post-dispatch verification capture #2 (20ms p50) captures after-state. Verification capture #2 is shared as initial state for post-assert diff calculation, avoiding double-counting in worst-case bound |
| Pre-flight Attribute Check | <1ms | <1ms | Evaluates isEnabled and !isProtected directly from fresh capture #1 candidate state in-memory (eliminates duplicate cross-process AX calls, saving 4ms p50 and 500ms worst case) |
| Semantic Action Dispatch | 4ms | 250ms | AXUIElementPerformAction (bounded by 250ms messaging timeout) |
| Menu Traversal & Leaf Check | 45ms (3x 15ms p50) | 750ms | Depth <= 3 AXMenuBar item traversal bounded by 750ms cumulative ceiling (3 levels x 250ms timeout per level). If any level times out, traversal aborts fail-closed, performs kAXCancelAction or kAXPressAction to dismiss open menus, and reports .timedOut |
| Post-assert Diff Calculation | 15ms (initial check) | 1450ms | In-memory diff calculation evaluated against verification capture #2 (not a separate AX pass); immediate check at 0ms. If unverified, up to 7 subsequent polling re-captures spaced by 125ms intervals up to attempt cap of 8 attempts (~875ms interval delays); 1200ms monotonic soft ceiling evaluated before each individual AX call bounds worst-case slow queries to at most one in-flight 250ms call overrun = 1450ms cutoff (covers initial capture #2 and all retries) |
| Total (Benign Element Fast-Path) | ~71ms | ~2.2s | Fast-path p50 target ~71ms (8ms parse + 20ms capture #1 + <1ms pre-flight + 4ms dispatch + 20ms capture #2 + 15ms diff + ~4ms telemetry); worst-case bounded at ~2.2s (15ms + 500ms + <1ms + 250ms + 1450ms), accounting for capture #2 overlapping with the post-assert diff ceiling |
| Total (Benign Menu Fast-Path) | ~116ms | ~3.0s | Fast-path p50 target ~116ms (8ms parse + 20ms capture #1 + <1ms pre-flight + 45ms menu traversal + 4ms dispatch + 20ms capture #2 + 15ms diff + ~4ms telemetry); worst-case bounded at ~3.0s (15ms + 500ms + <1ms + 750ms menu traversal + 250ms dispatch + 1450ms diff ceiling) |

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
│  │ Cancel       │   │ Cancel      │  │
│  └──────────────┘   └─────────────┘  │
└──────────────────────────────────────┘
```

| Surface | Trigger | Shape |
|---|---|---|
| Notch HUD | Action dispatch and assert | Compact target reticle, auto-expanding diff |
| Badge Overlay | Multiple candidates match title | Non-activating NSPanel window, row-bucket sorted badges |
| Menu Traversal | Spoken "menu File choose Save" or CLI "menu File > Save" | Cross-process AXMenuBar item press with confirmation banner |
| Automation CLI | sayso status / transcribe / control | JSON response with latency breakdown |

## Behavior

Fast path (Single unambiguous candidate, canAutoRun == true, semantic AX only):

```
[Voice Cmd] ──Plan (8ms)──▶ [Capture #1 (20ms)] ──Pre-flight (<1ms)──▶ [AX Dispatch (4ms)] ──Verification Capture #2 & Diff (20ms + 15ms)──▶ [Done (~71ms target)]
```

Ambiguous match path (Multiple targets sharing label; destructive badge requires confirmation):

```
[Voice Cmd] ──Resolver (ambiguous)──▶ [Badge Overlay 1..N (max 15s)] ──voice "badge 1"──▶ [Revalidation Capture: verify id & title (implies pid/windowTitle)] ──▶ [Confirmation Gate: "Cancel" requires review] ──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() Target Candidate Identity Check (id, title, isEnabled) + PreFlightCheck] ──▶ [Dispatch] ──▶ [Done]
```

Menu hierarchy path (Unlisted / destructive menu requires confirmation):

```
["menu File > Save"] ──Static Path & Confirmation Gate (unlisted/destructive)──▶ [NotchHUD Confirmation Banner] ──user confirms ("confirm action" / "cancel action")──▶ [execute() AXMenuBar Traversal + Leaf AXTitle Re-check + PreFlightCheck isEnabled] ──▶ [AXPress Leaf] ──▶ [Post-assert] ──▶ [Done]
```

Headless review lifecycle path (CLI/socket caller requires interactive human approval on Notch HUD):

```
┌─────────┐                ┌───────────┐                ┌──────────┐
│ Caller  │──send action──▶│ SaysoCore │──gate check───▶│ NotchHUD │
│ (CLI /  │                │           │                │  Banner  │
│ Socket) │◀─reviewRequired│           │                └────┬─────┘
│         │  (stepId, 15s) │           │                     │
│         │                │           │           pointer click required
│         │                │           │     (spoken approval barred for headless)
│         │                │           │                     │
│         │                ▼           ▼                     │
│         │          ┌───────────────────────┐               │
│         │          │ execute() & record()  │◀human confirm─┘
│         │          │ (verify target bound) │
│         │          └───────────┬───────────┘
│         │                      │
│         │◀─────return result───┘ (or poll stepId status)
└─────────┘
```

Multi-step chain execution semantics:

| Outcome Step Result | Mapped From | Handling in Multi-Step Chains |
|---|---|---|
| .effectObserved | ControlEffect.observed, .alreadySatisfied | State change verified (including modal sheets opened during AX timeout/cannotComplete). Reset consecutiveNoEffectCount to 0. Proceed to step k+1 |
| .effectUnknown | ControlEffect.unknown | Inherently unobservable, non-frame-mutating allowlisted menus (e.g. View > Zoom In), or unobservable key/select completion (.key, .select). Tolerated without modifying consecutiveNoEffectCount. Proceed to step k+1 |
| .noEffectObserved | ControlEffect.notObserved | State-mutating action (.press, .type, .clickAt, .scroll, .focus, unlisted .menu) completed AX dispatch successfully (<250ms) but state/fingerprint unchanged post-action. Increment consecutiveNoEffectCount. Proceed if counter < maxConsecutiveNoEffect (2); halt chain if counter == 2 |
| .timedOut | AX kAXErrorCannotComplete or messaging timeout without observed diff | Call messaging timeout or cannotComplete failure without observed state change (regardless of elapsed time). Mapped from ControlEffect.timedOut. Never retried fail-closed. ControlSession.record(.timedOut) invokes finish(.failed) to halt multi-step chain immediately, preventing subsequent steps from running against unverified state |
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
| Candidate Action Fingerprint Scope | Actions retain expectedFingerprint bound to window snapshot | Candidate actions retain expectedFingerprint bound to window snapshot at plan time, and badge pick revalidation re-binds it. Ambient window mutations during confirmation pause (sibling insertion, document title mutation, or ancestry index shift) intentionally reject fail-closed with staleTarget as a safety invariant. Known trade-off: live-updating controls (timers, chat feeds) in target window can cause staleTarget rejection, requiring user re-invocation |
| Fingerprint Bounds Exclusion | Snapshot fingerprint invariant | bounds: CGRect? on DesktopCandidate and DesktopElement are excluded from window snapshot fingerprint hash, ensuring window move or resize does not trigger false TOCTOU mismatch |
| Badge Grammar Prefix | Spoken badge selection requires prefix | "badge <N>" required; "cancel badges" dismisses overlay; bare digits and bare words ("cancel") are rejected on open mic to prevent ambiguity with candidate titles |
| Badge VAD Timeout | Overlay dismisses after 5s silence or 15s max | 5.0s timer extended on voice activity detection; hard cap of 15.0s overlay lifetime prevents mic chatter lock |
| Confirmation Tiers & Banner Safety | Single ControlPolicy.confirmationTier function | ControlPolicy.confirmationTier(step) maps actions to 3 tiers: (1) .physical: .quit, .clickAt, mutating keys (.return, .escape, .space, .undo, .redo), and candidate/menu titles matching ControlPolicy.physicalConfirmationWords (evaluated with two-pass matcher over single words/compounds: pay, purchase, transfer, send, delete, erase, trash, empty, quit, reset, revoke, deactivate, uninstall, remove, clear, discard, order, book, publish, post, share, confirm, approve, sign out, log out, signout, logout, and unclassified destructive stems; resend matches explicit entry in physicalConfirmationWords) require pointer click on Notch HUD confirmation banner with genuine user interaction (accepting macOS Accessibility assistive input: Voice Control, Switch Control, and Dwell Click; automated background CLI/socket programmatic self-approval without user presence is rejected fail-closed, no keyboard Return/Space capture on non-key panel, avoiding focus loss and target default button activation). Confirmation banner for .physical tier uses a fixed 15.0s timer with no voice activity extension. (2) .spokenOrPhysical: for interactive voice sessions, benign review actions (unlisted menus, sensitive toggles, non-English target application locales, non-ASCII candidate titles, navigation keys .tab, .up, .down, .left, .right, .type, .focus, .scroll, .open, .openFolder, .activate, .activateApplication, and words in ControlPolicy.spokenConfirmationWords: cancel, close, submit, reply, forward, archive, unsend) can be confirmed by spoken "confirm action" / "cancel action" ("approve action" / "abort action" accepted as spoken aliases) under active AEC with 5s silence / 15s max VAD timer, or by pointer click on banner; spoken confirmation words apply only if candidate title does not match any physical destructive stem or phrase. For actions originating from headless CLI/socket callers, ALL confirmation-gated actions (both .physical and .spokenOrPhysical) enforce physical pointer approval on the Notch HUD banner; spoken confirmation is barred for headless steps to block audio injection via local TTS (e.g. say "confirm action"). (3) .autoRun: returns .autoRun iff canAutoRun(step) evaluates true (requiring target application effective localization to begin with "en", ASCII-only candidate title, confidence >= 0.60, !step.requiresConfirmation, non-nil candidateTitle for .press/.select, and isDestructiveControlTitle == false for .press / .select, or allowlisted menu path without destructive segments); any step with confidence < 0.60, step.requiresConfirmation == true, non-English app localization, non-ASCII title, nil candidateTitle, or candidateTitle matching physicalConfirmationWords via two-pass matcher (including sign out, log out, signout, logout, quit, disconnect, leave) falls back to confirmation review. For actions without a target application (.open, .openFolder), localization check evaluates system Locale.preferredLanguages.first and ASCII destination path. Physical tier takes strict precedence over spoken tier on multi-word matches (e.g. "Cancel Order and Delete" is .physical). Dictation insertion into target app is suppressed while banner is active |
| Headless Action Confirmation | Headless callers require interactive human approval on Notch HUD | Automated CLI and socket calls cannot self-approve confirmation-gated actions (.physical or .spokenOrPhysical). Any gated action returns reviewRequired error JSON with stepId (15s TTL, single-use) bound strictly to the target identity: element actions (.press, .select, .focus, .clickAt, .scroll, .type, .key) bind to expectedFingerprint, processIdentifier, and windowTitle; application actions (.menu, .quit, .activate, .activateApplication) bind to bundleIdentifier (and processIdentifier when running); path actions (.open, .openFolder) bind to destination URL. The caller awaits the socket response event or polls sayso control --status <stepId>; stepId is consumed (single-use) upon human approval on the Notch HUD banner (physical pointer click on banner required for all headless gated actions; spoken confirmation barred for headless-originated steps) or upon expiration; execute() verifies bound target identity and records outcome in ControlSession.record; headless self-approval without human interaction is rejected fail-closed |
| Confirmation Banner Timeout | Banner auto-dismisses and cancels on timeout | 5.0s timer extended on voice activity detection for .spokenOrPhysical; fixed 15.0s timer for .physical; hard cap of 15.0s maximum banner lifetime. On timeout, action is automatically cancelled fail-closed, stepId expires, and banner dismisses |
| Destructive Actions | Actions in ControlPolicy.destructiveWords require review | ControlPolicy.requiresConfirmation gates execution |
| Button Press Confirmation Gating | Title classification in requiresConfirmation enables fast path | ControlPolicy.requiresConfirmation classifies .press and .select by candidate title via isDestructiveControlTitle(candidateTitle): destructive titles (evaluated via two-pass matcher over single words/compounds and adjacent word bigrams: sign out, log out, signout, logout, quit, disconnect, leave) gate behind confirmation banner while benign button titles auto-run (~71ms fast path). Target application effective localization (checked via target bundle preferred localizations or AppleLanguages override, falling back to system locale) must begin with "en" and candidate title must be ASCII-only; otherwise, execution fails safe to requiring confirmation banner. A press with nil candidateTitle fails closed and requires confirmation. DesktopAction.clickAt, .key, and .quit remain blanket confirmation-gated. DesktopAction.isDestructive retains its inherent destructive flag. UI risk label in Notch HUD derives strictly from ControlPolicy.requiresConfirmation (displays "Risk: Benign" for auto-running button presses) |
| Pointer Click Safety | Raw CGEvent mouse clicks always require review | Kept: DesktopAction.isDestructive returns true for .clickAt |
| Keystroke Safety | Keyboard shortcuts always require review | Kept: DesktopAction.isDestructive returns true for .key |
| Fail-Closed Menu Policy | Explicit .menu case; allowlist check must be non-destructive | path.count >= 2 && path.count <= 3 (requiring parent and child leaf, rejecting single segment e.g. ["File"] or depth > 3 fail-closed with invalidMenuPath before confirmation); safeMenuAllowlist.contains(path) && !path.contains(where: { isDestructiveControlTitle($0) }) |
| Menu Destructive Classification | Explicit .menu case in DesktopAction.isDestructive | In DesktopAction.isDestructive, .menu(path: _, expectedApplicationTarget: _) evaluates path.contains(where: { isDestructiveControlTitle($0) }) for intrinsic reporting; ControlPolicy.requiresConfirmation evaluates !safeMenuAllowlist.contains(path) || path.contains(where: { isDestructiveControlTitle($0) }) for execution gating, eliminating default: false fallbacks. Any path segment matching physicalConfirmationWords enforces .physical tier |
| Menu Exhaustive Switches | Enumerate all DesktopAction cases via compiler | Eliminate default: fallbacks across all action switches, explicitly enumerating .menu in isDestructive, requiresConfirmation, requiresActiveTarget, validatedNextTargetBundleIdentifier, and execute |
| Menu Application Target Guard | Menu actions bound to target application identity | DesktopAction.menu binds to target application identity (bundleIdentifier and processIdentifier) rather than full window AX element tree, preventing live-updating window controls (timers, chat feeds) from causing false staleTarget rejections. Traversal proceeds at AXApplication level even if no window is currently focused |
| Active Menu Target | Menus only target frontmost application | ControlPolicy.requiresActiveTarget returns true for .menu |
| Menu Traversal Execution Timing | Menu traversal executes inside execute() after confirmation | Confirmation gate statically inspects menu path against allowlist and destructive stems without opening menus. AXMenuBar traversal (depth ≤3) runs inside execute() post-approval, preventing open menus from shifting focusedRole/focusedValue or timing out during user confirmation. If traversal times out, performs kAXCancelAction, or verifies AXExpanded/AXSelected before kAXPressAction on opened parent menu item to dismiss menus without reopening (never synthesizes raw CGEvent Escape keys without confirmation); if dismissal fails, shows non-fatal HUD alert "Menu Left Open" and logs menuDismissalFailed to audit |
| Menu Hierarchy Traversal Verification | Intermediate segments verified by exact title at each depth | AXMenuBar traversal navigates hierarchy step-by-step, verifying exact title match at each parent depth level (depth ≤3). Inside execute() post-traversal, re-run safeMenuAllowlist and isDestructiveControlTitle against the actual resolved AXMenuItem title attribute (canonicalizing ellipsis … vs ...). If resolved leaf title differs from confirmed leaf, or if resolved leaf title requires a higher confirmation tier than approved (e.g. approved on spoken tier but leaf requires physical tier), abort fail-closed with menuLeafMismatch |
| Action Failure Session Halt | Fail-closed session halt on structural error | ControlSession.record(.actionFailed) and record(.timedOut) immediately invoke finish(.failed) with early return before evaluating actionCount against actionBudget. If the 12th action fails or times out, .failed priority wins over .actionBudgetExhausted. Multi-step chain halts immediately fail-closed without caller convention |
| AX Diff-Based Outcome Classification | Classify by post-action diff; timeouts halt session fail-closed | After any kAXErrorCannotComplete or messaging timeout, post-action diff observation runs unconditionally. If attribute or window frame diff is observed (e.g. modal sheet opened), outcome is classified as .effectObserved. If no diff is observed after observation ceiling: ANY dispatch experiencing kAXErrorCannotComplete or messaging timeout (regardless of elapsed time) maps to .timedOut, is non-retryable fail-closed, and halts session immediately via record(.timedOut) -> finish(.failed). State-mutating actions (.press, .type, .clickAt, .scroll, .focus, unlisted .menu) completing AX API calls successfully (<250ms) without observed diff map to .noEffectObserved (2 consecutive halt session fail-closed). Unobservable or selection actions (.key, .select) and allowlisted non-frame-mutating menus (.menu matching safeMenuAllowlist such as View > Zoom In returning AX success) map to .effectUnknown and do not increment no-effect counter |
| Key/Select Chain Tolerance | Tolerates unverified keystrokes and selection actions | .effectUnknown outcomes (.key, .select) do not alter consecutiveNoEffectCount, preserving multi-key/select chains (e.g. repeated tab navigation); only .noEffectObserved increments toward 2-step halt (any .timedOut halts immediately fail-closed) |
| Bounded AX Timeout | Cross-process AX queries cannot hang UI | AXUIElementSetMessagingTimeout 0.25s per call scoped strictly to frontmost target application element and traversed elements during desktop control (leaving system-wide AX and TextTools dictation unaffected); 500ms soft clock check |
| Resilient Audit Storage | Journal schema changes and read errors must never wipe history | ControlAuditStore decodes entries individually, preserving raw JSON values (dictionaries, arrays, strings, numbers, nulls) for every entry. Retaining raw JSON entries on disk provides complete forward and backward schema compatibility without requiring a separate sidecar file. Distinguishes missing file from read error (transient I/O, permissions); single transient write/read failure is tolerated best-effort in-memory with non-fatal HUD warning banner without re-executing; 2 consecutive failed disk writes or read errors transition store to .degradedBlocked, blocking all subsequent confirmation-gated actions and multi-step sessions fail-closed with auditStorageUnavailable until disk I/O recovers, displaying a persistent HUD audit error banner. Phase 1 per-entry decode deploys before Phase 2 (.menu). Raw entries count toward 500-entry cap and are preserved on re-save. Unrecognised entries (actions, effects, stepResult) decode as raw entries without backups; on whole-file JSON syntax failure, writes permanent initial backup control-audit.json.corrupt.initial and rotates up to 2 timestamped backups control-audit.json.corrupt-<timestamp> (capped at 3 backup files total) before fallback; if backup write fails, aborts append fail-closed without overwriting journal |
| Observation Polling | Observation attempt cap is primary with 1200ms backstop | Polling starts with immediate check at 0ms, followed by attempts spaced by 125ms intervals up to attempt cap of 8 attempts (~875ms interval delays). Monotonic soft ceiling of 1200ms evaluated before each individual AX call bounds worst-case slow cross-process AX responses to at most one in-flight 250ms AX call overrun (~1450ms cutoff) |
| Chain No-Effect Limit | Consecutive no-effect actions capped at 2 | Tolerates 1 no-effect step; halts on 2 consecutive .noEffectObserved (or 1 .timedOut) |

Safe menu allowlist (exact full path match, standard AppKit):
`[["View", "Zoom In"], ["View", "Zoom Out"], ["View", "Actual Size"], ["Window", "Zoom"]]`
Rule: Destructive check always wins. Even if in allowlist, any title matching destructive stems requires confirmation. Non-English menu paths and UI locales fail-safe to requiring confirmation banner.

## Errors

| Failure mode | User-visible surface | Recovery |
|---|---|---|
| AX API Timeout | Notch HUD warning banner | Map to .timedOut; non-retryable; ControlSession.record(.timedOut) halts multi-step session immediately fail-closed via finish(.failed) |
| Stale Target on Badge | Notch HUD alert banner | Abort dispatch when candidateID or title mismatch (ID equality ensures pid and windowTitle match); refresh list |
| Window Title Mutation on Badge | Notch HUD alert banner | Window title mutation during 15s badge overlay (e.g. document Edited marker or tab change) rejects candidate fail-closed via candidateID mismatch; refreshes candidates |
| Sibling Insertion on Badge | Notch HUD alert banner | Structural ancestry index shift rejects candidate fail-closed; dismiss overlay and refresh candidates |
| Menu Leaf Mismatch | Notch HUD alert banner | Resolved AXMenuItem title differs from confirmed leaf or matches destructive stem; aborts dispatch fail-closed |
| Badge Overlay Timeout | Overlay dismisses silently | Auto-dismiss after 5s silence or 15s hard cap, record timeout in audit |
| Confirmation Banner Timeout | Notch HUD banner dismisses | Auto-cancels action fail-closed after fixed 15s timer for .physical, or 5s silence / 15s hard cap for .spokenOrPhysical; records cancellation in audit |
| Post-assert Timeout | Notch HUD failed assertion | Report unobserved state after observation deadline; manual retry means initiating a fresh command (new capture, new planning, fresh confirmation if destructive), never automatic re-execution of a non-idempotent timed-out dispatch |
| Invalid Menu Path | Notch HUD path error | Parse time rejection of path length < 2 or > 3 with invalidMenuPath before confirmation |
| Menu Item Not Found | Notch HUD menu error | Inside execute() post-confirmation, if child leaf is missing under valid parent, aborts fail-closed, dismisses menu, and lists available items under parent menu |

## Testing strategy

| Layer | Scope | Gate |
|---|---|---|
| Unit | Menu hierarchy step parsing | "menu File choose Save then click Confirm" splits on " choose " token delimiters (e.g. "menu Edit choose New Item" -> "Edit" / "New Item"; "menu Insert choose Item List choose Sort" -> "Insert" / "Item List" / "Sort") without ambiguity with child titles containing "item" or "open"; splits on " then " (case-insensitive) into discrete command steps. Empty path [] and depth > 3 reject fail-closed with invalidMenuPath before confirmation. Spoken grammar uses "menu <Parent> choose <Child>"; CLI and automation socket use "menu File > Save"; two-pass title matcher detects multi-word destructive phrases ("Sign Out", "Log Out") alongside single words |
| Unit | Desktop candidate filtering and protection | All protected fields rejected |
| Unit | Menu allowlist explicit classification | ["View","Zoom In"] auto-runs; ["File","Export"] triggers confirmation; any destructive item in path (e.g. ["Account", "Sign Out", "Now"]) triggers .physical confirmation |
| Unit | Menu application target verification | Application switch before menu dispatch aborts execution; live-updating window content within target app does not invalidate menu action; menu traversal verifies on target app with no open windows |
| Unit | Menu leaf title mismatch aborts execution | Resolved AXMenuItem title differing from confirmed leaf or requiring higher confirmation tier than approved aborts dispatch fail-closed |
| Unit | Destructive badge confirmation gate | Picking destructive badge "Cancel" prompts confirmation banner |
| Unit | Button press nil title requires confirmation | ControlPolicy.requiresConfirmation returns true fail-closed when ControlPlanStep.candidateTitle is nil |
| Unit | Candidate action fingerprint scope | Candidate actions retain expectedFingerprint bound to window snapshot at plan time; ambient window mutations or ancestry index shifts reject fail-closed with staleTarget |
| Unit | Headless action approval | CLI and socket control calls return reviewRequired error JSON for gated steps; headless self-approval is barred fail-closed; execution requires interactive human pointer confirmation on Notch HUD; spoken confirmation barred for headless-originated steps to block local TTS injection; stepId binds strictly to target identity (element fingerprint, bundle ID, or URL) including .key; outcome delivers over socket or status poll |
| Unit | Immediate chain failure on .actionFailed | ControlSession.record(.actionFailed) directly invokes finish(.failed), halting multi-step chain immediately without caller convention |
| Unit | Session terminal outcome budget priority | In ControlSession.record(), terminal outcomes (.actionFailed, .timedOut) on 12th action return .failed over .actionBudgetExhausted |
| Unit | Low confidence press requires confirmation | confirmationTier returns .spokenOrPhysical for benign button press with confidence < 0.60 or requiresConfirmation == true, preventing unauthorized auto-run |
| Unit | Non-English locale press confirmation | Non-English target application effective localization (or non-ASCII candidate title) forces requiresConfirmation == true for all button presses and actions, preventing localized destructive commands from auto-running |
| Unit | ControlSessionStepResult effect mapping | ControlSessionStepResult.init(effect) exhaustively maps ControlEffect.timedOut to .timedOut |
| Unit | Badge revalidation and drift check | Stale candidate ID or title mismatch aborts dispatch; PID/windowTitle mismatch prevents re-binding |
| Unit | Pre-flight timing verification | PreFlightCheck evaluates isEnabled and !isProtected directly from fresh capture #1 candidate state in-memory inside execute() after approval |
| Unit | Badge dictation suppression | Target application dictation insertion suppressed during badge overlay |
| Unit | Confirmation banner safety | Pointer click on Notch HUD confirmation banner or native macOS Accessibility assistive input (Voice Control, Switch Control, Dwell Click) required for all .physical actions (.quit, .clickAt, mutating keys, physical destructive words); automated background CLI/socket programmatic self-approval rejected fail-closed; spoken "confirm action" / "cancel action" ("approve action" / "abort action" accepted as spoken aliases) accepted under active AEC for benign review voice actions; spoken confirmation barred for headless callers; bare words rejected |
| Unit | Confirmation banner timeout | .physical tier auto-cancels fail-closed on fixed 15s timer; .spokenOrPhysical auto-cancels on 5s silence / 15s max VAD timer |
| Unit | Menu traversal timeout dismisses menu via AX | Menu traversal timeout triggers kAXCancelAction, or checks AXExpanded/AXSelected before kAXPressAction on opened parent menu; zero CGEvent Escape keys synthesized |
| Unit | Multi-key effectUnknown chain tolerance | Navigation keys (.tab, .up, .down, .left, .right) map to .spokenOrPhysical, permitting hands-free spoken confirmation without forcing mouse clicks; 3 consecutive navigation .key actions (.effectUnknown) succeed without triggering no-effect halt; 2 consecutive .noEffectObserved or 1 .timedOut halt chain fail-closed |
| Unit | Post-action observation runs after AX timeout | Post-action diff observation runs after AX timeout or cannotComplete; modal sheet appearance verifies as .effectObserved; absence of diff verifies as .timedOut (regardless of elapsed time) and prevents action retry |
| Unit | Single AX timeout halts session | ControlSession.record(.timedOut) invokes finish(.failed) to halt multi-step chain fail-closed immediately without running subsequent steps |
| Unit | Spatial row-bucket badge ordering | Badges 1..N order by anchored row (Y ±4pt threshold), then X |
| Unit | Resilient audit journal decoding | Corrupt or unknown action entries preserved without wiping 500-entry journal; raw JSON values (dictionaries, arrays, primitives) retained without external sidecar files; transient read errors abort append without overwrite; initial corrupt backup control-audit.json.corrupt.initial and up to 2 timestamped backups (capped at 3 files) written on whole-file JSON syntax corruption |
| Unit | Audit persistence failure blocking | Single transient write/read failure in ControlAuditStore.append logs in-memory with HUD warning; 2 consecutive failed disk writes or read errors enter .degradedBlocked state, blocking confirmation-gated actions fail-closed with auditStorageUnavailable until disk recovers |
| Integration | Badge overlay coordinate mapping | AX top-left to Cocoa primary screen bottom-left conversion across screens |
| Integration | AXMenuBar hierarchy traversal | Native macOS menu bar resolution with lazy-menu fallback (depth ≤3) |
| Benchmark | Fast-path execution latency | Target composite pipeline latency p50 < 85ms, p95 < 140ms directly measured on standard AppKit target (intent parse + active target capture + pre-flight + semantic dispatch + immediate verification). Component capture p50 < 20ms, p95 < 35ms on Apple Silicon M-series |
| Benchmark | Spoken confirmation acoustic rejection | Measure spoken confirmation trigger accuracy under active system AEC against background speaker audio and media playback containing spoken confirmation phrase; acceptance gate: false accepts = 0 across 300 background playback trials (bounds false-accept rate <=1% at 95% confidence for benign review tier) |
| E2E | Computer-use automated validation | Tab navigation, state inspection, and audio transcribe round-trip |

## Out of scope

- OCR-based vision control for non-accessibility games and full-screen streaming.
- Cross-machine network desktop control.
- Hardware-level mouse emulation outside CGEvent and AX APIs.
