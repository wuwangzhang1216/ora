import Foundation
import Observation

/// Single record of one completed source→translation utterance. Serialized
/// as one JSON object per line in the monthly JSONL log.
struct TranscriptEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let sourceText: String
    let translationText: String
    let sourceLanguageHint: String?
    let targetLanguage: String
    let audioSource: String
    let sessionId: UUID
}

/// Persistent, append-only transcript store. Each completed utterance is
/// appended to `~/Library/Application Support/Ora/history/YYYY-MM.jsonl`
/// (rolling monthly) AND held in `currentSession` for the lifetime of the
/// running app. Export pulls from either the in-memory session or
/// `loadAll()`.
@MainActor
@Observable
final class TranscriptHistory {
    static let shared = TranscriptHistory()

    private(set) var currentSession: [TranscriptEntry] = []
    let sessionId = UUID()
    var latestEntry: TranscriptEntry? { currentSession.last }

    private let historyDir: URL
    private let writeQueue = DispatchQueue(label: "com.wangzhangwu.ora.history", qos: .utility)

    var historyFolderURL: URL { historyDir }

    private init() {
        let fm = FileManager.default
        let base: URL
        if let url = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = url
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        historyDir = base.appendingPathComponent("Ora/history", isDirectory: true)
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
    }

    /// Append an entry to the in-memory session list and asynchronously to
    /// the on-disk JSONL log. Disk I/O happens off the main actor.
    func append(_ entry: TranscriptEntry) {
        currentSession.append(entry)
        let url = currentLogURL()
        writeQueue.async {
            Self.appendLine(entry, to: url)
        }
    }

    func clearCurrentSession() {
        currentSession.removeAll()
    }

    /// Read every JSONL file under the history folder, merge, and sort by
    /// start time. Unparseable lines are skipped so a single corrupt line
    /// never takes down the whole history.
    func loadAll() -> [TranscriptEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: historyDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let jsonl = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var all: [TranscriptEntry] = []
        for file in jsonl {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let data = trimmed.data(using: .utf8) else { continue }
                if let entry = try? decoder.decode(TranscriptEntry.self, from: data) {
                    all.append(entry)
                } else {
                    FileHandle.standardError.write(
                        "[history] skip unparseable line in \(file.lastPathComponent)\n"
                            .data(using: .utf8) ?? Data()
                    )
                }
            }
        }
        return all.sorted { $0.startedAt < $1.startedAt }
    }

    /// Delete every JSONL file and clear the in-memory session. Throws on
    /// filesystem errors so the caller can surface them in an alert.
    func clearAll() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "jsonl" {
            try fm.removeItem(at: file)
        }
        currentSession.removeAll()
    }

    private func currentLogURL() -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        return historyDir.appendingPathComponent("\(df.string(from: Date())).jsonl")
    }

    nonisolated private static func appendLine(_ entry: TranscriptEntry, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)  // \n

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: [.atomic])
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
