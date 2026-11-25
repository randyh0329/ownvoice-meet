// A finished caption line into the Chinese the user chose: on the Mac (Apple Translation), or by a
// text model (TextModels.swift) that also sees the earlier lines, the glossary and the script.

import Foundation
import NaturalLanguage
import OwnVoiceCore
import Translation

protocol Translator: Sendable {
    /// The line's Chinese; `partial` gets it as it grows (text models stream).
    func translate(_ text: String, context: [String], partial: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Usage of a text model: its pricing id and the tokens one request used.
typealias UsageReport = @Sendable (String, Tokens) -> Void

func makeTranslator(_ s: AppSettings, script: String, onUsage: @escaping UsageReport) throws -> Translator {
    switch s.translate {
    case .apple:
        return AppleTranslator(source: s.meetingLanguage, chinese: s.chinese)
    case .translateGemma:
        return TranslateGemmaTranslator(model: try makeModel(.translateGemma, s), source: s.meetingLanguage, chinese: s.chinese)
    default:
        return ModelTranslator(model: try makeTextModel(s), glossary: s.glossary, script: script, chinese: s.chinese, onUsage: onUsage)
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

    func translate(_ text: String, context: [String], partial: @escaping @Sendable (String) -> Void) async throws -> String {
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

/// A text model, with the earlier lines, the glossary and the script.
struct ModelTranslator: Translator {
    let model: TextModel
    let glossary: String
    let script: String
    let chinese: ChineseVariant
    let onUsage: UsageReport

    func translate(_ text: String, context: [String], partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let variant = chinese
        let reply = try await model.stream(
            system: Prompts.system(glossary: glossary, variant: variant),
            user: Prompts.listenUser(context: context, utterance: text, variant: variant),
            script: script,
            maxTokens: 1000
        ) { soFar in partial(variant.fix(soFar)) }
        onUsage(model.id, reply.tokens)
        return variant.fix(reply.text)
    }
}

/// TranslateGemma in Ollama, with its own one-message prompt (no context, no glossary). An empty
/// meeting language is detected per line; Chinese speech is only put into the chosen script.
struct TranslateGemmaTranslator: Translator {
    let model: TextModel
    let source: String
    let chinese: ChineseVariant

    func translate(_ text: String, context: [String], partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let src = source.isEmpty ? (NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en") : source
        if src.hasPrefix("zh") { return chinese.fix(text) }
        let variant = chinese
        let reply = try await model.stream(system: "", user: Assistants.translateGemma(text: text, sourceCode: src, variant: variant), script: "", maxTokens: 1000) { soFar in
            partial(variant.fix(soFar))
        }
        return variant.fix(reply.text)
    }
}
