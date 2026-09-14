# Google Play Store Release Guide & Policy Compliance

This document outlines the complete procedure, store listing metadata, policy declarations, and automation setup to publish Sayso on the Google Play Store.

---

## 1. Prerequisites

1. **Google Play Console Developer Account**:
   - One-time $25 registration fee at [play.google.com/console](https://play.google.com/console).
   - Identity verification (personal or organization D-U-N-S number).
2. **Release Keystore & Secrets**:
   - The release keystore is configured in GitHub Actions secrets:
     - `SAYSO_KEYSTORE_B64`
     - `SAYSO_KEYSTORE_PASSWORD`
     - `SAYSO_KEY_ALIAS`
     - `SAYSO_KEY_PASSWORD`
3. **Automated Bundle Output**:
   - Tagged releases (`v*`) automatically compile and attach `sayso-vX.Y.Z.aab` (Android App Bundle) to GitHub Releases.

---

## 2. Store Listing Metadata

### App Details
- **App name**: Sayso: Fast Voice Dictation
- **Short description** (max 80 chars):
  `Fast, private on-device voice dictation and speech insights across all your apps.`
- **Full description** (max 4000 chars):
  ```text
  Sayso brings lightning-fast, private voice dictation to your Android device.

  Tap the floating microphone anywhere, speak naturally, and watch your words appear instantly in any text field across all your favourite apps.

  KEY FEATURES

  - ON-DEVICE SPEECH ENGINE
    Transcribe speech locally using state-of-the-art neural models powered by Sherpa-ONNX. Zero audio leaves your phone.

  - FLOATING DICTATION BUBBLE
    Dictate anywhere with a single tap. Sayso appears whenever you are in an input field, pastes your text, and gets out of your way.

  - HANDS-FREE WAKE WORD
    Say "Hey Sayso" to initiate dictation completely hands-free without reaching for your phone.

  - SPEECH INSIGHTS & ANALYTICS
    Track your speaking cadence, words per minute (WPM), and filler word frequency over time. Level up your speaking clarity.

  - VOCABULARY & CUSTOM REPLACEMENTS
    Add custom names, technical jargon, and pronunciation hints to guarantee accurate transcription every single time.

  - OPTIONAL CLOUD POLISH
    Prefer cloud models? Connect your own API keys for OpenAI, Anthropic, Groq, Deepgram, or Gemini for advanced transcript cleanup and formatting.

  PRIVACY FIRST
  Sayso has no central servers and collects no analytics or telemetry. In local mode, your voice and transcripts never leave your device.
  ```

### Categorization
- **App category**: Tools / Productivity
- **Tags**: Voice Typing, Dictation, Speech to Text, Productivity, Utilities
- **Content Rating**: Everyone (3+)

---

## 3. Mandatory Policy Declarations

### A. Accessibility Service API Declaration (CRITICAL)
Google Play strictly enforces the Accessibility API Policy. Failure to complete this declaration accurately will lead to rejection.

- **Usage purpose**: Under "App content > Accessibility services", select **"Alternative input / Dictation tool"**.
- **User-facing explanation**:
  > "Sayso uses Android's AccessibilityService API solely to detect active text input fields on screen and paste transcribed speech into them when the user taps the dictation bubble. Sayso does not read passwords, monitor personal messages, collect keystrokes, or transmit screen data."
- **Prominent Disclosure**:
  - Implemented in `HomeScreen.kt` via a dedicated dialog before launching system accessibility settings.
  - Explains the specific data accessed, confirms zero external telemetry, and requires user agreement before directing to system settings.
- **Demonstration Video**:
  - Google Play requires a short (30-60 second) unlisted YouTube video showing the core user flow:
    1. User opening Sayso and reviewing the Prominent Disclosure dialog.
    2. Enabling Sayso in Accessibility settings.
    3. Tapping the floating microphone in a third-party app (e.g., messaging or notes) and dictating text.

### B. Data Safety Form
- **Data collected**: No data collected (in on-device mode).
- **Data shared**: No data shared with third parties.
- **Ephemeral processing**: Audio recorded only during active speech capture.
- **Security practices**:
  - API keys encrypted via Android Keystore.
  - No background telemetry, crash reporters, or advertising SDKs.

### C. Target Audience
- Select **13 and older**. Sayso does not target children under 13.

### D. Privacy Policy
- **URL**: `https://raw.githubusercontent.com/stevengonsalvez/sayso/main/PRIVACY.md` (or GitHub Pages URL).

---

## 4. Graphic Assets Required

| Asset | Specifications | Purpose |
|---|---|---|
| **App Icon** | 512 x 512 px, 32-bit PNG, max 1MB | Store listing display |
| **Feature Graphic** | 1024 x 500 px, JPG or 24-bit PNG, no alpha | Top banner in Play Store |
| **Phone Screenshots** | Min 2, max 8. 16:9 or 9:16 aspect ratio (e.g. 1080 x 2400 px) | App visual preview |

---

## 5. Play Store Release Steps

```
┌────────────────────────┐
│  Create Play Console   │
│     App "Sayso"        │
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│ Complete Store Listing │
│ (Descriptions, Assets) │
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│ Policy Questionnaires  │
│ (Data Safety, Access)  │
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│ Upload sayso-*.aab to  │
│ Internal Testing Track │
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│ Promote to Production  │
└────────────────────────┘
```

1. Log into Google Play Console and click **Create app**.
2. Complete **Dashboard setup tasks** (Privacy policy, App access, Content ratings, Target audience, Data safety, Accessibility declaration).
3. Upload store graphics (icon, feature graphic, screenshots).
4. Navigate to **Testing > Internal testing**, click **Create new release**, and upload `sayso-v1.0.11.aab`.
5. Add internal tester email addresses to test install directly from Google Play.
6. Once verified, promote release to **Production** for Google review.
