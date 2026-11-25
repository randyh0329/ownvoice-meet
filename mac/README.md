# OwnVoice Meet for the Mac (native)

A native rewrite of OwnVoice Meet in Swift and SwiftUI, for Apple Silicon Macs on macOS 26 or
later. It lives next to the cross-platform app (the repo root) until it does everything that one
does; then the other is retired.

## Stage 1 (this)

- **Sound**: what the Mac plays (ScreenCaptureKit; asks once for Screen & System Audio Recording)
  or a microphone.
- **Listen**: Apple on-device recognition (SpeechAnalyzer, free) or Gemini 3.5 Transcribe Live.
- **Translate**: Apple Translation (on-device, free), Claude Haiku 5.5, Gemini 3.5 Flash-Lite, or
  Gemma 4 E4B in a local Ollama; into **繁體中文（台灣）** or **简体中文** (Settings).
- A caption window that can float over the meeting; Settings; keys in the login Keychain.
- **Interface in English, 繁體中文 and 简体中文**: follows the Mac, or chosen in Settings →
  Appearance. Strings live in `Resources/*.lproj/Localizable.strings`, keyed by the English text in
  the code; `scripts/check-strings.py` fails the build when one is missing.

Not yet: the reply window and script, the live summary, recordings and transcripts, speaker labels,
usage costs, OpenAI and the ChatGPT plan, Gemini Live Translate, updates.

## Layout

- `Core/`: plain logic with tests (prompts, Chinese variants, caption lines, Gemini Live messages,
  request formats). macOS 13 so the tests run on older CI machines; `swift test --package-path Core`.
- `Sources/OwnVoiceMeet/`: the app (audio, recognizers, translators, views).
- `Resources/`: Info.plist, entitlements, icon, translations.
- `scripts/build-app.sh`: `swift build`, the .app bundle, signing (`SIGN_IDENTITY`, ad hoc
  otherwise), the .dmg, into `build/`.

## Build on a Mac

Xcode 26 or later, or just the Command Line Tools (`xcode-select --install`), then:

```bash
cd mac && scripts/build-app.sh
open "build/OwnVoice Meet.app"
```

The ad hoc signed app: the first time, allow it in System Settings → Privacy & Security.

The code avoids SwiftUI's `@State`: in the macOS 27 SDK it became a macro whose plugin ships only
with Xcode, so the Command Line Tools could not build it. State lives in the observable `AppModel`
instead; CI fails if `@State` comes back.
