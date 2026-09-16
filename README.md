<p align="center">
  <img src="docs/logo.svg" alt="Sayso" width="120" />
</p>

<h1 align="center">Sayso</h1>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/stevengonsalvez/sayso?style=flat" alt="License" /></a>
  <img src="https://img.shields.io/badge/platform-Android%2010%2B-3DDC84?style=flat&logo=android&logoColor=white" alt="Platform" />
  <a href="https://github.com/stevengonsalvez/sayso/releases/latest"><img src="https://img.shields.io/github/v/release/stevengonsalvez/sayso?style=flat&sort=semver" alt="GitHub release" /></a>
  <a href="https://play.google.com/store/apps/details?id=ai.sayso.dictation"><img src="https://img.shields.io/badge/Google_Play-Closed_Testing-4285F4?style=flat&logo=google-play&logoColor=white" alt="Google Play" /></a>
  <a href="https://github.com/stevengonsalvez/sayso/stargazers"><img src="https://img.shields.io/github/stars/stevengonsalvez/sayso?style=flat" alt="GitHub stars" /></a>
</p>

<p align="center">
  The open-source, private voice dictation app for Android.<br/>
  Talk anywhere. Types directly into whatever app you are using: WhatsApp, Slack, Gmail, Notion, Docs. 100% offline or cloud AI.
</p>

<p align="center">
  <a href="#features">Features</a> &middot;
  <a href="#download">Download</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#on-device-models">On-Device Models</a> &middot;
  <a href="#build-from-source">Quick Start</a> &middot;
  <a href="#privacy">Privacy</a> &middot;
  <a href="#contributing">Contributing</a>
</p>

---

Sayso turns your voice into clean, polished text injected straight into whatever app you are using. Tap the floating overlay bubble or speak a hands-free wake word, talk normally, and watch your words appear directly at your cursor in WhatsApp, Slack, Gmail, Notion, Chrome, or any text box.

Choose between fully private offline transcription with on-device speech-to-text models like NVIDIA Parakeet, Moonshine, SenseVoice, and Whisper (where your audio never leaves your device), or ultra-fast cloud processing with Gemini, Deepgram, ElevenLabs, and Groq. Zero analytics, no remote telemetry, hardware-encrypted keys, fully open source.

## Download

| Source | Link | Notes |
|---|---|---|
| GitHub Releases | [`.apk`](https://github.com/stevengonsalvez/sayso/releases/latest) | Direct APK install, universal build |
| Google Play | [`Play Store`](https://play.google.com/store/apps/details?id=ai.sayso.dictation) | Closed testing track (`ai.sayso.dictation`) |
| Build from Source | [`make build`](#build-from-source) | Kotlin + Android SDK platform 36 |

## Architecture

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│ Floating Bubble │──────▶│ Audio Capture   │──────▶│ STT Engine      │
│ (Overlay / Mic) │       │ (16kHz PCM Wav) │       │ (Local / Cloud) │
└─────────────────┘       └─────────────────┘       └────────┬────────┘
                                                             │
                                                             ▼
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│ Active App      │◀──────│ Text Injector   │◀──────│ AI Polisher     │
│ (Target Cursor) │       │ (Accessibility) │       │ (Rules / LLM)   │
└─────────────────┘       └─────────────────┘       └─────────────────┘
```

## Features

- **Push-to-talk floating bubble**: Draggable, edge-snapping overlay button accessible from any screen or app. Single tap to record, tap to finish, or hold to talk.
- **Direct cursor text injection**: Injects text directly into the focused field of any Android application via Accessibility Service without needing to switch keyboards.
- **100% offline on-device transcription**: Run high-accuracy speech-to-text locally via sherpa-onnx. Zero network required, zero audio leaves your phone.
- **Cloud STT providers (BYOK)**: Connect Google Gemini 2.5 Flash, Deepgram Nova-3, ElevenLabs Scribe, OpenAI Whisper, or Groq with your own API keys.
- **Smart AI polish and text cleanup**: Automatically removes stutter, filler words ("um", "uh"), fixes capitalization, and repairs punctuation.
- **Dedicated dictation modes**:
  - *Clean*: Natural punctuation, grammar cleanup, and conversational formatting.
  - *Developer*: Formats camelCase, snake_case, code snippets, bash commands, and terminal syntax.
  - *Note / Summary*: Converts spoken rambling into concise bulleted notes.
- **Custom vocabulary and phonetic lexicon**: Teach Sayso names, technical jargon, acronyms, and slang. Includes keyword biasing for cloud recognizers (Deepgram keyterms, Whisper prompts).
- **Hands-free wake word activation**: Activate dictation hands-free with background wake-word detection.
- **Audio history with playback**: Inspect past transcriptions, replay recorded voice clips, or re-process clips with different models.
- **Productivity insights**: Track speaking speed (WPM), total words dictated, filler word rate, and most frequent vocabulary.
- **Sound cues and haptic feedback**: Subtle audio chimes and vibrations for record start, completion, and error states.
- **Hardware-encrypted security**: API keys are encrypted using the Android Keystore (`KeystoreSecretStore`). Keys never leave your device unencrypted.
- **Zero telemetry**: No third-party trackers, no crash analytics SDKs, no centralized database.

## On-Device Models

Download and manage models directly inside the app. Weights are stored in private app storage.

| Model | Size | Best For | Languages |
|---|---:|---|---|
| Parakeet 110M | ~100 MB | Fast, accurate daily dictation (Recommended) | English |
| Moonshine Tiny | ~100 MB | Ultra-low latency on older devices | English |
| Moonshine Base | ~250 MB | High accuracy with fast response | English |
| Whisper Base | ~200 MB | Robust baseline vocabulary | English |
| Parakeet 0.6B v3 | ~490 MB | Maximum accuracy, complex sentences | Multilingual |
| SenseVoice | ~170 MB | Voice dictation with emotion and multilingual support | English, Chinese, Japanese, Korean, Cantonese |

## Setup

1. Grant **Microphone** permission for voice recording.
2. Enable the **Sayso Accessibility Service** (the app provides a direct link).
3. (Optional) Grant **Display over other apps** permission for the floating bubble.
4. Select your preferred engine: download an on-device model or enter a cloud provider API key.

> **Why an Accessibility Service?**
> Android only permits an accessibility service to insert text directly into another app's focused text field. Sayso uses this permission solely to paste your transcribed words at the active cursor position. It does not read your screen, track keystrokes, or transmit any user data. If a field cannot accept direct injection, Sayso falls back to copying text to your clipboard.

## Build from Source

### Prerequisites
- JDK 17
- Android SDK (Platform 36, Build Tools 36.0.0)

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

The first build automatically retrieves the `sherpa-onnx` runtime AAR from k2-fsa into `app/libs/`.

## Tech Stack

- **UI & Architecture**: 100% Kotlin, Jetpack Compose, Material 3, Coroutines, StateFlow
- **Audio & ML**: AudioRecord (16kHz PCM), sherpa-onnx runtime, ONNX Runtime Mobile
- **Text Injection**: Android AccessibilityService, WindowManager overlay
- **Persistence**: Room SQLite database, Android Keystore encryption
- **Networking**: OkHttp 4, Server-Sent Events (SSE)

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=stevengonsalvez/sayso&type=date&legend=top-left)](https://www.star-history.com/#stevengonsalvez/sayso&type=date&legend=top-left)

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository.
2. Create a feature branch (`git checkout -b feat/my-feature`).
3. Commit your changes using conventional commits and GPG signing (`git commit -S -m "feat: description"`).
4. Push to your branch (`git push origin feat/my-feature`).
5. Open a Pull Request.

## Privacy

Sayso is private by design. Review our full privacy policy in [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE) - free for personal and commercial use.
On-device recognition is powered by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0).
