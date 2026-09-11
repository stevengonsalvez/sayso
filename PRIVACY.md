# Privacy Policy

Sayso is a dictation app for Android. It records your voice when you tap the floating button, converts the recording to text, and types that text into the field you are editing.

## What Sayso processes

- **Audio**: recorded only while the button shows the recording state. Recording stops when you tap again or when the maximum duration is reached.
- **Transcript text**: the words recognised from your audio, plus the optional cleaned-up version.
- **History** (optional, on by default): recent transcripts and their audio clips are stored on your device so you can copy or reprocess them. You can delete individual items or clear everything from the History screen, and you can turn history off in Settings.

## Where your data goes

Sayso has no backend. Nothing is sent to us.

- **On-device mode**: audio is processed locally by a speech model downloaded to your phone. Audio never leaves the device.
- **Cloud transcription**: if you choose a cloud provider (OpenAI, Deepgram, Groq, ElevenLabs, or Google Gemini), the audio clip is sent directly from your phone to that provider using your own API key. The provider's privacy policy applies.
- **Cloud cleanup**: if you enable cleanup with a cloud model (OpenAI, Anthropic, Groq, Google Gemini, or OpenRouter), the transcript text is sent directly to that provider using your own API key.
- **Built-in rules cleanup** runs entirely on the device.

## API keys

Keys are stored on your device, encrypted with a key held in the Android Keystore. They are used only to authenticate requests to the provider you chose.

## Accessibility Service

Sayso uses the Android Accessibility Service for one purpose: to find the text field you are editing and insert dictated text after you tap the floating button. It does not read screen content for any other reason, does not monitor your activity, and does not run automation. If insertion is not possible, the text is copied to the clipboard instead.

## Analytics and tracking

Sayso contains no analytics, advertising, or crash reporting SDKs.

## Contact

Questions about privacy: liam@shotclubhouse.com
