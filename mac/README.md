# OwnVoice Meet for the Mac (native)

A native rewrite of OwnVoice Meet in Swift and SwiftUI, for Apple Silicon Macs on macOS 26 or
later. It lives next to the cross-platform app (the repo root) until it does everything that one
does; then the other is retired.

## Stage 1 (this)

- **Sound**: what the Mac plays (a Core Audio process tap; asks once for System Audio Recording
  Only, never for screen recording) or a microphone.
- **Listen**: Apple on-device recognition (SpeechAnalyzer, free) or Gemini 3.5 Transcribe Live.
- **Translate**: Apple Translation (on-device, free), Claude Haiku 5.5, Gemini 3.5 Flash-Lite, or
  Gemma 4 E4B in a local Ollama; into **繁體中文（台灣）** or **简体中文** (Settings).
- A caption window that can float over the meeting; Settings; keys in the login Keychain.
- **Interface in English, 繁體中文 and 简体中文**: follows the Mac, or chosen in Settings →
  Appearance. Strings live in `Resources/*.lproj/Localizable.strings`, keyed by the English text in
  the code; `scripts/check-strings.py` fails the build when one is missing.

## Stage 2

- **Reply** (⌘1): type Chinese, get the words to read aloud in the language you speak (Settings →
  I speak), streamed in large text, with the recent captions, the glossary and the script as context.
- **Script** (⌘2): the bilingual script format (sections as tabs, cues, Q:, `>` meanings, copy
  blocks), edited in place, opened from a .md file or started from the template, kept between
  launches. **Fill In Missing Halves** (補對照) adds the missing half of each line. Captions, replies
  and the summary all read the script as context.
- **Summary** (⌘3): at most 8 points in the chosen Chinese, brought up to date every few minutes
  (Settings → Summary & Saving) and when listening stops, or on Update Now.
- **Saving** (off unless chosen): each session a folder with transcript.md and summary.md, and
  recording.m4a if chosen.
- Captions stream: the Chinese grows as the model writes it.
- Replies, the summary and 補對照 use the text model chosen under Translation; with Apple
  Translation, the first with a key (Claude, Gemini), else Gemma in Ollama.

## Gemma 4 in one click

Settings → Listen & Translate → **Gemma 4 on this Mac** (also in the app menu: Set Up Gemma 4…):
one button installs whatever is missing. Ollama comes from ollama.com (Ollama-darwin.zip, unpacked
with ditto, its Developer ID signature checked before anything is installed, marked as downloaded so
Gatekeeper checks it on first open, into /Applications or ~/Applications), is started, and the
Gemma 4 E4B model is pulled through Ollama's API with progress. Then Gemma 4 is chosen under
Translation.

Not yet: speaker labels, segments, usage costs, idle pause and auto-end, OpenAI and the ChatGPT
plan, Gemini Transcribe and Live Translate, updates.

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

The build is signed with a local certificate that `scripts/signing-identity.sh` makes once in the
login keychain (macOS may ask once to let codesign use it: Always Allow). The signature stays the
same between builds, so macOS keeps the permissions it granted; an ad hoc signature changed every
build and every rebuild asked again. Set `SIGN_IDENTITY` to sign with a Developer ID instead.

The code avoids SwiftUI's `@State`: in the macOS 27 SDK it became a macro whose plugin ships only
with Xcode, so the Command Line Tools could not build it. State lives in the observable `AppModel`
instead; CI fails if `@State` comes back.
