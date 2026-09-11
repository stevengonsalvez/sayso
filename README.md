<p align="center">
  <img src="docs/logo.svg" width="128" height="128" alt="Sayso">
</p>

# Sayso

Push-to-talk dictation for Android that types into whatever you are already editing.

Tap the floating button, talk, tap again. Sayso transcribes the clip on-device or with the cloud provider of your choice, optionally cleans it up, and inserts the text into the focused field. It does not replace your keyboard.

## Features

- **Six transcription backends**: on-device (sherpa-onnx models such as Parakeet, Moonshine, Whisper, SenseVoice), OpenAI, Deepgram, Groq, ElevenLabs Scribe, and Google Gemini.
- **Cleanup**: fix punctuation, casing, and recognition slips with built-in rules (offline) or an LLM (OpenAI, Anthropic, Groq, Gemini, OpenRouter). Presets for everyday text and developer dictation, or write your own prompt.
- **Vocabulary**: teach Sayso the spelling of names and jargon. Rules apply before cleanup and are also passed to the model.
- **Recognition hints**: bias cloud recognisers towards your terms (Deepgram keyterms, Whisper prompts).
- **History**: recent transcripts with audio, so you can copy them again or reprocess a clip with new settings.
- **Insights**: words per minute, filler rate, most used words.
- **Private by design**: no backend, no analytics. Cloud requests go straight from your phone to the provider with your own API key. Keys are encrypted with the Android Keystore.

## Install

Download the latest APK from [Releases](https://github.com/stevengonsalvez/sayso/releases), open it on your phone, and launch Sayso once to finish setup.

### Setup

1. Grant the microphone permission.
2. Enable the Sayso accessibility service (the app links you to the right settings page).
3. Pick a transcription model: download an on-device model, or paste an API key for a cloud provider.

The floating button appears as soon as the service is enabled. Drag it anywhere; it snaps to the nearest edge.

## Why an accessibility service?

Android only lets an accessibility service insert text into another app's field. Sayso uses that ability for exactly one thing: putting your dictated text where your cursor is, after you tap the button. It does not read the screen for any other purpose, and it does nothing in the background. If a field cannot be written to, the text is copied to the clipboard instead.

## Build from source

Requires JDK 17 and the Android SDK (platform 36).

```bash
git clone https://github.com/stevengonsalvez/sayso.git
cd sayso
make build          # app/build/outputs/apk/debug/app-debug.apk
make test           # JVM unit tests
make install        # adb install
```

The first build downloads the sherpa-onnx runtime (an AAR from the k2-fsa releases) into `app/libs/`.

## On-device models

Models are downloaded inside the app and stored in private app storage.

| Model | Size | Notes |
|---|---:|---|
| Parakeet 110M | ~100 MB | Recommended default, English |
| Moonshine Tiny | ~100 MB | Fastest |
| Moonshine Base | ~250 MB | Better accuracy, still quick |
| Whisper Base | ~200 MB | Solid baseline, English |
| Parakeet 0.6B v3 | ~490 MB | Best quality, multilingual |
| SenseVoice | ~170 MB | Chinese, English, Japanese, Korean, Cantonese |

## Privacy

See [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE). On-device recognition is powered by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0).
