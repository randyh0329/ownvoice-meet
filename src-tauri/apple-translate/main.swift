// The Mac's own translation (Apple's Translation framework) for OwnVoice Meet: a helper the app
// starts on macOS 26 or later and talks to over stdin/stdout, one JSON object per line.
//   {"op":"status","source":"en-US"}             -> {"ok":true,"status":"installed|supported|unsupported","target":"zh-Hant-TW",...}
//   {"op":"translate","text":"…","source":""}    -> {"ok":true,"text":"…"} or {"ok":false,"error":"…"}
// An empty source means: detect it (NaturalLanguage). Speech already in Chinese comes back as it is.
// The target is the first of zh-Hant-TW, zh-TW, zh-Hant the system offers for that source.
// `--self-check` prints {"sdk26":…,"macos26":…} and exits: CI checks the helper was built with the
// macOS 26 SDK, whose TranslationSession(installedSource:target:) works outside SwiftUI.
// Built by build.rs (swiftc, both architectures), bundled by Tauri as a sidecar (tauri.macos.conf.json).

import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

let targets = ["zh-Hant-TW", "zh-TW", "zh-Hant"]

#if compiler(>=6.2) && canImport(Translation)
let sdk26 = true
#else
let sdk26 = false
#endif

func macOS26() -> Bool {
    if #available(macOS 26, *) { return true }
    return false
}

func reply(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// The language of `text` by NaturalLanguage (en, ja, zh-Hant…), nil when it cannot tell.
func detect(_ text: String) -> String? {
    NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
}

#if compiler(>=6.2) && canImport(Translation)
@available(macOS 26, *)
final class Translator {
    /// One session per source language; a failed one is dropped and made again.
    var sessions: [String: TranslationSession] = [:]

    /// The best Chinese target for `source`, installed first, then one that can be downloaded.
    func pickTarget(from source: Locale.Language) async -> (String, LanguageAvailability.Status) {
        let availability = LanguageAvailability()
        var supported: String? = nil
        for id in targets {
            let status = await availability.status(from: source, to: Locale.Language(identifier: id))
            if status == .installed { return (id, status) }
            if status == .supported && supported == nil { supported = id }
        }
        if let id = supported { return (id, .supported) }
        return (targets[0], .unsupported)
    }

    func status(source: String) async -> [String: Any] {
        let src = source.isEmpty ? "en" : source
        let (target, status) = await pickTarget(from: Locale.Language(identifier: src))
        let name: String
        switch status {
        case .installed: name = "installed"
        case .supported: name = "supported"
        default: name = "unsupported"
        }
        return ["ok": true, "status": name, "source": src, "target": target]
    }

    func translate(_ text: String, source: String) async -> [String: Any] {
        let src = source.isEmpty ? (detect(text) ?? "en") : source
        if src.hasPrefix("zh") {
            return ["ok": true, "text": text]
        }
        do {
            let session: TranslationSession
            if let existing = sessions[src] {
                session = existing
            } else {
                let language = Locale.Language(identifier: src)
                let (target, status) = await pickTarget(from: language)
                switch status {
                case .installed: break
                case .supported:
                    return ["ok": false, "error": "語言包還沒下載（\(src) → \(target)）：到「系統設定 → 一般 → 語言與地區 → 翻譯語言」下載"]
                default:
                    return ["ok": false, "error": "Apple 翻譯不支援 \(src) → 中文"]
                }
                session = TranslationSession(installedSource: language, target: Locale.Language(identifier: target))
                sessions[src] = session
            }
            let response = try await session.translate(text)
            return ["ok": true, "text": response.targetText]
        } catch {
            sessions[src] = nil
            return ["ok": false, "error": "Apple 翻譯失敗：\(error.localizedDescription)"]
        }
    }
}
#endif

/// The Translator, made on first use (a stored global cannot be marked macOS 26 only).
var translatorBox: AnyObject? = nil

func handle(_ req: [String: Any]) async -> [String: Any] {
    let op = req["op"] as? String ?? ""
    let source = req["source"] as? String ?? ""
    #if compiler(>=6.2) && canImport(Translation)
    if #available(macOS 26, *) {
        let translator: Translator
        if let t = translatorBox as? Translator {
            translator = t
        } else {
            translator = Translator()
            translatorBox = translator
        }
        switch op {
        case "status":
            var s = await translator.status(source: source)
            s["sdk26"] = sdk26
            s["macos26"] = true
            return s
        case "translate":
            return await translator.translate(req["text"] as? String ?? "", source: source)
        default:
            return ["ok": false, "error": "unknown op \(op)"]
        }
    }
    #endif
    let why = sdk26 ? "Apple 翻譯需要 macOS 26 以上" : "這一版沒有用 macOS 26 SDK 建置，Apple 翻譯無法使用"
    return ["ok": false, "error": why, "sdk26": sdk26, "macos26": macOS26()]
}

/// Lets the async answer cross back to the reading thread.
final class Box {
    var value: [String: Any] = [:]
}

if CommandLine.arguments.contains("--self-check") {
    reply(["sdk26": sdk26, "macos26": macOS26()])
    exit(0)
}

// Requests are read and answered one at a time on a thread of their own; the main thread keeps a
// dispatch loop for the framework. End of input (the app quit) ends the helper.
Thread.detachNewThread {
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            reply(["ok": false, "error": "bad request"])
            continue
        }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await handle(req)
            done.signal()
        }
        done.wait()
        var out = box.value
        if let id = req["id"] { out["id"] = id }
        reply(out)
    }
    exit(0)
}
dispatchMain()
