// A listening session as it is kept: every line with its time and final translation (for the
// summary, and for transcript.md when saving is on), the summary in summary.md, and the sound when
// the user chose to keep it. Each session gets a folder named by its start; each segment in it gets
// its own transcript ("01-Keynote.md") and, with the sound kept, its own recording ("01-Keynote.mp4"
// or .wav, as chosen).

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
    /// Closed: a translation that still arrives is written at once (no ticker any more).
    private var closed = false
    private var audio: AudioRecorder?
    /// "mp4" or "wav" (Settings → Summary & Saving).
    private let soundExtension: String
    private var segments: [Segment]
    /// The agenda's segment names, taken in turn by New Segment.
    private let agenda: [String]
    /// Each segment's transcript as last written, to remove it when the segment is renamed.
    private var written: [Int: URL] = [:]
    /// The recording file open now, and the segment it belongs to.
    private var soundFile: URL?
    private var soundSegment = 0
    /// Finished, translated lines the summary has not taken in yet.
    private(set) var forSummary: [TranscriptLine] = []

    /// The speaker list's names, for writing (lines keep positions in it).
    var speakerNames: [String] = [] {
        didSet { if speakerNames != oldValue { dirty = true } }
    }

    private struct Entry {
        var offset: TimeInterval
        var segment: Int
        var speaker: Int?
        var heard = ""
        var translation = ""
        var finished = false
    }

    /// `keepSound`: record the sound even if saving is off (record only).
    init(settings s: AppSettings, recognition: String, translation: String, keepSound: Bool = false, onRecordingProblem: @escaping @Sendable (String) -> Void = { _ in }) throws {
        soundExtension = s.recordingFormat.fileExtension
        agenda = Agenda.names(s.agenda)
        segments = [Segment(name: Agenda.name(agenda, at: 0) ?? String(localized: "Start"), offset: 0)]
        let start = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
        header = [
            String(localized: "Started: \(start)"),
            String(localized: "Sound: \(s.input.label)"),
            String(localized: "Recognition: \(recognition)"),
            String(localized: "Translation: \(translation)"),
        ]
        guard s.saveMode != .off || keepSound else {
            folder = nil
            return
        }
        // Two sessions in the same minute get two folders ("… 1405", "… 1405 2").
        let name = SessionFiles.uniqueName(SessionFiles.folderName(started)) { FileManager.default.fileExists(atPath: s.saveFolderURL.appendingPathComponent($0).path) }
        let dir = s.saveFolderURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AppError(String(localized: "Could not make the session folder: \(error.localizedDescription)"))
        }
        folder = dir
        if s.saveMode == .transcriptAndAudio || keepSound {
            let url = soundURL(0, in: dir)
            audio = try AudioRecorder(url: url, format: s.recordingFormat, onProblem: onRecordingProblem)
            soundFile = url
        }
    }

    /// The recorder, if the sound is kept: read once when listening starts, then fed from the
    /// audio thread (it is safe there).
    var audioRecorder: AudioRecorder? { audio }

    func opened(_ id: Int, speaker: Int?) {
        guard entries[id] == nil else { return }
        entries[id] = Entry(offset: Date().timeIntervalSince(started), segment: segments.count - 1, speaker: speaker)
        order.append(id)
    }

    /// The speakers of the lines as the captions now have them (after a change or an undo).
    func adoptSpeakers(_ lines: [CaptionLine]) {
        for line in lines where entries[line.id] != nil && entries[line.id]?.speaker != line.speaker {
            entries[line.id]?.speaker = line.speaker
            dirty = true
        }
        if closed { writeIfChanged() }
    }

    /// Speaker `i` is gone from the list: their lines lose the name, later speakers move up one.
    func removeSpeaker(at i: Int) {
        for (id, e) in entries {
            guard let s = e.speaker, s >= i else { continue }
            entries[id]?.speaker = s == i ? nil : s - 1
            dirty = true
        }
        if closed { writeIfChanged() }
    }

    private func name(_ speaker: Int?) -> String {
        guard let speaker, speaker < speakerNames.count else { return "" }
        let n = speakerNames[speaker].trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String(localized: "Speaker \(String(speaker + 1))") : n
    }

    func finished(_ id: Int, heard: String) {
        opened(id, speaker: nil)
        entries[id]?.heard = heard
        entries[id]?.finished = true
        dirty = true
    }

    func translated(_ id: Int, _ zh: String) {
        guard var e = entries[id] else { return }
        let again = e.finished && !e.translation.isEmpty
        let earlier = TranscriptLine(offset: e.offset, heard: e.heard, translation: e.translation, segment: e.segment, speaker: name(e.speaker))
        e.translation = zh
        entries[id] = e
        dirty = true
        if e.finished {
            let line = TranscriptLine(offset: e.offset, heard: e.heard, translation: zh, segment: e.segment, speaker: name(e.speaker))
            if !again {
                forSummary.append(line)
            } else if let i = forSummary.firstIndex(of: earlier) {
                // More Chinese for a line already in (Live Translate): the summary sees it once.
                forSummary[i] = line
            }
        }
        if closed { writeIfChanged() }
    }

    /// The segment going on now: its number (1 = the first) and name.
    var currentSegment: (number: Int, name: String) { (segments.count, segments[segments.count - 1].name) }

    /// The agenda's name for the next segment, if it has one left.
    var nextAgendaName: String? { Agenda.name(agenda, at: segments.count) }

    /// A new segment from now on; returns its name (the agenda's next one, or "Segment 2", when
    /// none was given). With the sound kept, the recording goes on in a file of its own.
    @discardableResult
    func newSegment(_ name: String) -> String {
        let i = segments.count
        let n = name.isEmpty ? (Agenda.name(agenda, at: i) ?? String(localized: "Segment \(String(i + 1))")) : name
        segments.append(Segment(name: n, offset: Date().timeIntervalSince(started)))
        // If the next file cannot be made, the sound goes on into the one open now: nothing is lost.
        if let audio, let folder, let closing = closingURL() {
            let next = soundURL(i, in: folder)
            if audio.split(closingAs: closing, next: next) {
                soundFile = next
                soundSegment = i
            }
        }
        dirty = true
        writeIfChanged()
        return n
    }

    /// Renames the segment going on now: its transcript at once, its recording when it closes.
    func renameSegment(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let last = segments.last, n != last.name else { return }
        segments[segments.count - 1] = Segment(name: n, offset: last.offset)
        dirty = true
        writeIfChanged()
    }

    /// Where segment `i`'s recording goes, by its name now.
    private func soundURL(_ i: Int, in folder: URL) -> URL {
        folder.appendingPathComponent(SessionFiles.segmentStem(i + 1, segments[i].name) + "." + soundExtension)
    }

    /// The name the open recording closes under: its segment's name now, unless another file
    /// already has that name (then it keeps the one it was opened with).
    private func closingURL() -> URL? {
        guard let folder, let open = soundFile else { return nil }
        let wanted = soundURL(soundSegment, in: folder)
        return wanted != open && FileManager.default.fileExists(atPath: wanted.path) ? open : wanted
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
        let lines = order.compactMap { entries[$0] }.filter(\.finished).map { TranscriptLine(offset: $0.offset, heard: $0.heard, translation: $0.translation, segment: $0.segment, speaker: name($0.speaker)) }
        write(SessionFiles.transcript(title: String(localized: "Transcript"), header: header, segments: segments, lines: lines), to: folder.appendingPathComponent("transcript.md"))
        // Each segment's own transcript; a renamed one does not leave its old file behind.
        for i in segments.indices {
            let url = folder.appendingPathComponent(SessionFiles.segmentStem(i + 1, segments[i].name) + ".md")
            if let old = written[i], old != url { try? FileManager.default.removeItem(at: old) }
            write(SessionFiles.segmentTranscript(index: i, header: header, segments: segments, lines: lines), to: url)
            written[i] = url
        }
    }

    /// Every finished line so far, in order (for the meeting summary).
    func allLines() -> [TranscriptLine] {
        order.compactMap { entries[$0] }.filter(\.finished).map { TranscriptLine(offset: $0.offset, heard: $0.heard, translation: $0.translation, segment: $0.segment, speaker: name($0.speaker)) }
    }

    /// The session's title for the minutes: its start, as the folder is named.
    var title: String { SessionFiles.folderName(started) }

    func writeMinutes(_ text: String, model: String) {
        guard let folder else { return }
        write("# \(String(localized: "Meeting summary")) · \(title)\n\n_\(model)_\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n", to: folder.appendingPathComponent("minutes.md"))
    }

    func writeSummary(_ text: String, updated: String) {
        guard let folder else { return }
        write(SessionFiles.summary(title: String(localized: "Summary"), updated: updated, text: text), to: folder.appendingPathComponent("summary.md"))
    }

    func close() {
        audio?.close(as: closingURL())
        audio = nil
        dirty = true
        writeIfChanged()
        closed = true
    }

    private func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// The session's sound, one file per segment: AAC in an .mp4 file (mono, 48 kHz, 64 kbit/s), or
/// uncompressed 16-bit .wav (mono, 16 kHz). The file type follows the file name's extension.
final class AudioRecorder: @unchecked Sendable {
    /// The file written now and where it is: touched only on `queue` once recording has begun.
    private var file: AVAudioFile
    private var url: URL
    private let format: RecordingFormat
    private let converter: BufferConverter
    private let queue = DispatchQueue(label: "recorder")
    private let onProblem: @Sendable (String) -> Void
    private var reported = false

    init(url: URL, format: RecordingFormat, onProblem: @escaping @Sendable (String) -> Void = { _ in }) throws {
        file = try Self.open(url, format)
        self.url = url
        self.format = format
        self.onProblem = onProblem
        converter = BufferConverter(to: file.processingFormat)
    }

    private static func open(_ url: URL, _ format: RecordingFormat) throws -> AVAudioFile {
        let settings: [String: Any] = switch format {
        case .mp4: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        case .wav: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        }
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AppError(String(localized: "Could not start the recording: \(error.localizedDescription)"))
        }
    }

    /// Called on the audio thread: converted there (the source may reuse its buffer), written on
    /// a queue of its own.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        queue.async {
            do {
                try self.file.write(from: converted)
            } catch {
                // Said once, not dropped: a recording that silently stays empty is found too late.
                guard !self.reported else { return }
                self.reported = true
                self.onProblem(String(localized: "The recording could not be written: \(error.localizedDescription)"))
            }
        }
    }

    /// A segment ends (called on the main thread): the next file is made here, then swapped in on
    /// the writing queue, between one buffer and the next, so no sound is lost or doubled. The file
    /// that ends is closed and named `closingAs`. False, and the sound stays in the file open now,
    /// when the next one cannot be made.
    func split(closingAs: URL, next: URL) -> Bool {
        guard let new = try? Self.open(next, format) else { return false }
        queue.async {
            let old = self.file
            let oldURL = self.url
            self.file = new
            self.url = next
            old.close()
            Self.move(oldURL, to: closingAs)
        }
        return true
    }

    /// The last file is closed (playable from then on) and named `final` when given.
    func close(as final: URL?) {
        queue.sync {
            file.close()
            if let final { Self.move(url, to: final) }
        }
    }

    private static func move(_ from: URL, to: URL) {
        guard from.standardizedFileURL != to.standardizedFileURL else { return }
        try? FileManager.default.moveItem(at: from, to: to)
    }
}
