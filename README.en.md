# OwnVoice Meet (native Mac branch)

[繁體中文](README.md) · **English**

**Understand the meeting. Answer in your own voice.**

In an online meeting or a talk, live captions put the meaning of what others say under it in Chinese; when you want to speak, you type what you mean in Chinese and get a sentence you can say in the meeting's language, which you read aloud. It does not answer for you: the words are yours, and so is the voice.

**[Download the native Mac app (.dmg, Apple Silicon, macOS 26 or later)](https://github.com/randyh0329/ownvoice-meet/releases/download/mac-v0.6.2/OwnVoice-Meet-0.6.2-mac-arm64.dmg)** · [All releases](https://github.com/randyh0329/ownvoice-meet/releases/latest) · [First use](#first-use)

This is a fork of [Zaious/ownvoice-meet](https://github.com/Zaious/ownvoice-meet) (`randyh0329/ownvoice-meet`, branch `main`; development on `gemini-transcribe`). Its main addition is a **native Mac app rewritten in Swift and SwiftUI** (Apple Silicon, macOS 26 or later) in [`mac/`](mac/); the original cross-platform app (Tauri, Windows and macOS) stays at the repo root until the native app does everything it does.

> **Status: native Mac app 0.6.2 (preview).** Tested on an Apple M5: the Mac's sound, Apple on-device recognition, Apple Translation, Gemma 4, caption colors and saving. The options new in 0.6 build and pass CI, and are still being tried.

## Download

| Version | For | Where |
|---|---|---|
| **Native Mac app** (recommended) | Apple Silicon (M1 and later), macOS 26 or later | **[OwnVoice-Meet-0.6.2-mac-arm64.dmg](https://github.com/randyh0329/ownvoice-meet/releases/download/mac-v0.6.2/OwnVoice-Meet-0.6.2-mac-arm64.dmg)** ([release page](https://github.com/randyh0329/ownvoice-meet/releases/latest)). Open the .dmg and drag OwnVoice Meet to Applications. The newest development build is under [Actions → "Mac app (Swift)"](https://github.com/randyh0329/ownvoice-meet/actions/workflows/mac-native.yml?query=is%3Asuccess) (sign in to GitHub), or [build it](#build-from-source). |
| Cross-platform app (Tauri), Mac | Intel and Apple Silicon, macOS 11 or later | [Actions → "macOS DMG"](https://github.com/randyh0329/ownvoice-meet/actions/workflows/dmg.yml): the newest green run, `OwnVoice-Meet-macOS-dmg` under Artifacts. Listens through a microphone only on the Mac. |
| Cross-platform app, Windows | Windows 10 and 11 | The original author's [0.4.0 release](https://github.com/Zaious/ownvoice-meet/releases/latest) (without this branch's additions). |

Actions keeps its files for 90 days; release files stay. The downloaded app is not notarized by Apple, so macOS blocks it the first time: choose Open Anyway in System Settings → Privacy & Security.

## What the native Mac app does

- **Hears the meeting**: what the Mac plays (a Core Audio process tap; needs only System Audio Recording Only, no screen recording), or a microphone for a talk in the room.
- **Listen (speech recognition)**: Apple on-device recognition (free, nothing uploaded), Gemini 3.5 Transcribe Live, Gemini 3.5 Live Translate (hears and translates in one), Gemini 3.5 Transcribe or OpenAI gpt-4o-mini-transcribe (sentence by sentence), OpenAI gpt-live-transcribe, your own Whisper server, or record only.
- **Translate**: Apple Translation (on-device, free), Claude Haiku / Sonnet 5.5, OpenAI gpt-6-luna / gpt-6.1-sol, Gemini 3.5 Flash-Lite / 3.8 Flash, or on the Mac **TranslateGemma 4B**, **Gemma 4 E4B** or Gemma 4 12B (Ollama, free; pick one and set it up with one click in Settings), or your own OpenAI-compatible server.
- **Which Chinese**: Traditional Chinese (Taiwan) or Simplified Chinese; the prompts, Apple Translation's target and the script of the captions all follow.
- **Reply** (⌘1): type Chinese, get the words to read aloud in the language you speak (Settings → I speak), in large text.
- **Script** (⌘2): a bilingual script with sections, cues, Q&A and copy blocks; Fill In Missing Halves adds the missing half of each line. Captions, replies and the summary all read it as context.
- **Live summary** (⌘3): at most 8 points, brought up to date every few minutes.
- **Saving** (off by default): a folder per session with the transcript, the summary and, if chosen, the recording (.m4a).
- **Speakers**: name the people in the meeting, switch who is speaking with ⌥1…⌥9, right-click a line to change it; names go into the transcript and the summary.
- **Undo** (⌘Z): Clear Captions, speaker changes and script replacements (Fill In Missing Halves, template, Open…) can be undone.
- **Segments** (⌘⇧N): start a new section; the transcript is grouped by section.
- **Usage**: estimated cost per service for this session and this month.
- **Saving money**: cloud recognition pauses in a quiet room (nothing billed) and resumes when someone speaks; listening stops after a long quiet.
- **Caption colors**: system, terminal (green or amber), Solarized, subtitles, or your own; what was said and the Chinese in two colors.
- **Interface in English, 繁體中文 and 简体中文**: follows the Mac, or chosen in Settings.

What it does not do: answer for you, synthesize your voice, join the meeting, or plug into meeting software.

## First use

1. Open the app. If macOS blocks it, choose Open Anyway in System Settings → Privacy & Security.
2. Settings (⌘,) → **Listen & Translate**:
   - Sound: "Sound the Mac plays" (online meetings) or "Microphone" (in the room).
   - Recognition: Apple on-device recognition, with the meeting language set to what others speak.
   - Translation, one of:
     - **Apple Translation**: press Check Apple Translation; if languages are missing, Open Language & Region and download English and Chinese under Translation Languages.
     - **A local model (TranslateGemma 4B or Gemma 4)**: under Local model on this Mac, pick one and press Set Up; it installs Ollama (from ollama.com, signature checked) and the model (TranslateGemma about 3.3 GB, Gemma 4 E4B about 7 GB). TranslateGemma only translates captions; Gemma 4 also does replies and summaries.
     - **Claude, OpenAI or Gemini**: enter the key under API Keys (kept in the Keychain, never in a file).
3. Back in the caption window press **Start** (⌘L). The first time it hears the Mac, macOS asks to allow System Audio Recording: allow it, then quit and reopen the app.

Replies, the summary and Fill In Missing Halves need a text model: the one chosen under Translation if it is one; with Apple Translation or TranslateGemma, the first with a key (Claude, Gemini, OpenAI), else Gemma 4 E4B.

## Services and cost

| | Option | Cost (list-price estimate) |
|---|---|---|
| Listen | Apple on-device recognition | Free; sound stays on the Mac |
| Listen | Your own Whisper server | Free |
| Listen | OpenAI gpt-4o-mini-transcribe (sentence by sentence) | About US$0.18 an hour |
| Listen | Gemini 3.5 Transcribe (sentence by sentence) | About US$0.30 an hour |
| Listen | Gemini 3.5 Transcribe Live | About US$0.54 an hour |
| Listen | OpenAI gpt-live-transcribe | About US$1.02 an hour |
| Listen + translate | Gemini 3.5 Live Translate | About US$2.2 an hour |
| Translate | Apple Translation, TranslateGemma 4B, Gemma 4 E4B / 12B, your own server | Free; text stays on your machines |
| Translate | Claude Haiku 5.5, OpenAI gpt-6-luna | About US$0.03 an hour |
| Translate | Gemini 3.5 Flash-Lite | About US$0.13 an hour |
| Translate | Gemini 3.8 Flash (slow) | About US$0.25 an hour |
| Translate | Claude Sonnet 5.5, OpenAI gpt-6.1-sol | About US$0.66 an hour |

Entirely free and offline: Apple recognition plus Apple Translation or TranslateGemma for captions, with Gemma 4 for replies and the summary. Google uses free-tier Gemini data to improve its products; use a paid-tier key for confidential meetings.

## Privacy

- **Sound**: stays on the Mac with Apple recognition; goes to Google with Gemini.
- **Caption text, script, glossary**: stay on the Mac with Apple Translation or Gemma; go to Anthropic or Google with Claude or Gemini.
- **API keys**: in the macOS Keychain, never in a file.
- **Saving**: off by default; when on, transcripts, summaries and recordings stay on your Mac. Other people's voices are kept: check that everyone agrees.
- **Network**: only the services you choose; ollama.com when you set up a local model; GitHub when you press Check for Updates. No analytics, no ads.

## Build from source

The native Mac app (Xcode 26 or later, or just the Command Line Tools: `xcode-select --install`):

```bash
git clone https://github.com/randyh0329/ownvoice-meet.git
cd ownvoice-meet/mac && ./scripts/build-app.sh
open "build/OwnVoice Meet.app"
```

The first build makes a local signing certificate in the login keychain (macOS may ask once to let codesign use it: Always Allow). Every build is then signed the same way, so macOS keeps the permissions it granted. Details in [mac/README.md](mac/README.md).

The cross-platform app (Tauri) needs Node.js 24 and Rust:

```bash
npm ci
npm run tauri dev        # development
npm run tauri build      # installer
```

## Layout

- [`mac/`](mac/): the native Mac app (Swift, SwiftUI). `mac/Core` is the tested logic (prompts, Chinese variants, script format, stream parsing), `mac/Sources/OwnVoiceMeet` the app, `mac/Resources` the translations.
- `src-tauri/`, `src/`: the cross-platform app (Rust and TypeScript).
- [`docs/`](docs/): the cross-platform app's manual and architecture notes.
- `.github/workflows/`: `mac-native.yml` (native app), `dmg.yml` (cross-platform Mac), `ci.yml`, `release.yml`.

## Origin and license

OwnVoice Meet was created by [Zaious](https://zaious.dev/) ([ChronicleCore Studio](https://studio.chroniclecore.com)); the original project is [Zaious/ownvoice-meet](https://github.com/Zaious/ownvoice-meet). This fork is maintained by [randyh0329](https://github.com/randyh0329) and adds the native Mac app and the new recognition and translation options; these changes are not the original author's: raise problems with this branch on [this fork](https://github.com/randyh0329/ownvoice-meet), not with the original project.

AI agents wrote most of the code and documentation; commits with an AI co-author trailer (`Co-Authored-By`) are visible in the git history. Translations, replies and summaries are produced on the spot by the model you choose and nobody checks them line by line: read them before you say them.

The Windows Live Captions approach is ported from SakiRinn and contributors' [LiveCaptions-Translator](https://github.com/SakiRinn/LiveCaptions-Translator) (Apache-2.0); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

License: [Apache License 2.0](LICENSE); see also [NOTICE](NOTICE) (works based on this project must keep its attribution notice).
