// Upload-per-sentence speech recognition: one WAV per utterance (Segmenter), either to an
// OpenAI-compatible /audio/transcriptions endpoint (OpenAI gpt-4o-mini-transcribe, or a Whisper
// server the user runs) as multipart form data, or inline to Gemini's /interactions endpoint
// (gemini-3.5-transcribe, per ai.google.dev/gemini-api/docs/transcribe: verbatim mode, the meeting
// language as a BCP-47 hint, the text in steps[].content[].text).

import Foundation

public enum Uploads {
    public static let geminiInteractions = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    public static let openAITranscriptions = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// multipart/form-data for /audio/transcriptions; returns the body and its Content-Type.
    public static func transcriptionForm(wav: Data, model: String, language: String, boundary: String = "ownvoice-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("model", model)
        field("response_format", "json")
        let iso = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        if !iso.isEmpty { field("language", iso) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    public static func transcriptionText(_ data: Data, status: Int) throws -> String {
        let v = try Requests.object(data, status: status)
        return (v["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func geminiBody(model: String, language: String, wav: Data) throws -> Data {
        let lang = language.trimmingCharacters(in: .whitespaces)
        let body: [String: Any] = [
            "model": model,
            "input": [["type": "audio", "data": wav.base64EncodedString(), "mime_type": "audio/wav"]],
            // Verbatim: Smart mode would act on "actually no, …" in a meeting as an editing instruction.
            "generation_config": ["transcription_config": ["language_codes": lang.isEmpty ? [] : [lang]]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func geminiText(_ data: Data, status: Int) throws -> String {
        let v = try Requests.object(data, status: status)
        if let s = v["status"] as? String, s != "completed" { throw ServiceError("Gemini status: \(s)") }
        if let t = v["output_text"] as? String { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        let steps = v["steps"] as? [[String: Any]] ?? []
        let texts = steps.filter { ($0["type"] as? String).map { $0 == "model_output" } ?? true }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
