// Ollama on this Mac, for Gemma 4: its address, the model, the download of Ollama itself, and the
// answers of its own API (/api/tags lists the models it has; /api/pull streams one JSON line per
// step while a model downloads).

import Foundation

public enum Ollama {
    public static let base = URL(string: "http://localhost:11434")!
    /// Ollama for macOS, as ollama.com offers it (a zip holding Ollama.app).
    public static let appDownload = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!

    /// Whether the /api/tags answer lists `model` under that very tag. Ollama answers a request only
    /// for a tag it lists: a model pulled as gemma4:latest is the same E4B, yet a request for
    /// gemma4:e4b fails until that tag is pulled too, so :latest does not count.
    public static func hasModel(tags: Data, model: String) -> Bool {
        guard let v = (try? JSONSerialization.jsonObject(with: tags)) as? [String: Any],
              let models = v["models"] as? [[String: Any]] else { return false }
        let names = models.flatMap { [$0["name"] as? String, $0["model"] as? String].compactMap { $0 } }
        return names.contains(model)
    }

    public enum PullStep: Equatable, Sendable {
        case progress(status: String, done: Int64, total: Int64)
        case done
        case error(String)
    }

    /// One line of /api/pull: {"status":"pulling 1a2b…","total":…,"completed":…}, then {"status":"success"}.
    public static func pullStep(_ line: String) -> PullStep? {
        guard let v = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        if let e = v["error"] as? String { return .error(e) }
        guard let status = v["status"] as? String else { return nil }
        if status == "success" { return .done }
        let n = { (key: String) -> Int64 in (v[key] as? NSNumber)?.int64Value ?? 0 }
        return .progress(status: status, done: n("completed"), total: n("total"))
    }
}
