<p align="center">
  <img src="assets/logo.svg" alt="Sayso" width="120" />
</p>

<h1 align="center">Sayso: 100% Private Voice Dictation</h1>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat" alt="License" /></a>
  <img src="https://img.shields.io/badge/Cost-100%25%20Free%20%26%20Open%20Source-brightgreen?style=flat" alt="Free" />
  <img src="https://img.shields.io/badge/Privacy-Zero%20Data%20Leaves%20Device-success?style=flat&logo=shield" alt="Privacy" />
  <img src="https://img.shields.io/badge/Platform-Android%2011%2B%20(API%2030%2B)-3DDC84?style=flat&logo=android&logoColor=white" alt="Platform" />
  <a href="https://github.com/stevengonsalvez/sayso/releases/latest"><img src="https://img.shields.io/github/v/release/stevengonsalvez/sayso?style=flat&sort=semver" alt="GitHub release" /></a>
  <a href="https://play.google.com/store/apps/details?id=ai.sayso.dictation"><img src="https://img.shields.io/badge/Google_Play-Closed_Testing-4285F4?style=flat&logo=google-play&logoColor=white" alt="Google Play" /></a>
  <a href="https://github.com/stevengonsalvez/sayso/stargazers"><img src="https://img.shields.io/github/stars/stevengonsalvez/sayso?style=flat" alt="GitHub stars" /></a>
</p>

<p align="center">
  <strong>The 100% private, free, and open-source voice typing assistant for Android.</strong><br/>
  Talk anywhere. Types directly into WhatsApp, Slack, Gmail, Notion, Docs, or Termux.<br/>
  <strong>No subscriptions. No ads. No telemetry. Zero audio or text ever leaves your phone.</strong>
</p>

<p align="center">
  <a href="#key-features">Key Features</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#on-device-models">Voice Models</a> &middot;
  <a href="#download">Download</a> &middot;
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#privacy--data-safety">Privacy</a> &middot;
  <a href="#tech-stack">Tech Stack</a> &middot;
  <a href="#macos-app-sayso-notch-status">macOS status</a>
</p>

---

## 🌟 Key Features

### 🔒 100% Private, On-Device, and Offline
Sayso processes all speech on your phone hardware. Zero audio bytes, transcripts, or keystrokes are transmitted to external servers. It runs without internet, in airplane mode, or in remote areas. No account registration, no remote databases, no tracking, and no analytics SDKs.

### 💸 Completely Free Forever
No subscriptions, no usage tiers, no paywalls, and no ads. 100% open-source software under the MIT license.

### 🎙️ Hands-Free "Hey Sayso" Wake Word (with VoIP Protection)
- Say **"Hey Sayso"** or **"Sayso"** to trigger voice dictation completely hands-free.
- **Smart Call Suppression**: Automatically pauses wake-word listening during cellular phone calls, WhatsApp voice calls, and VoIP meetings. It never pops up or interrupts conversations.
- Adjustable acoustic sensitivity (High, Medium, Low) for quiet rooms or noisy commutes.

### 🇮🇳 Indian Languages with Tanglish & Hinglish Transliteration
- Powered by state-of-the-art **AI4Bharat IndicConformer** models for Tamil, Hindi, and Malayalam.
- **Phonetic Transliteration**: Speak colloquial Tamil, Hindi, or Malayalam, and Sayso converts it to readable Tanglish, Hinglish, or Manglish in English letters (e.g. *"Vanakkam, eppadi irukkeenga?"*).
- 1-tap toggle between phonetic English letters and native scripts (தமிழ், हिंदी, മലയാളം).

### ⚡ Sub-100ms Ultra-Fast English Dictation
Powered by NVIDIA Parakeet TDT CTC 110M INT8 via Sherpa-ONNX. Delivers desktop-grade real-time factor (RTF < 0.15) for instant dictation with zero lag.

### 🚀 Types Directly Over Any App
A lightweight floating microphone bubble hovers unobtrusively over your screen. Tap or speak the wake word, and Sayso types your words directly into WhatsApp, Slack, Gmail, Notion, Chrome, or Termux via the Android AccessibilityService API. No copy-pasting required.

### ✨ On-Device AI Polish & Smart Markdown Formatting
- Built-in regex rules and local SLMs (Qwen 2.5 0.5B / Phi-3 Mini) clean up filler words ("um", "uh"), remove stutter, and repair punctuation.
- **Task Formatting**: Say "action items" or "todo list" to generate clean Markdown checklists: `- [ ] buy groceries`.
- **Note Summaries**: Dictate rambling thoughts and convert them into structured bullet points.

### 🌐 90+ Multilingual Languages Supported
Easily switch to Whisper Multilingual Tiny or Base to dictate in Spanish, French, German, Italian, Portuguese, Dutch, Japanese, Korean, Chinese, Arabic, and more.

### 🔑 Bring Your Own Key (BYOK) Cloud Option
If you prefer cloud models, optionally connect OpenAI Whisper, Google Gemini 2.5 Flash, Deepgram Nova-3, ElevenLabs, or Groq with your own API keys. All keys are encrypted locally using the Android Keystore (`KeystoreSecretStore`).

---

## 🏛️ Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                              SAYSO CORE                                │
│                                                                        │
│   ┌──────────────────┐    ┌──────────────────┐    ┌────────────────┐   │
│   │   Audio Source   │───▶│  KWS Wake Word   │───▶│ Audio Capture  │   │
│   │  (16kHz/16-bit)  │    │  (Zipformer 4MB) │    │  (Noise Floor) │   │
│   └──────────────────┘    └──────────────────┘    └───────┬────────┘   │
│            │                       │                      │            │
│            ▼                       ▼                      ▼            │
│   ┌──────────────────┐    ┌──────────────────┐    ┌────────────────┐   │
│   │ CallStateDetector│    │ Neural LID (Opt) │    │ Local STT Pool │   │
│   │ (Zero-Permission)│    │  (Whisper Tiny)  │    │ Parakeet/Indic │   │
│   └──────────────────┘    └──────────────────┘    └───────┬────────┘   │
│                                                           │            │
│                                                           ▼            │
│   ┌──────────────────┐    ┌──────────────────┐    ┌────────────────┐   │
│   │ Accessibility API│◀───│ Post-Processing  │◀───│ Indic Translit │   │
│   │ (Types in Apps)  │    │  (SLM / Rules)   │    │  (Phonetic)    │   │
│   └──────────────────┘    └──────────────────┘    └────────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 📦 On-Device Voice Models

Download and manage models directly from the app. All model weights are stored in private app storage.

| Model | Size | Best For | Languages |
|---|---|---|---|
| **Parakeet 110M** (Recommended) | 104 MB | Ultra-fast real-time daily dictation | English |
| **AI4Bharat IndicConformer Tamil** | 189 MB | Superior accuracy on colloquial Tamil, Tanglish & dialects | Tamil, Tanglish |
| **AI4Bharat IndicConformer Hindi** | 189 MB | Superior accuracy on colloquial Hindi, Hinglish & dialects | Hindi, Hinglish |
| **AI4Bharat IndicConformer Malayalam** | 189 MB | Superior accuracy on colloquial Malayalam & Manglish | Malayalam, Manglish |
| **Whisper Multilingual Tiny** | 111 MB | Lightweight multilingual speech & neural language detection | 90+ languages |
| **Whisper Multilingual Base** | 198 MB | Higher accuracy multilingual transcription | 90+ languages |
| **Qwen 2.5 0.5B Instruct** (SLM) | 390 MB | On-device AI polish, task checklists & punctuation | English, Multilingual |
| **Phi-3 Mini 4K Instruct** (SLM) | 2.2 GB | Comprehensive offline rewriting & reasoning | English |

---

## 📲 Download

| Channel | Link | Notes |
|---|---|---|
| **Google Play** | [Play Store Listing](https://play.google.com/store/apps/details?id=ai.sayso.dictation) | Closed testing track (`ai.sayso.dictation`) |
| **GitHub Releases** | [Download APK](https://github.com/stevengonsalvez/sayso/releases/latest) | Universal Android APK |
| **Source Code** | [Build from Source](#quick-start) | Full project repository |

---

## 🛠️ Quick Start

### Build Prerequisites
- JDK 17 (`JAVA_HOME=/opt/homebrew/opt/openjdk@17` or standard JDK 17)
- Android SDK Platform 36 and Build Tools 36.0.0

```bash
# Clone the repository
git clone https://github.com/stevengonsalvez/sayso.git
cd sayso

# Build debug APK (outputs to app/build/outputs/apk/debug/app-debug.apk)
make build

# Run unit tests
make test

# Install to connected device or emulator via ADB
make install
```

The first build automatically fetches the `sherpa-onnx` runtime AAR into `app/libs/`.

---

## 🛡️ Privacy & Data Safety

- **Zero Data Collection**: Sayso collects 0 bytes of personal information, usage metrics, crash reports, or analytics.
- **Audio Stays Local**: Audio is recorded strictly to private memory buffers during dictation and discarded or saved only to your local history if history is enabled.
- **Accessibility API Disclosure**: Sayso uses Android AccessibilityService solely to type your speech directly into the input field you are editing. It does not inspect passwords, read personal messages, or monitor background activity.

---

## 💻 Tech Stack

- **UI**: 100% Kotlin, Jetpack Compose, Material 3, Dynamic Theme (#1E2A44 Navy & #F4B942 Golden Amber)
- **Speech & ML Engine**: Sherpa-ONNX runtime (k2-fsa), ONNX Runtime Mobile, Zipformer acoustic KWS
- **Transliteration**: Custom rule-based phonetic Brahmic transliteration engine
- **Telephony & Call State**: Zero-permission hardware `AudioManager` call mode observer
- **Text Insertion**: Android AccessibilityService, WindowManager overlay
- **Security**: Hardware-backed Android Keystore (`KeystoreSecretStore`)
- **Storage**: Room SQLite database (local private storage)

---

## 🍎 macOS app (Sayso Notch): status

A native macOS notch app lives under [`macos/`](macos/) (SwiftPM, SwiftUI). This section says what exists, what has been proven live on a real Mac, and what is still open. Status as of 2026-11-21; the evidence, with timestamps and screenshots, is in [`docs/ultimate-notch/PROOF_LEDGER.md`](docs/ultimate-notch/PROOF_LEDGER.md), and the test runbook is [`docs/ultimate-notch/E2E_BATCH_1.md`](docs/ultimate-notch/E2E_BATCH_1.md). It is signed for development only, not notarised, and there is no Apple Developer account yet (release plan: [`docs/macos-release-plan.md`](docs/macos-release-plan.md), issue #86).

### What is built

- **Dictation** from the notch with double Fn: on-device (Parakeet Realtime EOU 120M for live streaming; Parakeet TDT 0.6B v3 for finished English recordings when its files are installed), cloud providers you bring a key for (Deepgram, Groq, OpenAI-compatible; each needs an explicit consent switch), and Apple Speech.
- **Text polish**: rules or local model cleanup, a vocabulary with learned corrections, and spoken numbers and times written as digits (`three thirty pm` becomes `3:30 PM`, `555-0192`, `25%`).
- **Control** (hands-free desktop control with review cards), **Voice output**, **History**, **Models and downloads**.
- **Notch modules**: Now Playing, Pomodoro and timers, Caffeine, World clocks, System stats, Calculator, Colour picker, File tools, Privacy guard (microphone and camera in use), Snippets, Battery health, Clipboard and File shelf.

### Proven live on a real Mac

| Area | Result | Notes |
|---|---|---|
| Hotkeys 3.1, 3.2, 3.3 | Partly | Synthetic Fn events pass; a physical double tap (history entries) and triple tap (Control mode screenshot) were seen. Key edges and the live status during the physical presses were not captured. |
| Hotkey 3.4 (Control-Option-N) | Pass | |
| Dictation into TextEdit, Arc, Orca, WhatsApp (draft only, nothing sent), Finder rename field | Pass | Finder needed fixes #121 and #91. |
| Voice output (TTS) | Partly | Heard by a person; Stop during speech not exercised. |
| Models download | Partly | Notch download line and Cancel pass (#90); a full download to "ready" was not observed. |
| Vocabulary | Pass | Suggestion, Remember and learned correction (#102). |
| Privacy guard | Pass | Real microphone and camera, notch line shown and cleared. |
| Now Playing | Partly | Line shown and cleared with Sayso's own Automation grant; the track had no artist, and pause, resume and stop were not exercised. |
| Pomodoro | Partly | Countdown and phase change pass; a chime was heard, which phase change is an inference. |
| Colour sampler | Pass | |
| Control: review card, Approve, Deny, clarification buttons | Partly | Seen live on Calculator. Not observed: `12 x 3 = 36`, Approve running exactly once, a stale approve, the audit entry. Paused by the owner; details in #149. |
| Local English dictation quality | Known gap | Streaming uses the small model (lowercase, no punctuation, dropped words); Parakeet v3 and Whisper Large v3 Turbo were far better on a test paragraph. See #144. |

### Still open

| Issue | What |
|---|---|
| [#149](https://github.com/stevengonsalvez/sayso/issues/149) | Control live proof, paused: what is done and what is pending. |
| [#146](https://github.com/stevengonsalvez/sayso/issues/146) | Desktop Control cannot be switched on from the app (the switch was removed); needs `--automation-server`. |
| [#144](https://github.com/stevengonsalvez/sayso/issues/144) | Local model choices do nothing for English dictation; the WhisperKit card is static text; pre-warm and unload. |
| [#143](https://github.com/stevengonsalvez/sayso/issues/143) | Same actor-isolation trap on first-run permission callbacks. |
| [#139](https://github.com/stevengonsalvez/sayso/issues/139) | Cloud consent survives editing the provider base URL; consent switch only on the cloud route. |
| [#140](https://github.com/stevengonsalvez/sayso/issues/140), [#148](https://github.com/stevengonsalvez/sayso/issues/148) | Two flaky tests (scheduler timing, disk free on the runner). |
| [#86](https://github.com/stevengonsalvez/sayso/issues/86) | Release plan: Developer ID, notarisation, DMG, Sparkle, permission grants across updates. |
| #132, #130, #123, #120, #99, #95, #92, #87 | Follow-ups from earlier merge-gate reviews. |

## 🏷️ Tags & Topics

`#voice-dictation` `#speech-to-text` `#offline-stt` `#privacy` `#on-device-ai` `#android` `#sherpa-onnx` `#parakeet` `#ai4bharat` `#tanglish` `#hinglish` `#wake-word` `#whisper` `#open-source` `#free-software`

---

## 📄 License

Sayso is licensed under the [MIT License](LICENSE).
On-device speech recognition is powered by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0).
