// Server-sent events from the text models, one `data:` line at a time: Anthropic's Messages API
// (content_block_delta text) and Chat Completions (choices[0].delta.content, ending with [DONE]).

import Foundation

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case usage(Tokens)
    case done
    case error(String)
}

public enum Streaming {
    public static func anthropic(_ line: String) -> StreamEvent? {
        guard let v = object(line) else { return nil }
        let n = { (d: [String: Any]?, k: String) in (d?[k] as? NSNumber)?.intValue ?? 0 }
        switch v["type"] as? String {
        case "message_start":
            let u = (v["message"] as? [String: Any])?["usage"] as? [String: Any]
            return .usage(Tokens(input: n(u, "input_tokens"), cached: n(u, "cache_read_input_tokens"), output: 0))
        case "message_delta":
            let u = v["usage"] as? [String: Any]
            return .usage(Tokens(output: n(u, "output_tokens")))
        case "content_block_delta":
            let delta = v["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String else { return nil }
            return .text(t)
        case "message_stop":
            return .done
        case "error":
            return .error((v["error"] as? [String: Any])?["message"] as? String ?? "error")
        default:
            return nil
        }
    }

    public static func chat(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        if line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        guard let v = object(line) else { return nil }
        if let e = v["error"] as? [String: Any] { return .error(e["message"] as? String ?? "error") }
        // The last chunk (stream_options.include_usage): no choices, the usage of the whole answer.
        if let u = v["usage"] as? [String: Any], (v["choices"] as? [Any])?.isEmpty ?? true {
            let n = { (d: [String: Any]?, k: String) in (d?[k] as? NSNumber)?.intValue ?? 0 }
            let cached = n(u["prompt_tokens_details"] as? [String: Any], "cached_tokens")
            return .usage(Tokens(input: max(0, n(u, "prompt_tokens") - cached), cached: cached, output: n(u, "completion_tokens")))
        }
        let delta = ((v["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
        guard let t = delta?["content"] as? String, !t.isEmpty else { return nil }
        return .text(t)
    }

    /// The JSON after "data:".
    static func object(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}
