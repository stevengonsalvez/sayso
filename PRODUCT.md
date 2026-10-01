# Sayso macOS Product Direction

## Promise

Sayso is a native voice workspace for immediate dictation and safe desktop control. It should feel quiet, precise, and alive. Users must always know which mode is active, what Sayso heard, and whether an action is safe to run.

## Product Register

| Surface | Primary job | Required state | Primary action |
|---|---|---|---|
| Docked notch | Ambient voice status | Dictation, Control, idle, listening, processing, blocked | Double Fn or triple Fn |
| Floating HUD | Movable equivalent | Same state and copy as docked notch | Same gestures and controls |
| Dictation | Stream speech into focused editor | Live partial transcript, final delivery, fallback | Double Fn starts or stops |
| Control | Ground and run safe desktop action | Target, planning, review, result | Triple Fn starts or stops |
| Control Try now | Teach control safely | Ready, listening, planning, complete, blocked | Calculator or Safari example |
| Overflow | Secondary controls | Presentation, settings, permissions, quit | Accessible menu |

## Interaction Contract

- Double Fn starts or stops Dictation.
- Triple Fn starts or stops Control.
- Double-tap waits one bounded multi-tap window so triple-tap remains possible.
- Live partial text appears in the verified focused editable target, then final text replaces it without duplication.
- Protected fields, stale processes, changed focus, changed selection, and changed target identity stop insertion.
- Control always shows grounding and execution status. Misleading generic dictation labels never appear in Control mode.
- Try now uses a visible, reversible Calculator or Safari action through the normal grounded control path.

## Product Principles

- Product register over icon wall. One primary mode and action at a time.
- Status before decoration. Transcript or control status owns visual hierarchy.
- Local first. Network providers remain explicit opt-in with credentials stored in Keychain.
- Safety is visible. Permission, protected-target, review, and failure states name the blocker.
- Native behavior. Use SwiftUI, AppKit, standard menus, buttons, focus, and System Settings permission routes.

## Acceptance

- Both notch presentations show current mode, status, and accurate gesture hint without clipping.
- VoiceOver names every control and announces state changes without relying on color.
- Keyboard navigation and visible focus reach primary action, mode selector, Try now, and overflow.
- Reduced Motion removes nonessential movement while preserving state changes.
- Normal and increased-contrast appearances maintain WCAG AA text contrast.
- Fresh physical-microphone proof covers two partial states, TextEdit, one non-allowlisted editor, final text, and safe Jev control provenance.

## Exclusions

Android changes, notarization, App Store distribution, release publishing, new speech providers, destructive controls, and unrelated settings redesign are outside this revamp.
