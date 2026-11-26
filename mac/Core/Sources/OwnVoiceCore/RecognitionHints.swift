// The glossary also helps recognition: its names and product terms, as said in the meeting (the
// right-hand side of each `中文 = English` line), are given to the recognizer as hints, so a name it
// does not know is not heard as something else. Each service takes them its own way: Apple's
// contextual strings, Gemini's custom vocabulary (Live and Transcribe), OpenAI Live's keywords, and
// a short prompt for the uploads to OpenAI and Whisper.

import Foundation

extension Prompts {
    /// The services advise at most about a hundred terms.
    public static let maxRecognitionTerms = 100

    /// The meeting-language side of the glossary, each term once, at most `maxRecognitionTerms`.
    /// Terms with angle brackets are left out (OpenAI Live rejects them).
    public static func recognitionTerms(glossary: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for entry in parseGlossary(glossary) {
            let term = entry.en
            guard !term.contains("<"), !term.contains(">"), seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxRecognitionTerms { break }
        }
        return terms
    }

    /// The prompt for an upload to OpenAI or a Whisper server: the terms as a short list, the way
    /// OpenAI suggests for words it might not know. Whisper reads only the last 224 tokens of a
    /// prompt, so it is kept to about 600 characters. Empty when there are no terms.
    public static func transcriptionPrompt(terms: [String]) -> String {
        var list = ""
        for term in terms {
            let next = list.isEmpty ? term : list + ", " + term
            if next.count > 600 { break }
            list = next
        }
        return list.isEmpty ? "" : "Names and terms in this meeting: \(list)."
    }
}

/// One session's recognition hints, given up for good the first time a service refuses them, so
/// recognition with a glossary is never worse than without: the refused setup or upload is tried
/// again without the terms, and the rest of the session goes without. Used from any thread.
public final class RecognitionHints: @unchecked Sendable {
    private let lock = NSLock()
    private let all: [String]
    private var refused = false
    private var noticePending = false

    public init(_ terms: [String]) {
        all = terms
    }

    /// The terms to send now: none once a service refused them.
    public var terms: [String] {
        lock.lock()
        defer { lock.unlock() }
        return refused ? [] : all
    }

    /// A request with the terms was refused and the same one without them was taken.
    public func refuse() {
        lock.lock()
        defer { lock.unlock() }
        if !refused { noticePending = true }
        refused = true
    }

    /// True once after `refuse`: the moment to tell the user.
    public func takeNotice() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let notice = noticePending
        noticePending = false
        return notice
    }

    /// Whether an upload answered with this HTTP status may have been refused for the terms (a
    /// request the service did not accept), not for the key, the address or the rate limit.
    public static func mayBeRefused(status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 404, 408, 429].contains(status)
    }
}
