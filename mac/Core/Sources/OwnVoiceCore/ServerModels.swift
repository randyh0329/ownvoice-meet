// Settings' Test Connection for the user's own servers (an OpenAI-compatible text server, a Whisper
// server): GET <address>/models and read the model names it lists, so one can be picked instead of
// typed. Most servers answer as OpenAI does ({"data": [{"id": …}]}); Ollama's own list
// ({"models": [{"name": …}]}) and a bare array are read too.

import Foundation

public enum ServerModels {
    /// The answer was not a list of models (a web page, say).
    public struct NotAList: Error, Equatable {
        public init() {}
    }

    /// `<address>/models`, with spaces and trailing slashes taken off; nil when there is no usable
    /// http(s) address.
    public static func url(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/models"), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The model names in a server's answer, in its order, each once. An HTTP error throws the
    /// server's own message (ServiceError); an answer that is no list throws NotAList.
    public static func ids(_ data: Data, status: Int) throws -> [String] {
        guard (200..<300).contains(status) else {
            _ = try Requests.object(data, status: status)
            throw ServiceError("\(status)")
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        let entries: [Any]
        if let list = json as? [Any] {
            entries = list
        } else if let object = json as? [String: Any], let list = (object["data"] ?? object["models"]) as? [Any] {
            entries = list
        } else {
            throw NotAList()
        }
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            let name: String?
            if let text = entry as? String {
                name = text
            } else if let item = entry as? [String: Any] {
                name = (item["id"] ?? item["name"] ?? item["model"]) as? String
            } else {
                name = nil
            }
            guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out
    }
}
