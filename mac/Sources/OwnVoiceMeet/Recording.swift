// A listening session as it is kept: every line with its time and final translation (for the
// summary, and for transcript.md when saving is on), the summary in summary.md, and the sound in
// recording.m4a when the user chose to keep it. Each session gets a folder named by its start.

import AVFoundation
import Foundation
import OwnVoiceCore

@MainActor
final class SessionRecord {
    let started = Date()
    let folder: URL?
    private let header: [String]
    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []
    private var dirty = false
    private var audio: AudioRecorder?
    /// Finished, translated lines the summary has not taken in yet.
    private(set) var forSummary: [TranscriptLine] = []

    private struct Entry {
        var offset: TimeInterval
        var heard = ""
        var translation = ""
        var finished = false
    }

    init(settings s: AppSettings, recognition: String, translation: String) throws {
        let start = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
        header = [
            String(localized: "Started: \(start)"),
            String(localized: "Sound: \(s.input.label)"),
            String(localized: "Recognition: \(recognition)"),
            String(localized: "Translation: \(translation)"),
        ]
        guard s.saveMode != .off else {
            folder = nil
            return
        }
        let dir = s.saveFolderURL.appendingPathComponent(SessionFiles.folderName(started))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AppError(String(localized: "Could not make the session folder: \(error.localizedDescription)"))
        }
        folder = dir
        if s.saveMode == .transcriptAndAudio {
            audio = try AudioRecorder(url: dir.appendingPathComponent("recording.m4a"))
        }
    }

    /// The recorder, if the sound is kept: read once when listening starts, then fed from the
    /// audio thread (it is safe there).
    var audioRecorder: AudioRecorder? { audio }

    func opened(_ id: Int) {
        guard entries[id] == nil else { return }
        entries[id] = Entry(offset: Date().timeIntervalSince(started))
        order.append(id)
    }

    func finished(_ id: Int, heard: String) {
        opened(id)
        entries[id]?.heard = heard
        entries[id]?.finished = true
        dirty = true
    }

    func translated(_ id: Int, _ zh: String) {
        guard var e = entries[id] else { return }
        e.translation = zh
        entries[id] = e
        dirty = true
        if e.finished { forSummary.append(TranscriptLine(offset: e.offset, heard: e.heard, translation: zh)) }
    }

    func takeForSummary() -> [TranscriptLine] {
        defer { forSummary.removeAll() }
        return forSummary
    }

    /// Lines the summary could not use this time go back in front.
    func giveBack(_ lines: [TranscriptLine]) {
        forSummary.insert(contentsOf: lines, at: 0)
    }

    /// "14:05" for a line's offset.
    func clock(_ offset: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: started.addingTimeInterval(offset))
    }

    func writeIfChanged() {
        guard dirty, let folder else { return }
        dirty = false
        let lines = order.compactMap { entries[$0] }.filter(\.finished).map { TranscriptLine(offset: $0.offset, heard: $0.heard, translation: $0.translation) }
        write(SessionFiles.transcript(title: String(localized: "Transcript"), header: header, lines: lines), to: folder.appendingPathComponent("transcript.md"))
    }

    func writeSummary(_ text: String, updated: String) {
        guard let folder else { return }
        write(SessionFiles.summary(title: String(localized: "Summary"), updated: updated, text: text), to: folder.appendingPathComponent("summary.md"))
    }

    func close() {
        audio?.close()
        audio = nil
        dirty = true
        writeIfChanged()
    }

    private func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// The session's sound as AAC in an .m4a file (mono, 48 kHz).
final class AudioRecorder: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: BufferConverter
    private let queue = DispatchQueue(label: "recorder")

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AppError(String(localized: "Could not start the recording: \(error.localizedDescription)"))
        }
        converter = BufferConverter(to: file.processingFormat)
    }

    /// Called on the audio thread: converted there (the source may reuse its buffer), written on
    /// a queue of its own.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        queue.async { try? self.file.write(from: converted) }
    }

    func close() {
        queue.sync { file.close() }
    }
}
