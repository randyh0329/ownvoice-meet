// The text models behind captions, replies, the summary and 補對照, streamed: Claude through
// Anthropic's Messages API; OpenAI, Gemini (its OpenAI-compatible endpoint), Ollama on this Mac and
// the user's own server through Chat Completions; the ChatGPT plan through the Responses API. `onText` gets the whole text so far as it grows;
// the reply carries the tokens used.

import Foundation
import Observation
import OwnVoiceCore

/// A model's answer and what it used (for the usage record).
struct ModelReply: Sendable {
    let text: String
    let tokens: Tokens
}

protocol TextModel: Sendable {
    /// The pricing id (Usage.swift).
    var id: String { get }
    var name: String { get }
    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> ModelReply
}

enum Provider {
    case anthropic, openai, gemini, ollama, local
    /// Sign in with ChatGPT: the user's plan, no key (ChatGPTSignIn.swift).
    case chatgpt
}

/// One text model: who serves it, its name there, the lowest thinking setting it takes.
struct ModelSpec {
    let id: String
    let name: String
    let provider: Provider
    let apiModel: String
    let effort: String
    /// Claude 5.5-generation models: a declined request is re-run on another model in the same call.
    var fallbacks = false

    static let haiku = ModelSpec(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", provider: .anthropic, apiModel: "claude-haiku-5-5", effort: "low")
    static let sonnet = ModelSpec(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: .anthropic, apiModel: "claude-sonnet-5-5", effort: "low", fallbacks: true)
    // Thinking cannot be turned off on Opus 5.5 (its default effort is medium); Fable 5.2 is best
    // started at high.
    static let opus = ModelSpec(id: "claude-opus-5-5", name: "Claude Opus 5.5", provider: .anthropic, apiModel: "claude-opus-5-5", effort: "medium", fallbacks: true)
    static let fable = ModelSpec(id: "claude-fable-5-2", name: "Claude Fable 5.2", provider: .anthropic, apiModel: "claude-fable-5-2", effort: "high", fallbacks: true)
    static let luna = ModelSpec(id: "gpt-6-luna", name: "OpenAI gpt-6-luna", provider: .openai, apiModel: "gpt-6-luna", effort: "none")
    // gpt-6.1-sol rejects "none" (checked against the API 2026-10-17).
    static let sol = ModelSpec(id: "gpt-6.1-sol", name: "OpenAI gpt-6.1-sol", provider: .openai, apiModel: "gpt-6.1-sol", effort: "low")
    static let flashLite = ModelSpec(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", provider: .gemini, apiModel: "gemini-3.5-flash-lite", effort: "minimal")
    // Gemini 3.8 Flash rejects "minimal" (checked 2026-10-17).
    static let flash = ModelSpec(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", provider: .gemini, apiModel: "gemini-3.8-flash", effort: "low")
    // Ollama maps "none" to thinking off for Gemma 4.
    static let gemma = ModelSpec(id: "gemma4-e4b", name: "Gemma 4 E4B", provider: .ollama, apiModel: "gemma4:e4b", effort: "none")
    static let gemma12 = ModelSpec(id: "gemma4-12b", name: "Gemma 4 12B", provider: .ollama, apiModel: "gemma4:12b", effort: "none")
    // Qwen3 thinks before answering unless told not to; Ollama maps "none" to thinking off.
    static let qwen3 = ModelSpec(id: "qwen3-1.7b", name: "Qwen3 1.7B", provider: .ollama, apiModel: "qwen3:1.7b", effort: "none")
    static let translateGemma = ModelSpec(id: "translategemma-4b", name: "TranslateGemma 4B", provider: .ollama, apiModel: "translategemma:4b", effort: "")
    // gpt-6-luna on the user's ChatGPT plan; the pricing id counts it as free (the plan pays).
    static let chatgpt = ModelSpec(id: "chatgpt-luna", name: String(localized: "ChatGPT plan (gpt-6-luna)"), provider: .chatgpt, apiModel: "gpt-6-luna", effort: "none")
}

extension TranslateOption {
    /// The general text model this option is, if it is one (not Apple Translation or TranslateGemma,
    /// which only translate caption lines). Live Translate takes sound only: its text model, for the
    /// lines it misses, replies and the summary, is Gemini 3.5 Flash-Lite on the same key.
    var textModel: ModelSpec? {
        switch self {
        case .haiku: .haiku
        case .sonnet: .sonnet
        case .luna: .luna
        case .chatgpt: .chatgpt
        case .sol: .sol
        case .geminiFlashLite: .flashLite
        case .geminiFlash: .flash
        case .geminiLiveTranslate: .flashLite
        case .gemma: .gemma
        case .gemma12: .gemma12
        case .qwen3: .qwen3
        case .localServer: ModelSpec(id: "local", name: String(localized: "Your own server"), provider: .local, apiModel: "", effort: "")
        case .apple, .translateGemma: nil
        }
    }
}

/// The model the summaries use: one chosen in Settings, or (auto) the text model.
func makeSummaryModel(_ choice: SummaryModelChoice, _ s: AppSettings) throws -> TextModel {
    guard let spec = choice.spec else { return try makeTextModel(s) }
    return try makeModel(spec, s)
}

/// The model for text jobs (replies, the summary, 補對照, and captions with a text model). Under 翻,
/// a text model is itself; with Apple Translation or TranslateGemma (which only translate caption
/// lines) it is the first model there is a key (or a ChatGPT sign-in) for, else Gemma 4 E4B in Ollama.
func makeTextModel(_ s: AppSettings) throws -> TextModel {
    if let spec = s.translate.textModel { return try makeModel(spec, s) }
    if Keychain.get("anthropic") != nil { return try makeModel(.haiku, s) }
    if Keychain.get("gemini") != nil { return try makeModel(.flashLite, s) }
    if Keychain.get("openai") != nil { return try makeModel(.luna, s) }
    if ChatGPTStore.load() != nil { return try makeModel(.chatgpt, s) }
    return try makeModel(.gemma, s)
}

func makeModel(_ spec: ModelSpec, _ s: AppSettings) throws -> TextModel {
    func key(_ provider: String, _ missing: String) throws -> String {
        guard let k = Keychain.get(provider) else { throw AppError(missing) }
        return k
    }
    switch spec.provider {
    case .anthropic:
        return AnthropicModel(id: spec.id, key: try key("anthropic", String(localized: "Add an Anthropic API key in Settings first.")), model: spec.apiModel, effort: spec.effort, name: spec.name, fallbacks: spec.fallbacks)
    case .openai:
        return ChatModel(id: spec.id, url: Requests.openAIURL, key: try key("openai", String(localized: "Add an OpenAI API key in Settings first.")), model: spec.apiModel, effort: spec.effort, name: spec.name)
    case .gemini:
        return ChatModel(id: spec.id, url: Requests.geminiCompatURL, key: try key("gemini", String(localized: "Add a Gemini API key in Settings first.")), model: spec.apiModel, effort: spec.effort, name: spec.name)
    case .ollama:
        return ChatModel(id: spec.id, url: Requests.ollamaURL, key: nil, model: spec.apiModel, effort: spec.effort, name: spec.name)
    case .local:
        let base = s.localServerURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), !base.isEmpty, !s.localServerModel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AppError(String(localized: "Your own server: fill in its address and model name in Settings first."))
        }
        return ChatModel(id: spec.id, url: url, key: Keychain.get("local"), model: s.localServerModel.trimmingCharacters(in: .whitespaces), effort: "", name: spec.name)
    case .chatgpt:
        guard ChatGPTStore.load() != nil else { throw AppError(ChatGPTPlan.Failure.notConnectedMessage) }
        return ChatGPTPlanModel(id: spec.id, model: spec.apiModel, effort: spec.effort, name: spec.name)
    }
}

struct AnthropicModel: TextModel {
    let id: String
    let key: String
    let model: String
    let effort: String
    let name: String
    var fallbacks = false

    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> ModelReply {
        var req = URLRequest(url: Requests.anthropicURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallbacks { req.setValue(Requests.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try Requests.anthropicBody(model: model, system: system, user: user, effort: effort, script: script, stream: true, maxTokens: maxTokens, fallbacks: fallbacks)
        return try await read(req, format: .anthropic, failure: Requests.anthropicText, onText: onText)
    }
}

struct ChatModel: TextModel {
    let id: String
    let url: URL
    let key: String?
    let model: String
    let effort: String
    let name: String

    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> ModelReply {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = try Requests.chatBody(model: model, system: system, user: user, effort: effort, script: script, stream: true)
        do {
            return try await read(req, format: .chat, failure: Requests.chatText, onText: onText)
        } catch let error as URLError where url == Requests.ollamaURL && error.code == .cannotConnectToHost {
            throw AppError(String(localized: "The local model is not set up yet: Settings → Listen & Translate → Local model on this Mac → Set Up."))
        }
    }
}

/// The ChatGPT plan through the Responses API (Sign in with ChatGPT): the access token is fetched,
/// and refreshed when it is about to expire, for each request. The plan takes no output limit, so
/// `maxTokens` is not sent; a refusal is put into words the user can act on.
struct ChatGPTPlanModel: TextModel {
    let id: String
    let model: String
    let effort: String
    let name: String

    func stream(system: String, user: String, script: String, maxTokens: Int, onText: @escaping @Sendable (String) -> Void) async throws -> ModelReply {
        let token = try await ChatGPTTokens.shared.access()
        var req = URLRequest(url: ChatGPTPlan.responsesURL, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.httpBody = try ChatGPTPlan.requestBody(model: model, effort: effort, system: system, user: user, script: script)
        do {
            return try await read(req, format: .responses, failure: { data, status in throw ChatGPTPlan.failure(status: status, body: data) }, onText: onText)
        } catch let failure as ChatGPTPlan.Failure {
            throw AppError(failure.message)
        }
    }
}

/// Reads a server-sent event stream; a refused request is read whole for the service's own message.
private func read(
    _ req: URLRequest,
    format: Streaming.Format,
    failure: (Data, Int) throws -> String,
    onText: @escaping @Sendable (String) -> Void
) async throws -> ModelReply {
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        _ = try failure(body, status)
        throw ServiceError("\(status)")
    }
    var reply = StreamedReply(format)
    for try await line in bytes.lines {
        if try reply.read(line) { onText(reply.text) }
        // Chat Completions sends its usage after the last text and before [DONE]; Anthropic's
        // message_stop comes after message_delta. Either way the usage is in by now.
        if reply.finished { break }
    }
    // A reply cut off at its length limit (thinking can use most of it) is not taken as whole.
    if reply.truncated {
        throw AppError(String(localized: "The reply was cut off at its length limit; try again."))
    }
    return ModelReply(text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines), tokens: reply.tokens)
}

/// Settings' Test Connection for one of the user's own servers: asks it for its models (with the
/// "Your own server's key" if one is saved) and says whether it answered, and with which models.
@MainActor
@Observable
final class ServerProbe {
    private(set) var working = false
    private(set) var message = ""
    private(set) var failed = false
    /// The model names the server listed, offered in a menu to fill in the model field.
    private(set) var models: [String] = []

    func test(base: String) async {
        guard !working else { return }
        reset()
        guard let url = ServerModels.url(base: base) else {
            show(String(localized: "Fill in the server's address first, such as http://localhost:8000/v1."), failed: true)
            return
        }
        working = true
        defer { working = false }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let key = Keychain.get("local") { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let found = try ServerModels.ids(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            models = found
            switch found.count {
            case 0: show(String(localized: "✓ Connected, but the server lists no models."), failed: false)
            case 1: show(String(localized: "✓ Connected: 1 model"), failed: false)
            default: show(String(localized: "✓ Connected: \(String(found.count)) models"), failed: false)
            }
        } catch is ServerModels.NotAList {
            show(String(localized: "The server answered, but not with a list of models: check the address (it usually ends in /v1)."), failed: true)
        } catch {
            show(error.localizedDescription, failed: true)
        }
    }

    /// The address changed: what was found no longer applies.
    func reset() {
        message = ""
        failed = false
        models = []
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}
