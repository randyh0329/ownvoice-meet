# OwnVoice Meet（Mac 原生版分支）

**繁體中文** · [English](README.en.md)

**聽得懂會議，用自己的聲音回答。**

開線上會議或聽演講時，即時字幕把別人說的話接上中文意思；想發言時，用中文打出意思，它給你一句說得出口的外語，你照著唸。它不替你作答：話是你自己的，聲音也是你自己的。

**[下載 Mac 原生版（.dmg，Apple Silicon、macOS 26 以上）](https://github.com/randyh0329/ownvoice-meet/releases/download/mac-v0.8.0/OwnVoice-Meet-0.8.0-mac-arm64.dmg)** · [所有版本](https://github.com/randyh0329/ownvoice-meet/releases/latest) · [第一次使用](#第一次使用)

這是 [Zaious/ownvoice-meet](https://github.com/Zaious/ownvoice-meet) 的 fork（`randyh0329/ownvoice-meet`，分支 `main`；開發在 `gemini-transcribe`）。主要多了一個**用 Swift／SwiftUI 重寫的 Mac 原生版**（Apple Silicon、macOS 26 以上），放在 [`mac/`](mac/)；原本跨平台的版本（Tauri，Windows 與 macOS）留在 repo 根目錄，直到原生版的功能追上為止。

> **狀態：Mac 原生版 0.8.0（預覽）。** 在 Apple M5 上實測過：聽 Mac 的聲音、Apple 裝置上辨識、Apple 翻譯、Gemma 4、字幕顏色、存檔。0.8.0 補齊了跨平台版有、Mac 版還沒有的功能（視窗控制、在任何 app 裡都能用的快捷鍵、長句先翻、離線的 Parakeet＋SenseVoice 辨識、ChatGPT 方案、Live Translate 跟著字幕翻、麥克風檢查、議程與每段各自存檔）；這些能建置、CI 通過，還在試用中。

## 下載

| 版本 | 適用 | 從哪裡拿 |
|---|---|---|
| **Mac 原生版**（建議） | Apple Silicon（M1 以後），macOS 26 以上 | **[OwnVoice-Meet-0.8.0-mac-arm64.dmg](https://github.com/randyh0329/ownvoice-meet/releases/download/mac-v0.8.0/OwnVoice-Meet-0.8.0-mac-arm64.dmg)**（[發布頁](https://github.com/randyh0329/ownvoice-meet/releases/latest)）。打開 .dmg，把 OwnVoice Meet 拖到「應用程式」。最新的開發版在 [Actions →「Mac app (Swift)」](https://github.com/randyh0329/ownvoice-meet/actions/workflows/mac-native.yml?query=is%3Asuccess)（要登入 GitHub），或[自己建置](#從原始碼建置)。 |
| 跨平台版（Tauri），Mac | Intel 與 Apple Silicon，macOS 11 以上 | [Actions →「macOS DMG」](https://github.com/randyh0329/ownvoice-meet/actions/workflows/dmg.yml)：最新一次綠色的執行，Artifacts 的 `OwnVoice-Meet-macOS-dmg`。Mac 上只能用麥克風收音。 |
| 跨平台版，Windows | Windows 10、11 | 原作者的 [0.4.0 發布頁](https://github.com/Zaious/ownvoice-meet/releases/latest)（不含這個分支新增的功能）。 |

Actions 附的檔案保留 90 天，發布頁的檔案一直都在。下載的 app 沒有 Apple 公證，第一次打開時 macOS 會擋下：到「系統設定 → 隱私權與安全性」按「強制打開」。

## Mac 原生版做什麼

- **聽會議的聲音**：直接聽 Mac 播放的聲音（Core Audio 的 process tap，只需要「僅限系統錄音」權限，不錄螢幕），或用麥克風聽實體會場。
- **聽（語音辨識）**：Apple 裝置上辨識（免費、不上傳）、Gemini 3.5 Transcribe Live、Gemini 3.5 Live Translate（聽和翻一起做）、Gemini 3.5 Transcribe 或 OpenAI gpt-4o-mini-transcribe（一句一句）、OpenAI gpt-live-transcribe、你自己的 Whisper 伺服器、**在這台 Mac 上用 Parakeet＋SenseVoice**（免費、離線，模型約 910 MB；可以每句自動判斷中文或英文），或只錄音。術語表裡的人名和術語也會提示語音辨識。
- **翻（翻譯）**：Apple 翻譯（裝置上，免費）、Claude Haiku／Sonnet 5.5、OpenAI gpt-6-luna／gpt-6.1-sol、Gemini 3.5 Flash-Lite／3.8 Flash，或在這台 Mac 上跑的 **TranslateGemma 4B**、**Gemma 4 E4B**、Gemma 4 12B（Ollama，免費；設定裡選一個、按一下就裝好），也可以接你自己的 OpenAI 相容伺服器、用 **ChatGPT 方案**（用 ChatGPT 登入，不用 API key），或讓 **Gemini 3.5 Live Translate 跟著其他辨識的字幕翻**。長句子還沒講完就先開始翻。
- **中文要哪一種**：繁體中文（台灣）或简体中文。提示詞、Apple 翻譯的目標語言和字幕的字都跟著換。
- **回覆**（⌘1）：打中文，變成要唸的外語（設定裡選「我說的語言」），大字顯示。
- **講稿**（⌘2）：中外對照講稿，分頁、提示、問答、複製區塊；「補對照」幫你補上缺的那一半。字幕翻譯、回覆和摘要都會參考講稿。
- **即時摘要**（⌘3）：每 1 到 60 分鐘（或只在按「立即更新」時）整理成最多 8 點重點，可以另選模型。
- **會議摘要**：會議結束時（或隨時按「摘要整場會議」）把整份逐字稿交給你選的強模型（例如 Claude Opus 5.5），寫成會議紀錄：重點、決議、待辦事項、待釐清問題，存成 minutes.md。
- **存檔**（預設關閉）：每次聆聽一個資料夾，裡面是逐字稿、摘要，選了的話還有錄音（.m4a）。
- **講者**：可以**依聲音自動分辨**（在 Mac 上，免費，模型約 32 MB 下載一次）：新的聲音自動變成講者 1、2、3，在任一行按右鍵取名，這個聲音前後的每一行都會跟著改。也可以自己用 ⌥1…⌥9 切換現在誰在說話。名字寫進逐字稿和摘要。
- **復原**（⌘Z）：清除字幕、講者變更、講稿被替換（補對照、範本、開啟）都可以復原。
- **段落**（⌘⇧N，或在任何 app 裡按 ⌃⇧F9）：開始新段落，有寫**議程**就照議程命名；點段落標籤可以改名，錄音中顯示紅色 ●。每個段落也各自存一份逐字稿和錄音檔。
- **開會時**：分享螢幕時回覆和講稿視窗會隱藏；字幕視窗可以讓滑鼠點擊穿過去操作會議（⌃⇧F8，或選單列圖示）；每個視窗都有 A−／A+ 和背景透明度滑桿；**只看翻譯**只顯示翻譯；在任何 app 裡按 ⌃⇧Space 叫出回覆；聆聽時 Mac 不會睡著。
- **麥克風**：選麥克風和增益、做 6 秒麥克風檢查，聆聽時看音量條。
- **用量**：估算這次和這個月每個服務的費用。
- **省錢**：雲端辨識在安靜時自動暫停（不計費），有人說話就恢復，連同前 2 秒一起送出，第一句不會漏；安靜太久自動停止聆聽。
- **字幕顏色**：跟系統、終端機（綠色／琥珀色）、Solarized、電影字幕，或自訂顏色；原文和中文分開兩種顏色。
- **介面語言**：English、繁體中文、简体中文，跟著 Mac 或在設定裡指定。

它不做的事：不會替你回答，不合成你的聲音，不加入會議，也不是會議軟體的外掛。

## 第一次使用

1. 打開 app。第一次被擋下的話，到「系統設定 → 隱私權與安全性」按「強制打開」。
2. 打開設定（⌘,）→ **聽與翻**：
   - 聲音選「Mac 播放的聲音」（線上會議）或「麥克風」（實體會場）。
   - 辨識選「Apple 裝置上辨識」，會議語言選對方說的語言。
   - 翻譯選一個：
     - **Apple 翻譯**：按「檢查 Apple 翻譯」；缺語言包就按「打開語言與地區」，在「翻譯語言」下載英文和中文。
     - **本機模型（TranslateGemma 4B 或 Gemma 4）**：在「在這台 Mac 上跑的本機模型」選一個，按「設定」，會自動裝好 Ollama（從 ollama.com 下載，先檢查簽章）和模型（TranslateGemma 約 3.3 GB、Gemma 4 E4B 約 7 GB）。TranslateGemma 只翻字幕；Gemma 4 也能做回覆和摘要。
     - **Claude、OpenAI 或 Gemini**：到「API 金鑰」分頁填 key（存在鑰匙圈，不寫進檔案）。
3. 回到字幕視窗按 **開始**（⌘L）。第一次聽 Mac 的聲音時，macOS 會問要不要允許「系統錄音」：允許之後，結束並重新打開 app。

回覆、摘要和「補對照」需要文字模型：翻譯選了文字模型就用它；選 Apple 翻譯或 TranslateGemma 時，用第一個有 key 的（Claude、Gemini、OpenAI），都沒有就用 Gemma 4 E4B。

## 服務與費用

| | 選項 | 費用（牌價估算） |
|---|---|---|
| 聽 | Apple 裝置上辨識 | 免費，聲音不離開 Mac |
| 聽 | 你自己的 Whisper 伺服器 | 免費 |
| 聽 | 在這台 Mac 上：Parakeet＋SenseVoice | 免費，聲音不離開 Mac |
| 聽 | OpenAI gpt-4o-mini-transcribe（一句一句） | 約每小時 US$0.18 |
| 聽 | Gemini 3.5 Transcribe（一句一句） | 約每小時 US$0.30 |
| 聽 | Gemini 3.5 Transcribe Live | 約每小時 US$0.54 |
| 聽 | OpenAI gpt-live-transcribe | 約每小時 US$1.02 |
| 聽＋翻 | Gemini 3.5 Live Translate | 約每小時 US$2.2 |
| 翻 | Apple 翻譯、TranslateGemma 4B、Gemma 4 E4B／12B、你自己的伺服器 | 免費，文字不離開你的機器 |
| 翻 | ChatGPT 方案（gpt-6-luna） | 用你的 ChatGPT 方案額度，不另外計費 |
| 翻 | Claude Haiku 5.5、OpenAI gpt-6-luna | 約每小時 US$0.03 |
| 翻 | Gemini 3.5 Live Translate 跟著字幕翻 | 約每小時 US$2.2 |
| 翻 | Gemini 3.5 Flash-Lite | 約每小時 US$0.13 |
| 翻 | Gemini 3.8 Flash（較慢） | 約每小時 US$0.25 |
| 翻 | Claude Sonnet 5.5、OpenAI gpt-6.1-sol | 約每小時 US$0.66 |

完全免費、完全不連網的組合：Apple 裝置上辨識＋Apple 翻譯或 TranslateGemma（字幕），回覆和摘要用 Gemma 4。Gemini 的免費層資料會被 Google 用來改進產品，機密會議請用付費層的 key。

## 隱私

- **聲音**：選 Apple 辨識時不離開 Mac；選 Gemini 時送到 Google。
- **字幕文字、講稿、術語表**：選 Apple 翻譯或 Gemma 時不離開 Mac；選 Claude 或 Gemini 時送到 Anthropic 或 Google。
- **API key**：存在 macOS 的鑰匙圈，不寫進檔案。
- **存檔**：預設關閉；打開後逐字稿、摘要和錄音只存在你的 Mac 上。會留下別人的聲音，請先確認大家同意。
- **網路連線**：只連你選的服務；設定本機模型時從 ollama.com 下載 Ollama 和模型；下載裝置上辨識模型時連 Hugging Face；用 ChatGPT 登入時連 OpenAI；按「檢查更新」時問 GitHub。沒有統計、沒有廣告。

## 從原始碼建置

Mac 原生版（需要 Xcode 26 以上，或只裝 Command Line Tools：`xcode-select --install`）：

```bash
git clone https://github.com/randyh0329/ownvoice-meet.git
cd ownvoice-meet/mac && ./scripts/build-app.sh
open "build/OwnVoice Meet.app"
```

第一次建置時會在登入鑰匙圈建立一個本機簽章憑證（macOS 可能問一次是否允許 codesign 使用：選「永遠允許」）。之後每次建置的簽章都一樣，系統給的權限就不會一直重問。細節見 [mac/README.md](mac/README.md)。

跨平台版（Tauri）需要 Node.js 24 和 Rust：

```bash
npm ci
npm run tauri dev        # 開發模式
npm run tauri build      # 安裝檔
```

## 專案結構

- [`mac/`](mac/)：Mac 原生版（Swift、SwiftUI）。`mac/Core` 是可測試的邏輯（提示詞、中文變體、講稿格式、串流解析），`mac/Sources/OwnVoiceMeet` 是 app，`mac/Resources` 有翻譯檔。
- `src-tauri/`、`src/`：跨平台版（Rust 與 TypeScript）。
- [`docs/`](docs/)：跨平台版的使用手冊與架構說明。
- `.github/workflows/`：`mac-native.yml`（原生版）、`dmg.yml`（跨平台版 Mac）、`ci.yml`、`release.yml`。

## 來源與授權

OwnVoice Meet 由 [Zaious](https://zaious.dev/)（[ChronicleCore Studio](https://studio.chroniclecore.com) 編年史記工作室）創作，原始專案在 [Zaious/ownvoice-meet](https://github.com/Zaious/ownvoice-meet)。這個 fork 由 [randyh0329](https://github.com/randyh0329) 維護，加上了 Mac 原生版和新的辨識、翻譯選項；這些修改不是原作者做的：這個分支的問題請找 [這個 fork](https://github.com/randyh0329/ownvoice-meet)，不要回報給原專案。

程式與文件大部分由 AI agent 撰寫，帶有 AI 共同作者標記（`Co-Authored-By`）的 commit 可以在 git 歷史裡查到。翻譯、回覆和摘要是你選的模型當場產生的，沒有人逐句查過；照著唸之前請自己看一眼。

Windows 即時輔助字幕的做法移植自 SakiRinn 與貢獻者的 [LiveCaptions-Translator](https://github.com/SakiRinn/LiveCaptions-Translator)（Apache-2.0），見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

授權：[Apache License 2.0](LICENSE)，另見 [NOTICE](NOTICE)（以本專案為基礎的作品須保留其中的署名聲明）。
