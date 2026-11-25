// A finished caption line into the Chinese the user chose: on the Mac (Apple Translation), or by a
// text model (Claude Haiku, Gemini Flash-Lite, Gemma 4 in a local Ollama) that also sees the
// earlier lines and the glossary.

import Foundation
import NaturalLanguage
import OwnVoiceCore
import Translation

protocol Translator: Sendable {
    func translate(_ text: String, context: [String]) async throws -> String
}

func makeTranslator(_ s: AppSettings) throws -> Translator {
    switch s.translate {
    case .apple:
        return AppleTranslator(source: s.meetingLanguage, chinese: s.chinese)
    case .haiku:
        guard let key = Keychain.get("anthropic") else { throw AppError(String(localized: "Add an Anthropic API key in Settings first.")) }
        return AnthropicTranslator(key: key, model: "claude-haiku-5-5", effort: "low", glossary: s.glossary, chinese: s.chinese)
    case .geminiFlashLite:
        guard let key = Keychain.get("gemini") else { throw AppError(String(localized: "Add a Gemini API key in Settings first.")) }
        return ChatTranslator(url: Requests.geminiCompatURL, key: key, model: "gemini-3.5-flash-lite", effort: "minimal", glossary: s.glossary, chinese: s.chinese)
    case .gemma:
        return ChatTranslator(url: Requests.ollamaURL, key: nil, model: "gemma4:e4b", effort: "none", glossary: s.glossary, chinese: s.chinese)
    }
}

// MARK: - Apple Translation

/// macOS 26's TranslationSession, one per source language, toward the first of the variant's
/// targets the system offers. An empty meeting language is detected per line; Chinese speech is
/// only put into the chosen script.
actor AppleTranslator: Translator {
    private let source: String
    private let chinese: ChineseVariant
    private var sessions: [String: TranslationSession] = [:]

    init(source: String, chinese: ChineseVariant) {
        self.source = source
        self.chinese = chinese
    }

    func translate(_ text: String, context: [String]) async throws -> String {
        let src = source.isEmpty ? (NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en") : source
        if src.hasPrefix("zh") { return chinese.fix(text) }
        let session = try await session(for: src)
        do {
            return chinese.fix(try await session.translate(text).targetText)
        } catch {
            sessions[src] = nil
            throw error
        }
    }

    private func session(for src: String) async throws -> TranslationSession {
        if let s = sessions[src] { return s }
        let language = Locale.Language(identifier: src)
        let (target, status) = await Self.target(from: language, chinese: chinese)
        switch status {
        case .installed: break
        case .supported: throw AppError(String(localized: "Apple Translation languages are not downloaded yet: System Settings → General → Language & Region → Translation Languages."))
        default: throw AppError(String(localized: "Apple Translation does not translate \(src) into this Chinese."))
        }
        let s = TranslationSession(installedSource: language, target: Locale.Language(identifier: target))
        sessions[src] = s
        return s
    }

    /// The best target for `source`: installed first, then one that can be downloaded.
    static func target(from source: Locale.Language, chinese: ChineseVariant) async -> (String, LanguageAvailability.Status) {
        let availability = LanguageAvailability()
        var supported: String?
        for id in chinese.appleTargets {
            let status = await availability.status(from: source, to: Locale.Language(identifier: id))
            if status == .installed { return (id, status) }
            if status == .supported, supported == nil { supported = id }
        }
        if let id = supported { return (id, .supported) }
        return (chinese.appleTargets[0], .unsupported)
    }
}

// MARK: - Text models

struct AnthropicTranslator: Translator {
    let key: String
    let model: String
    let effort: String
    let glossary: String
    let chinese: ChineseVariant

    func translate(_ text: String, context: [String]) async throws -> String {
        var req = URLRequest(url: Requests.anthropicURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try Requests.anthropicBody(
            model: model,
            system: Prompts.system(glossary: glossary, variant: chinese),
            user: Prompts.listenUser(context: context, utterance: text, variant: chinese),
            effort: effort
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        return chinese.fix(try Requests.anthropicText(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0))
    }
}

/// Chat Completions: Gemini's OpenAI-compatible endpoint, or Ollama on this Mac.
struct ChatTranslator: Translator {
    let url: URL
    let key: String?
    let model: String
    let effort: String
    let glossary: String
    let chinese: ChineseVariant

    func translate(_ text: String, context: [String]) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = try Requests.chatBody(
            model: model,
            system: Prompts.system(glossary: glossary, variant: chinese),
            user: Prompts.listenUser(context: context, utterance: text, variant: chinese),
            effort: effort
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return chinese.fix(try Requests.chatText(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        } catch let error as URLError where url == Requests.ollamaURL && error.code == .cannotConnectToHost {
            throw AppError(String(localized: "Ollama is not running: install it from ollama.com and open it once."))
        }
    }
}
