// Server-sent events from the text models, one `data:` line at a time: Anthropic's Messages API
// (content_block_delta text) and Chat Completions (choices[0].delta.content, ending with [DONE]),
// which Gemini's OpenAI-compatible endpoint, Ollama and OpenAI all send. Gemini puts its usage in
// the chunk with the last text, so one line can carry two events; Gemini's own format
// (candidates, usageMetadata) is read too. The Responses API (the ChatGPT plan, ChatGPTPlan.swift)
// sends response.output_text.delta, then response.completed with the usage; its failures are thrown
// as ChatGPTPlan.Failure.
//
// Usage: Anthropic's cache writes (cache_creation_input_tokens) count as input, since the prices
// have no rate of their own for them (a write costs a little more than input, so the total runs
// slightly low); cache reads count as cached. Gemini's thinking tokens count as output.
//
// Why the model stopped: Anthropic's message_delta stop_reason, Chat Completions' finish_reason,
// Gemini's finishReason. A reply cut off at its token limit (max_tokens, length) is not whole.

import Foundation

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case usage(Tokens)
    case done
    case error(String)
}

public enum Streaming {
    public enum Format: Sendable {
        case anthropic
        case chat
        case responses
    }

    /// The first event of a Messages API line (see `events` for all of them).
    public static func anthropic(_ line: String) -> StreamEvent? {
        events(line, format: .anthropic).first
    }

    /// The first event of a Chat Completions line: its text when it has some (see `events` for the
    /// usage that may come in the same line).
    public static func chat(_ line: String) -> StreamEvent? {
        events(line, format: .chat).first
    }

    /// Every event in one line, text before usage.
    public static func events(_ line: String, format: Format) -> [StreamEvent] {
        switch format {
        case .anthropic: anthropicEvents(line)
        case .chat: chatEvents(line)
        case .responses: responsesEvents(line)
        }
    }

    /// Why the model stopped, when this line says: "end_turn", "max_tokens" (Anthropic), "stop",
    /// "length" (Chat Completions), "STOP", "MAX_TOKENS" (Gemini).
    public static func stopReason(_ line: String, format: Format) -> String? {
        guard let v = object(line) else { return nil }
        switch format {
        case .anthropic:
            guard v["type"] as? String == "message_delta" else { return nil }
            return (v["delta"] as? [String: Any])?["stop_reason"] as? String
        case .chat:
            if let r = (v["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String { return r }
            return (v["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
        case .responses:
            // An unfinished reply is a failure of its own (ChatGPTPlan.streamFailure).
            return nil
        }
    }

    /// Whether a reply that stopped for `reason` was cut off at its token limit.
    public static func isTruncated(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return ["max_tokens", "length", "MAX_TOKENS", "model_context_window_exceeded"].contains(reason)
    }

    static func anthropicEvents(_ line: String) -> [StreamEvent] {
        guard let v = object(line) else { return [] }
        switch v["type"] as? String {
        case "message_start":
            return [.usage(anthropicTokens((v["message"] as? [String: Any])?["usage"] as? [String: Any], output: false))]
        case "message_delta":
            // The usage so far, the input again on newer API versions.
            return [.usage(anthropicTokens(v["usage"] as? [String: Any], output: true))]
        case "content_block_delta":
            let delta = v["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String else { return [] }
            return [.text(t)]
        case "message_stop":
            return [.done]
        case "error":
            return [.error((v["error"] as? [String: Any])?["message"] as? String ?? "error")]
        default:
            return []
        }
    }

    /// message_start's output_tokens is a placeholder; message_delta has the real count.
    static func anthropicTokens(_ u: [String: Any]?, output: Bool) -> Tokens {
        Tokens(input: n(u, "input_tokens") + n(u, "cache_creation_input_tokens"),
               cached: n(u, "cache_read_input_tokens"),
               output: output ? n(u, "output_tokens") : 0)
    }

    static func chatEvents(_ line: String) -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        if line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]" { return [.done] }
        guard let v = object(line) else { return [] }
        if let e = v["error"] as? [String: Any] { return [.error(e["message"] as? String ?? "error")] }
        var events: [StreamEvent] = []
        let delta = (v["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
        if let t = delta?["content"] as? String, !t.isEmpty { events.append(.text(t)) }
        // Gemini's own format: candidates[0].content.parts[].text (thoughts left out).
        let parts = ((v["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let geminiText = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        if !geminiText.isEmpty { events.append(.text(geminiText)) }
        // stream_options.include_usage: OpenAI sends it in a last chunk of its own, Gemini with the
        // last text. Gemini leaves its thinking out of completion_tokens yet counts it in
        // total_tokens, so the output is whatever the total has beyond the prompt.
        if let u = v["usage"] as? [String: Any] {
            let cached = n(u["prompt_tokens_details"] as? [String: Any], "cached_tokens")
            let prompt = n(u, "prompt_tokens")
            let output = max(n(u, "completion_tokens"), n(u, "total_tokens") - prompt)
            events.append(.usage(Tokens(input: max(0, prompt - cached), cached: cached, output: output)))
        }
        if let u = v["usageMetadata"] as? [String: Any] {
            let cached = n(u, "cachedContentTokenCount")
            events.append(.usage(Tokens(input: max(0, n(u, "promptTokenCount") - cached), cached: cached,
                                        output: n(u, "candidatesTokenCount") + n(u, "thoughtsTokenCount"))))
        }
        return events
    }

    /// The Responses API: text deltas, and the usage once the response is complete (its input
    /// tokens include the cached ones). Failures are read by ChatGPTPlan.streamFailure.
    static func responsesEvents(_ line: String) -> [StreamEvent] {
        guard let v = object(line) else { return [] }
        switch v["type"] as? String {
        case "response.output_text.delta":
            guard let d = v["delta"] as? String, !d.isEmpty else { return [] }
            return [.text(d)]
        case "response.completed":
            let u = (v["response"] as? [String: Any])?["usage"] as? [String: Any]
            let cached = n(u?["input_tokens_details"] as? [String: Any], "cached_tokens")
            return [.usage(Tokens(input: max(0, n(u, "input_tokens") - cached), cached: cached, output: n(u, "output_tokens"))), .done]
        default:
            return []
        }
    }

    static func n(_ d: [String: Any]?, _ k: String) -> Int {
        (d?[k] as? NSNumber)?.intValue ?? 0
    }

    /// The JSON after "data:".
    static func object(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}

/// A streamed reply as it comes in, one line at a time: its text, the tokens it used, and why the
/// model stopped. `truncated` is true when the model ran out of tokens before it was done; such a
/// reply should be treated as a failure, not shown as an answer.
public struct StreamedReply: Equatable, Sendable {
    public let format: Streaming.Format
    public private(set) var text = ""
    public private(set) var tokens = Tokens()
    public private(set) var stopReason: String?
    /// The stream said it is over (message_stop, [DONE]).
    public private(set) var finished = false

    public var truncated: Bool { Streaming.isTruncated(stopReason) }

    public init(_ format: Streaming.Format) {
        self.format = format
    }

    /// Reads one line. Returns whether the text grew; throws the service's error (a
    /// ChatGPTPlan.Failure for the Responses API).
    @discardableResult
    public mutating func read(_ line: String) throws -> Bool {
        if format == .responses, let failure = ChatGPTPlan.streamFailure(line) { throw failure }
        if let reason = Streaming.stopReason(line, format: format) { stopReason = reason }
        var grew = false
        for event in Streaming.events(line, format: format) {
            switch event {
            case .text(let t):
                text += t
                grew = true
            case .usage(let t):
                tokens.merge(t)
            case .done:
                finished = true
            case .error(let message):
                throw ServiceError(message)
            }
        }
        return grew
    }
}
