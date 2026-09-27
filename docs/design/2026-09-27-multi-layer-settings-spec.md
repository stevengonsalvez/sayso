# Specification: Multi-Layer Pipeline Settings and Android Parity

**Generated from:** Settings Architecture Interview
**Interview date:** 2026-09-27
**Version:** 1.0

## Executive Summary

Restructure Sayso desktop settings to match the multi-layer pipeline architecture from the Sayso Android application. Introduces dedicated workspaces for Pre-Processing, Speech Recognition Models, Post-Processing (Cleanup), and a categorized Vocabulary & Pronunciation Dictionary with Android-compatible JSON import and export.

## Architecture & Flow

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Sayso Pipeline Settings                         │
├───────────────────┬────────────────────────────────────────────────────┤
│ 1. Pre-Processing │ Mic Input, Acoustic Hints, Silence Timeout, LID    │
│ 2. Speech Models  │ On-Device (Parakeet/Indic/Sherpa) + Cloud STT      │
│ 3. Post-Processing│ Modes (Rules/Cloud), Presets, App Context Style    │
│ 4. Vocabulary     │ Categorized Dictionary, Phonetics, JSON Sync       │
│ 5. HUD & Triggers │ Notch/Floating, ⌥Space, ⌃⌥Space, ⌃⌥N              │
└───────────────────┴────────────────────────────────────────────────────┘
```

## Sidebar Navigation Structure

| Section | Workspace | Tag | Purpose |
|---|---|---|---|
| Activity | Dictation | 0 | Live dictation, audio visualizer, quick copy |
| Activity | History | 1 | Transcripts, audio playback, language filter, export |
| Activity | Desktop Control | 2 | Computer use, accessibility permissions, audit trail |
| Pipeline | Pre-Processing | 3 | Microphone input, acoustic hints, silence timeout, LID |
| Pipeline | Speech Models | 4 | Local on-device STT catalog and Cloud STT providers |
| Pipeline | Post-Processing | 5 | Rules vs LLM, prompt presets, app context awareness |
| Pipeline | Vocabulary | 6 | Pronunciation dictionary, categories, import/export |
| Desktop & Triggers | Notch & HUD | 7 | Presentation style (Notch vs Floating), size controls |
| Desktop & Triggers | Shortcuts | 8 | Configurable hotkeys (Dictation, Control, Toggle Notch) |
| System | Voice Output | 9 | Text-to-speech voice, speed, test tone |
| System | Settings Hub | 10 | Permissions, automation socket, reset defaults, about |

## Components & Contracts

### 1. Pronunciation & Vocabulary Domain (`PronunciationDomain.swift`)

Matches Android `PronunciationCategory` and `PronunciationEntry` schema:

```swift
public enum PronunciationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case technical = "Technical"
    case names = "Names"
    case acronyms = "Acronyms"
    case symbols = "Symbols"
    case brands = "Brands"
    case medical = "Medical"
    case custom = "Custom"

    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

public struct PronunciationEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var word: String
    public var pronunciation: String
    public var replacement: String?
    public var category: PronunciationCategory
    public var isRegex: Boolean
    public var caseSensitive: Boolean
}
```

- JSON Encoding/Decoding compatible with Android `Lexicon.encodePronunciations`
- Default seeding from standard developer dictionary (iOS, macOS, CLI, GUI, JSON, YAML, kubectl, Kubernetes, PostgreSQL, AWS, etc.)
- Full import/export file picker support in macOS

### 2. Pre-Processing Suite

- Microphone Input Device picker (CoreAudio HAL)
- Spoken Language selector with Early LID auto-routing toggle
- Acoustic Vocabulary Hints (comma-separated list for speech engine bias)
- Silence Auto-Stop Toggle and Duration Slider (0.5s to 5.0s)
- Maximum Recording Duration Slider (15s to 300s)
- Start/Stop Sound Cues Toggle
- Indic Transliteration to Latin Script Toggle

### 3. Post-Processing & Cleanup Pipeline

- Mode selection: Rules-Based (fast regex/local) vs Cloud LLM (OpenAI, Gemini, Anthropic, OpenRouter)
- Prompt Presets:
  - Standard (base formatting and punctuation)
  - Developer (code identifiers, CLI flags, camelCase preservation)
  - Minimal (punctuation and capitalization only)
  - Casual (conversational, concise)
  - Custom (full prompt template editor)
- App Context Awareness:
  - Chat & Messaging (Slack, Discord, Messages)
  - Email (Mail, Outlook)
  - Code & Terminal (Terminal, iTerm, Xcode, VS Code)
  - Docs & Notes (Notes, Notion, Pages)
  - General
- Output Language selection

### 4. Vocabulary Workspace UI

- Search bar for quick filter across words, pronunciations, and replacements
- Category filter chips (All, Technical, Names, Acronyms, Symbols, Brands, Medical, Custom)
- Add new word / Edit entry modal sheet
- Delete confirmation
- Export Dictionary to JSON button
- Import Dictionary from JSON button

## Implementation Plan

1. Create `macos/Sources/SaysoCore/PronunciationDomain.swift` with models, defaults, and JSON encoders.
2. Extend `SaysoSettings` in `SaysoCore/Domain.swift` with pre-processing, post-processing presets, and pronunciation dictionary array.
3. Build `PreProcessingWorkspace`, `PostProcessingWorkspace`, and `VocabularyWorkspace` in `SaysoNotchApp.swift`.
4. Update sidebar navigation tags in `SaysoNotchApp.swift` to reflect the 11 structured tabs.
5. Add unit tests in `SaysoCoreTests/PronunciationDomainTests.swift`.
6. Verify test suite, package release app, and restart live process.
