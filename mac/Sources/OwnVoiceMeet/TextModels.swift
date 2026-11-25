// The text models behind captions, replies, the summary and 補對照, streamed: Claude through
// Anthropic's Messages API, Gemini and Gemma through Chat Completions (Gemini's OpenAI-compatible
// endpoint, Ollama on this Mac). `onText` gets the whole text so far as it grows.

import Foundation
import OwnVoiceCore

protocol TextModel: Sendable {
    var name: String { get }
    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> String
}

/// The model for text jobs. Under 翻, a text model is itself; with Apple Translation chosen (which
/// only translates caption lines) it is the first model there is a key for, else Gemma in Ollama.
func makeTextModel(_ s: AppSettings) throws -> TextModel {
    switch s.translate {
    case .haiku: return try haiku()
    case .geminiFlashLite: return try flashLite()
    case .gemma: return gemma()
    case .apple:
        if Keychain.get("anthropic") != nil { return try haiku() }
        if Keychain.get("gemini") != nil { return try flashLite() }
        return gemma()
    }
}

private func haiku() throws -> TextModel {
    guard let key = Keychain.get("anthropic") else { throw AppError(String(localized: "Add an Anthropic API key in Settings first.")) }
    return AnthropicModel(key: key, model: "claude-haiku-5-5", effort: "low", name: "Claude Haiku 5.5")
}

private func flashLite() throws -> TextModel {
    guard let key = Keychain.get("gemini") else { throw AppError(String(localized: "Add a Gemini API key in Settings first.")) }
    return ChatModel(url: Requests.geminiCompatURL, key: key, model: "gemini-3.5-flash-lite", effort: "minimal", name: "Gemini 3.5 Flash-Lite")
}

private func gemma() -> TextModel {
    ChatModel(url: Requests.ollamaURL, key: nil, model: "gemma4:e4b", effort: "none", name: "Gemma 4 E4B")
}

struct AnthropicModel: TextModel {
    let key: String
    let model: String
    let effort: String
    let name: String

    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var req = URLRequest(url: Requests.anthropicURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try Requests.anthropicBody(model: model, system: system, user: user, effort: effort, script: script, stream: true, maxTokens: maxTokens)
        return try await read(req, parse: Streaming.anthropic, failure: Requests.anthropicText, onText: onText)
    }
}

struct ChatModel: TextModel {
    let url: URL
    let key: String?
    let model: String
    let effort: String
    let name: String

    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = try Requests.chatBody(model: model, system: system, user: user, effort: effort, script: script, stream: true)
        do {
            return try await read(req, parse: Streaming.chat, failure: Requests.chatText, onText: onText)
        } catch let error as URLError where url == Requests.ollamaURL && error.code == .cannotConnectToHost {
            throw AppError(String(localized: "Gemma 4 is not set up yet: Settings → Listen & Translate → Set Up Gemma 4."))
        }
    }
}

/// Reads a server-sent event stream; a refused request is read whole for the service's own message.
private func read(
    _ req: URLRequest,
    parse: (String) -> StreamEvent?,
    failure: (Data, Int) throws -> String,
    onText: @escaping @Sendable (String) -> Void
) async throws -> String {
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        _ = try failure(body, status)
        throw ServiceError("\(status)")
    }
    var text = ""
    for try await line in bytes.lines {
        switch parse(line) {
        case .text(let t)?:
            text += t
            onText(text)
        case .done?:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .error(let message)?:
            throw ServiceError(message)
        case nil:
            continue
        }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
