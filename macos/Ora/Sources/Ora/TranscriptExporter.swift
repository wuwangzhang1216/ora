import Foundation
import UniformTypeIdentifiers

/// Export target format for the transcript history.
enum TranscriptExportFormat: String, CaseIterable, Identifiable {
    case txt
    case srt
    case json
    case md

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .txt:  return "Plain Text (.txt)"
        case .srt:  return "Subtitles (.srt)"
        case .json: return "JSON (.json)"
        case .md:   return "Markdown (.md)"
        }
    }

    var utType: UTType {
        switch self {
        case .txt:  return .plainText
        case .srt:  return UTType(filenameExtension: "srt") ?? .plainText
        case .json: return .json
        case .md:   return UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

/// Pure rendering functions — given a set of `TranscriptEntry` values and a
/// target format, produce the bytes to write to disk. Kept stateless so the
/// same renderer can serve both "current session" and "all history" exports.
enum TranscriptExporter {
    static func render(_ entries: [TranscriptEntry], as format: TranscriptExportFormat) -> Data {
        switch format {
        case .txt:  return renderTxt(entries)
        case .srt:  return renderSrt(entries)
        case .json: return renderJson(entries)
        case .md:   return renderMd(entries)
        }
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func groupedBySession(_ entries: [TranscriptEntry]) -> [[TranscriptEntry]] {
        var order: [UUID] = []
        var groups: [UUID: [TranscriptEntry]] = [:]
        for e in entries {
            if groups[e.sessionId] == nil { order.append(e.sessionId) }
            groups[e.sessionId, default: []].append(e)
        }
        return order.map { groups[$0] ?? [] }
    }

    // MARK: - TXT

    private static func renderTxt(_ entries: [TranscriptEntry]) -> Data {
        let groups = groupedBySession(entries)
        var out = ""
        for (i, group) in groups.enumerated() {
            if i > 0 { out += "\n" }
            if let first = group.first {
                out += "# Session \(dateFormatter.string(from: first.startedAt))\n"
            }
            for e in group {
                out += "[\(timeFormatter.string(from: e.startedAt))] "
                out += "\(e.sourceText) ⇒ \(e.translationText)\n"
            }
        }
        return Data(out.utf8)
    }

    // MARK: - SRT

    private static func renderSrt(_ entries: [TranscriptEntry]) -> Data {
        guard let base = entries.first?.startedAt else { return Data() }
        var out = ""
        for (i, e) in entries.enumerated() {
            let start = e.startedAt.timeIntervalSince(base)
            let end = max(start + 0.5, e.endedAt.timeIntervalSince(base))
            out += "\(i + 1)\n"
            out += "\(srtTime(start)) --> \(srtTime(end))\n"
            out += "\(e.translationText)\n"
            if !e.sourceText.isEmpty {
                out += "\(e.sourceText)\n"
            }
            out += "\n"
        }
        return Data(out.utf8)
    }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        let ms = Int((s - floor(s)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }

    // MARK: - JSON

    private static func renderJson(_ entries: [TranscriptEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)) ?? Data()
    }

    // MARK: - Markdown

    private static func renderMd(_ entries: [TranscriptEntry]) -> Data {
        let groups = groupedBySession(entries)
        var out = "# Ora Transcript\n\n"
        for group in groups {
            guard let first = group.first else { continue }
            out += "## Session — \(dateFormatter.string(from: first.startedAt))\n\n"
            for e in group {
                out += "**[\(timeFormatter.string(from: e.startedAt))]** \(e.sourceText)\n\n"
                out += "> \(e.translationText)\n\n"
            }
        }
        return Data(out.utf8)
    }
}
