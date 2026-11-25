// A local model (Gemma 4 or TranslateGemma) on this Mac in one click: whatever is missing, in order.
//   1. Ollama not installed: download Ollama-darwin.zip from ollama.com, unpack it with ditto,
//      check that Ollama.app carries a valid Developer ID signature (nothing is installed if not),
//      mark it as downloaded from the internet so Gatekeeper checks it on first open, and put it in
//      /Applications (~/Applications when that is not writable).
//   2. Ollama not running: open it, and wait until its API answers.
//   3. The chosen model missing (TranslateGemma 4B, Gemma 4 E4B or 12B): download it through
//      Ollama's /api/pull, with progress.

import AppKit
import Foundation
import Observation
import OwnVoiceCore
import Security

@MainActor
@Observable
final class GemmaSetup {
    enum State: Equatable {
        case unknown, checking, noOllama, notRunning, noModel, ready, working
    }

    private(set) var state: State = .unknown
    private(set) var message = ""
    /// Which model to have in Ollama (Settings picks it).
    var model: LocalModel = AppSettings.load().translate.ollamaModel ?? .gemmaE4B {
        didSet { if model != oldValue { Task { await check() } } }
    }
    /// 0…1 while something downloads.
    private(set) var progress: Double?

    /// What is there: Ollama installed, running, with the model.
    func check() async {
        guard state != .working else { return }
        state = .checking
        if let tags = await Self.tags() {
            state = Ollama.hasModel(tags: tags, model: model.rawValue) ? .ready : .noModel
        } else {
            state = Self.installedApp() == nil ? .noOllama : .notRunning
        }
        message = describe(state)
    }

    /// Everything still missing, one step after another.
    func setUp() async {
        guard state != .working else { return }
        state = .working
        do {
            var tags = await Self.tags()
            if tags == nil {
                let app: URL
                if let installed = Self.installedApp() { app = installed } else { app = try await install() }
                tags = try await start(app)
            }
            if let tags, !Ollama.hasModel(tags: tags, model: model.rawValue) {
                try await pull()
            }
            progress = nil
            state = .unknown
            await check()
        } catch {
            progress = nil
            state = .unknown
            message = error.localizedDescription
        }
    }

    private func describe(_ state: State) -> String {
        switch state {
        case .ready: String(localized: "✓ Ready: Ollama is running and has \(model.rawValue).")
        case .noModel: String(localized: "Ollama is running; \(model.rawValue) is not downloaded yet.")
        case .notRunning: String(localized: "Ollama is installed but not running.")
        case .noOllama: String(localized: "Ollama is not installed.")
        case .unknown, .checking, .working: String(localized: "Checking…")
        }
    }

    // MARK: Steps

    private func install() async throws -> URL {
        message = String(localized: "Downloading Ollama…")
        progress = 0
        let zip = try await FileDownload.run(Ollama.appDownload) { fraction in
            Task { @MainActor in self.progress = fraction }
        }
        progress = nil
        message = String(localized: "Installing Ollama…")
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-\(UUID().uuidString)")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw AppError(String(localized: "The Ollama download did not contain Ollama.app."))
        }
        try Self.verifySignature(app)
        let destination = try Self.applicationsFolder().appendingPathComponent("Ollama.app")
        try FileManager.default.moveItem(at: app, to: destination)
        Self.markDownloaded(destination)
        try? FileManager.default.removeItem(at: zip)
        try? FileManager.default.removeItem(at: unpacked)
        return destination
    }

    /// Opens Ollama and waits for its API; the model list it answers with.
    private func start(_ app: URL) async throws -> Data {
        message = String(localized: "Starting Ollama… (if macOS asks whether to open it, choose Open)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<90 {
            if let tags = await Self.tags() { return tags }
            try await Task.sleep(for: .seconds(1))
        }
        throw AppError(String(localized: "Ollama did not start. Open Ollama from Applications once, then press Set Up Gemma 4 again."))
    }

    private func pull() async throws {
        message = String(localized: "Downloading \(model.rawValue)…")
        progress = 0
        var req = URLRequest(url: Ollama.base.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.rawValue, "stream": true])
        req.timeoutInterval = 3600
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            switch Ollama.pullStep(line) {
            case .progress(_, let done, let total)? where total > 0:
                progress = Double(done) / Double(total)
                let gb = { (n: Int64) in String(format: "%.1f", Double(n) / 1e9) }
                let name = model.rawValue
                message = String(localized: "Downloading \(name)… \(gb(done)) / \(gb(total)) GB")
            case .done?:
                return
            case .error(let e)?:
                throw AppError(String(localized: "Ollama could not download the model: \(e)"))
            default:
                continue
            }
        }
        throw AppError(String(localized: "The model download stopped before it finished; press Set Up Gemma 4 to go on."))
    }

    // MARK: Helpers

    /// /api/tags, or nil when Ollama does not answer.
    private static func tags() async -> Data? {
        var req = URLRequest(url: Ollama.base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func installedApp() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications/Ollama.app"), home.appendingPathComponent("Applications/Ollama.app")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func applicationsFolder() throws -> URL {
        let system = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let mine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine
    }

    /// A valid signature by an Apple Developer ID, intact (the download was not altered).
    private static func verifySignature(_ app: URL) throws {
        let requirementText = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw AppError(String(localized: "The Ollama download failed its signature check, so it was not installed."))
        }
    }

    /// Gatekeeper checks an app marked as downloaded when it first opens, as for a browser download.
    private static func markDownloaded(_ app: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "OwnVoice Meet",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        var url = app
        try? url.setResourceValues(values)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AppError(String(localized: "Unpacking Ollama failed."))
            }
        }.value
    }
}

/// A file download with progress, into a temporary file of its own.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func run(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let download = FileDownload(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(AppError(String(localized: "Ollama could not be downloaded from ollama.com."))))
            return
        }
        // The file at `location` is gone once this returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
