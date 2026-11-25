// Request bodies and answers for the text models: Anthropic's Messages API, and the OpenAI-style
// Chat Completions that Gemini (its OpenAI-compatible endpoint) and Ollama also serve.

import Foundation

public struct ServiceError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Requests {
    public static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let geminiCompatURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    public static let ollamaURL = URL(string: "http://localhost:11434/v1/chat/completions")!
    public static let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// `effort`: the lowest thinking setting the model takes ("" leaves the default). `script`: the
    /// prepared script, sent as its own cached block after the instructions (it is the same on
    /// every call).
    /// `fallbacks`: let the API re-run a declined request on another model inside the same call
    /// (Opus 5.5, Fable 5.2, Sonnet 5.5; needs the server-side-fallback-2026-07-01 beta header).
    public static func anthropicBody(model: String, system: String, user: String, effort: String, script: String = "", stream: Bool = false, maxTokens: Int = 1000, fallbacks: Bool = false) throws -> Data {
        var blocks: [[String: Any]] = [["type": "text", "text": system]]
        if let block = Assistants.scriptBlock(script) {
            blocks.append(["type": "text", "text": block, "cache_control": ["type": "ephemeral"]])
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": blocks,
            "messages": [["role": "user", "content": user]],
        ]
        if stream { body["stream"] = true }
        if !effort.isEmpty { body["output_config"] = ["effort": effort] }
        if fallbacks { body["fallbacks"] = "default" }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// Chat Completions has no cache marks: the script joins the system message.
    public static func chatBody(model: String, system: String, user: String, effort: String, script: String = "", stream: Bool = false) throws -> Data {
        let full = [system, Assistants.scriptBlock(script)].compactMap { $0 }.joined(separator: "\n\n")
        // TranslateGemma takes a single user message: no system message when there is none.
        let messages: [[String: Any]] = full.isEmpty ? [["role": "user", "content": user]] : [["role": "system", "content": full], ["role": "user", "content": user]]
        var body: [String: Any] = ["model": model, "messages": messages]
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        if !effort.isEmpty { body["reasoning_effort"] = effort }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The text of a Messages API answer.
    public static func anthropicText(_ data: Data, status: Int) throws -> String {
        let v = try object(data, status: status)
        let parts = (v["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text of a Chat Completions answer.
    public static func chatText(_ data: Data, status: Int) throws -> String {
        let v = try object(data, status: status)
        let message = ((v["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        return (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON answer, or the service's own error message.
    public static func object(_ data: Data, status: Int) throws -> [String: Any] {
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), let v else {
            let error = v?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw ServiceError("\(status)：\(message)")
        }
        return v
    }
}
