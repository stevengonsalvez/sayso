# Research: Sayso macOS staged review

**Date**: 2026-09-22 15:59:08
**Repository**: sayso-notch
**Branch**: stevengonsalvez/sayso-notch
**Commit**: 28b6c32
**Research Type**: Comprehensive

## Research Question

Review Sayso onboarding, dictation, notch, and desktop control against JustSpeakToIt and JEV-use. Fix clear defects as they are found.

## Executive Summary

Onboarding had a real permission-recovery defect: Input Monitoring did nothing and no exact Settings recovery was available. Desktop Control had a more serious safety defect: it could capture the Sayso window after Sayso became focused. Both defects are now addressed in code.

JustSpeakToIt is a strong source for macOS dictation lifecycle, permission recovery, and automation boundaries. JEV-use is a broader desktop agent, not a safe drop-in for Sayso's explicit, grounded command model.

## Key Findings

- Input Monitoring must use Core Graphics preflight/request and Settings recovery.
- Accessibility and Input Monitoring cannot be granted programmatically.
- Control execution must bind capture, verification, and action to one external application.
- Destructive desktop actions require explicit review.

## Prior Learnings

| Learning | Key Insight | Confidence |
|---|---|---|
| macOS privacy controls | Accessibility and screen permissions require human grant in Settings | high |

## Detailed Findings

### Onboarding and permissions

- Current fix: `macos/Sources/SaysoCore/Permissions.swift` maps microphone, speech, Accessibility, and Input Monitoring to their exact Privacy pane URLs.
- Current fix: Input Monitoring now calls `CGPreflightListenEventAccess()` and `CGRequestListenEventAccess()`.
- Current fix: denied native permissions open recovery Settings, and state refreshes after app activation.
- Physical proof remains required because macOS TCC controls the grant.

### Dictation and notch

- JustSpeakToIt provides robust reference patterns for capture ownership, hotkeys, HUD phases, output fallback, local automation, and permission recovery.
- Sayso directly depends on upstream `SpeakCore`, `SpeakAutomationKit`, and `SpeakHotKeys` through `macos/Package.swift`.
- Upstream has broad providers and platform surfaces. Copy narrow macOS primitives, not iOS, Watch, sync, billing, or distribution systems.

### Desktop control

- Current fix: `macos/Sources/SaysoCore/DesktopControl.swift` preserves process identity during capture, execution, and verification.
- Current fix: risky actions require review before execution.
- Current fix: `macos/Sources/SaysoNotch/SaysoNotchApp.swift` retains the last external application and targets it from Control workspace.
- JEV-use includes deeper traversal, menus, key sequences, app and folder operations, and multi-step planning. Those require a dedicated safe-command design, not blind reuse.

## External Research

- [JustSpeakToIt repository](https://github.com/crmitchelmore/justspeaktoit)
- [JustSpeakToIt permission guide](https://github.com/crmitchelmore/justspeaktoit/blob/0f0e92028a249e17b58349da3ee8033c73ffd219/Docs/mac-permission-guides.md)
- [JustSpeakToIt automation boundary](https://github.com/crmitchelmore/justspeaktoit/blob/0f0e92028a249e17b58349da3ee8033c73ffd219/Docs/automation.md)
- [JEV-use repository](https://github.com/savka777/jev-use)

## Recommendations

1. Physically grant microphone, speech, Accessibility, and Input Monitoring from the packaged app.
2. Add a bounded pending-action review UI for every destructive control command.
3. Expand JEV parity only through explicit, grounded command families with tests.

## Open Questions

- Real TCC grant and deep-link behavior needs interactive device proof.
- Direct external-app AX execution needs an Accessibility-enabled test run.
