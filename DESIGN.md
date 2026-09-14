# Sayso Design System & Interface Specification

## 1. Vision and Physical Scene

Sayso is an on-device local voice dictation tool built for high-velocity thinkers, writers, and developers who require instant, private, and precise speech-to-text input across all apps.

### Physical Scene
- **User Context**: Walking outdoors in direct sunlight, standing in noisy rooms, or working late at night in low-light desk setups.
- **Cognitive Demands**: Zero hesitation, instant visual feedback, tactile and audio responsiveness, surgical legibility.
- **Core Aesthetic**: Electric Studio. Precision audio hardware meets Linear-grade software craft. Purposeful, high-contrast, uncluttered, and uncompromisingly fast.

---

## 2. Color Strategy & Palette

Sayso adopts a **Committed Color Strategy**: a vivid Sonic Cobalt primary paired with Energetic Amber and Vivid Crimson signals, framed by deep obsidian slate and crisp pure white surfaces.

Sayso explicitly rejects the saturated AI defaults of 2026: no warm-cream, parchment, or beige body backgrounds; no muddy mid-tones; no fuzzy decorative drop shadows.

```
┌─────────────────────────────────────────────────────────────┐
│                       COLOR ARCHITECTURE                    │
│                                                             │
│  [ Sonic Cobalt ]      [ Energetic Amber ]  [ Crimson Pulse]│
│  Primary Brand         Secondary/Accent     Recording Signal│
│  oklch(0.55 0.22 255)  oklch(0.72 0.17 65)  oklch(0.58 0.22 25)
│                                                             │
│  [ Pure White / Slate ]                     [ Deep Obsidian]│
│  Light Surface & BG                         Dark Surface & BG
└─────────────────────────────────────────────────────────────┘
```

### Color Tokens (OKLCH & Hex Mappings)

| Token Name | Role | Light Mode Hex | Dark Mode Hex | OKLCH (Light) | OKLCH (Dark) |
|---|---|---|---|---|---|
| `md_theme_primary` | Core brand identity & key CTAs | `#2563EB` | `#60A5FA` | `oklch(0.55 0.22 255)` | `oklch(0.72 0.17 255)` |
| `md_theme_onPrimary` | Text & icons on primary fill | `#FFFFFF` | `#0B0F17` | `oklch(1.00 0.00 0)` | `oklch(0.12 0.02 255)` |
| `md_theme_primaryContainer` | Tonal buttons & active badge bg | `#DBEAFE` | `#1E3A8A` | `oklch(0.92 0.04 255)` | `oklch(0.32 0.11 255)` |
| `md_theme_onPrimaryContainer`| Text on tonal primary container | `#1E40AF` | `#DBEAFE` | `oklch(0.40 0.16 255)` | `oklch(0.92 0.04 255)` |
| `md_theme_secondary` | Progress & attention highlights | `#F59E0B` | `#FBBF24` | `oklch(0.72 0.17 65)` | `oklch(0.80 0.16 75)` |
| `md_theme_onSecondary` | Text on secondary fill | `#FFFFFF` | `#451A03` | `oklch(1.00 0.00 0)` | `oklch(0.25 0.08 65)` |
| `md_theme_secondaryContainer`| Subdued highlight container | `#FEF3C7` | `#78350F` | `oklch(0.95 0.05 75)` | `oklch(0.35 0.10 65)` |
| `md_theme_onSecondaryContainer`| Text on subdued container | `#92400E` | `#FEF3C7` | `oklch(0.42 0.14 65)` | `oklch(0.95 0.05 75)` |
| `md_theme_error` | Recording state, errors, alerts | `#EF4444` | `#F87171` | `oklch(0.58 0.22 25)` | `oklch(0.68 0.20 25)` |
| `md_theme_background` | App screen background | `#F8FAFC` | `#0B0F17` | `oklch(0.985 0.004 255)` | `oklch(0.12 0.015 255)` |
| `md_theme_surface` | Cards, sheets, dialog surfaces | `#FFFFFF` | `#131B2A` | `oklch(1.00 0.00 0)` | `oklch(0.17 0.02 255)` |
| `md_theme_surfaceVariant` | List item backgrounds, dividers | `#F1F5F9` | `#1E293B` | `oklch(0.95 0.01 255)` | `oklch(0.24 0.025 255)` |
| `md_theme_onSurface` | Primary typography & high-emphasis | `#0F172A` | `#F8FAFC` | `oklch(0.18 0.02 255)` | `oklch(0.97 0.005 255)` |
| `md_theme_onSurfaceVariant` | Subtitles, helper text, chevrons | `#475569` | `#94A3B8` | `oklch(0.45 0.02 255)` | `oklch(0.70 0.015 255)` |
| `md_theme_outline` | Fine borders and card strokes | `#CBD5E1` | `#334155` | `oklch(0.85 0.015 255)` | `oklch(0.32 0.02 255)` |

### Contrast and Helmholtz-Kohlrausch Compliance
- **Body Text**: Exceeds WCAG AAA contrast standard (14.5:1 in light mode, 15.2:1 in dark mode).
- **Secondary Text**: Exceeds WCAG AA contrast standard (5.5:1 in light mode, 6.2:1 in dark mode).
- **Text on Color Fills**: All filled buttons and active badges use pure white text (`#FFFFFF`), avoiding perceptual muddiness on saturated mid-luminance colors.
- **No Wallpaper Dilution**: Sayso locks its theme across Android 12+ instead of deferring to dynamic wallpaper tinting, preserving brand fidelity and readability.

---

## 3. Typography Scale

Sayso relies on Android system fonts (Roboto / Google Sans) for instant rendering speed, native keyboard integration, and zero bundle footprint.

| Role | Size | Weight | Tracking | Line Height | Usage |
|---|---|---|---|---|---|
| `displayLarge` | 36sp | Bold | -0.02em | 44sp | Key speech metrics (WPM, words) |
| `titleLarge` | 22sp | SemiBold | -0.01em | 28sp | Screen headers, top app bar |
| `titleMedium` | 16sp | SemiBold | 0.00em | 24sp | Card titles, section headers |
| `titleSmall` | 14sp | Medium | +0.01em | 20sp | Sub-section labels, status headings |
| `bodyLarge` | 16sp | Regular | 0.00em | 24sp | Primary instructional text |
| `bodyMedium` | 14sp | Regular | 0.00em | 20sp | Setting descriptions, card body |
| `labelLarge` | 14sp | SemiBold | +0.01em | 20sp | Action buttons, CTA labels |
| `labelMedium` | 12sp | Medium | +0.02em | 16sp | Metric subtitles, status chips |
| `labelSmall` | 11sp | Medium | +0.03em | 14sp | Fine timestamps, secondary tags |

### Typographic Rules
1. **Letter-spacing ceiling**: Display heading tracking never drops below -0.03em. Tight letter-touching is prohibited.
2. **Line Length**: Body copy lines capped at 65 characters for fast readability.
3. **No Decorative Gradient Text**: All typography uses single, crisp solid tokens.

---

## 4. Spacing, Layout & Elevation

Sayso uses a strict 4dp spatial grid for alignment, rhythm, and layout balance.

### Spacing Scale
- `4dp`: Micro-spacing between icon and label, chip padding.
- `8dp`: Spacing between stacked text lines, button content padding.
- `12dp`: Medium gap between related controls and metric tiles.
- `16dp`: Standard card internal padding, screen edge horizontal gutters.
- `24dp`: Section separator spacing, bottom scroll padding.
- `32dp`: Large visual break between distinct operational functional areas.

### Corner Radius System
- `8dp`: Status tags, metric value surfaces, micro-chips.
- `10dp` to `12dp`: Action buttons, input containers, text fields.
- `16dp`: Standard cards, dashboard widgets, elevated sheets.
- `999dp` (Pill): Floating overlay bubble, interactive toggles.
- **Rule**: Cards are capped at 16dp. Over-rounding (24dp+ on cards) is prohibited.

### Elevation & Depth
- **Elevated Cards**: 2dp to 4dp tonal surface elevation with subtle border stroke (`1dp` at `outlineVariant`). Avoid heavy, blurred drop shadows.
- **Active State Highlights**: Layered background tints instead of colored side-stripe borders.

---

## 5. Overlay Bubble Design & Micro-Interactions

The floating overlay bubble is the primary touchpoint during daily dictation. It operates via `TYPE_ACCESSIBILITY_OVERLAY`.

```
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│    IDLE     │  ──▶  │  RECORDING  │  ──▶  │    BUSY     │
│ Sonic Blue  │       │ Vivid Red   │       │ Warm Amber  │
│ Soft Pulse  │       │ Heartbeat   │       │ Spinner     │
└─────────────┘       └─────────────┘       └─────────────┘
```

### Bubble State Specifications

1. **Idle State**:
   - Base Color: `#00B0FF` (Electric Cyan) / `#2563EB` (Sonic Cobalt).
   - Outer Glow: 20% opacity matching ring, radius 60dp.
   - Inner Bubble: 52dp diameter, 2.5dp stroke at `#E0F7FA`.
   - Icon: White microphone symbol (`ic_bubble_idle`).
   - Settle Behavior: Snaps smoothly to nearest screen edge with 8dp margin.

2. **Recording State**:
   - Base Color: `#EF4444` / `#FF1744` (Vivid Crimson).
   - Dynamic Animation: 500ms pulsing outer ring with 45% alpha glow.
   - Haptic Feedback: Short tactile click upon activation.
   - Dual-Mode Input:
     - Push-and-hold (press to dictate, release to transcribe).
     - Tap-to-toggle (tap once to record hands-free, tap again to finish).

3. **Busy State (Transcribing & Polishing)**:
   - Base Color: `#F59E0B` / `#FF9100` (Energetic Amber).
   - Animation: Indeterminate circular spinner centered within bubble.
   - Duration: Immediate visual handover upon audio completion.

4. **Result Feedback Pill**:
   - Background: Translucent Slate (`0xEE1E293B`) with 10dp rounded corners.
   - Text: High-contrast crisp white typography (`12sp`).
   - Display Duration: 2,000ms auto-dismissal.

---

## 6. Dashboard & Insights Architecture

The home screen functions as an active speech dashboard rather than a passive checklist.

### Screen Composition
1. **Top Bar**:
   - Title: `Dashboard`.
   - Actions: Clean back navigation when descending into sub-screens.
2. **Speech Insights Top Widget**:
   - Position: Primary card at the top of the scrollable column.
   - Header: Luminous `Insights` icon + `Speech Insights` title + session count badge.
   - Live Metric Tiles:
     - `Words Spoken`: Total accumulated dictation words.
     - `Average Pace`: Measured in words per minute (WPM).
     - `Filler Rate`: Number of filler words per 1,000 spoken words.
   - Empty State: Clean guidance text prompting first recording when session count is zero.
   - Call to Action: Full-width tonal button (`See more insights`) with trailing chevron navigation.
3. **Operational Readiness**:
   - Clear setup status card (Microphone permission, Accessibility service).
   - One-tap resolution for missing system capabilities.
4. **Quick Controls**:
   - Wake word ("Hey Sayso") toggle.
   - Floating bubble visibility toggle.
   - Model selection summaries (STT and Cleanup).

---

## 7. Anti-Patterns & Absolute Bans

The following patterns are strictly banned in Sayso:

1. **No Em-Dashes**: Never use em-dashes anywhere in UI copy, docs, or code comments. Use commas, colons, or parentheses.
2. **No Cream / Beige / Saturated AI Neutral Backgrounds**: Never use `#FFFDF5`, `#FDFBF7`, or linen tints. Use pure crisp neutrals.
3. **No Colored Side-Stripe Borders**: Never use a 3px colored `border-left` on cards. Use full subtle borders or tonal background fills.
4. **No Gradient Text**: Never use gradient text clipping on headers.
5. **No Decorative Glassmorphism**: Never use excessive background blurs where solid, high-contrast surfaces provide better readability.
6. **No Card Over-Rounding**: Cards must never exceed `16dp` corner radius.
7. **No Hardcoded Dim Typography**: Text on colored containers must maintain verified WCAG AA contrast under all conditions.
