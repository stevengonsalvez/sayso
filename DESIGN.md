---
product: Sayso macOS
personality: quiet, precise, alive
platform: macOS 14+
colors:
  canvas: "#0C1322"
  surface: "#151F33"
  elevated: "#1E2A44"
  outline: "#334668"
  text: "#FFFFFF"
  muted: "#94A3B8"
  action: "#2563EB"
  attention: "#F4B942"
  danger: "#EF4444"
shape:
  compact: 8
  card: 12
  workspace: 16
spacing:
  compact: 6
  control: 10
  section: 16
---

# Design System: Sayso macOS

## Visual Theme

Restrained native utility. Dark navy surfaces frame clear white text, one cobalt primary action, and amber only for attention or Control state. The notch should feel present without looking luminous, ornamental, or game-like.

## Color Roles

- Deep Navy Canvas (#0C1322): notch and settings background.
- Navy Surface (#151F33): grouped content and compact status regions.
- Navy Elevated (#1E2A44): selected mode and raised controls.
- Structural Outline (#334668): quiet borders and visible keyboard focus support.
- Clear White (#FFFFFF): primary text and current transcript.
- Slate Muted (#94A3B8): secondary labels only, never critical state alone.
- Cobalt Action (#2563EB): Dictation and primary confirmation.
- Golden Attention (#F4B942): Control identity, review, and permission attention.
- Crimson Danger (#EF4444): blocked or destructive state only.

All text and interactive states must meet WCAG AA. Increased Contrast strengthens outlines and state separation without changing meaning.

## Typography

- Use system San Francisco through SwiftUI semantic fonts.
- Current mode and status use semibold hierarchy.
- Live transcript uses regular body text with two-line truncation in compact state.
- Gesture hints use compact monospaced text only where key rhythm benefits.
- Avoid all-caps labels except established macOS control conventions.

## Layout

```text
┌──────────────────────────────────────────────────────────┐
│ Mode        Live transcript or control status      More │
│ Double Fn / Triple Fn                         Main action │
└──────────────────────────────────────────────────────────┘
```

- Lead with mode, status, and one primary action.
- Put secondary destinations in one labeled overflow menu.
- Docked and floating presentations share content hierarchy and state copy.
- Compact layout must survive long status copy without obscuring stop control.
- Use 6, 10, and 16 point spacing rhythm from compact detail to sections.

## Components

- Mode selector: native segmented or menu control, text plus optional symbol.
- Primary action: labeled native button, cobalt for Dictation, amber for Control.
- Status region: transcript in Dictation, controlStatus in Control.
- Gesture hint: `Double Fn Dictation` or `Triple Fn Control`, always current.
- Try now: one compact Control card with example, target, and visible outcome.
- Overflow: native Menu with VoiceOver label `More Sayso controls`.
- Focus: standard keyboard focus ring remains visible on every interactive item.

## Motion

- State changes may use a short opacity or scale transition.
- Respect Reduce Motion by replacing movement with immediate opacity changes.
- Never pulse, shimmer, spin continuously, or use glow as status.
- Fn gestures use a 400 ms multi-tap decision window. Double-Fn therefore adds 400 ms before Dictation starts so triple-Fn can resolve without duplicate actions.
- Completed gestures use a 120 ms cooldown. A fourth rapid tap is ignored instead of starting an accidental second action.

## Do

- Reuse `SaysoPalette` and platform components.
- Expose mode and state through text, symbol, and accessibility value.
- Keep labels truthful during listening, processing, review, and failure.
- Let status content carry visual life through real updates.

## Do Not

- No icon wall, gamer glow, decorative glass, or ornamental gradients.
- No stale shortcut copy or `Start dictation` label in Control mode.
- No color-only state, hidden focus, clipped transcript, or unlabeled icon button.
- No bespoke control where a native macOS control already fits.

## Current Drift

- Existing notch header has seven equal-weight icon buttons.
- Existing Control mode hides `controlStatus` and retains dictation action copy.
- Existing active-glow and glass styling are not valid for the revamped notch.
- Drift remains a bug until screenshot and accessibility proof pass.
