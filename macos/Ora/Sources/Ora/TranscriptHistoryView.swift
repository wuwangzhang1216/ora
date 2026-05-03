import AppKit
import SwiftUI

/// Searchable transcript browser for past Ora sessions. The store is still
/// append-only JSONL on disk; this view turns that quiet persistence layer
/// into a usable review surface.
struct TranscriptHistoryView: View {
    @Bindable private var history = TranscriptHistory.shared

    @State private var allEntries: [TranscriptEntry] = []
    @State private var query = ""
    @State private var selectedSessionId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HSplitView {
                sessionList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                detailPane
                    .frame(minWidth: 460, idealWidth: 620)
            }
        }
        .frame(width: 900, height: 620)
        .navigationTitle("Transcript History")
        .onAppear {
            refresh()
        }
        .onChange(of: history.currentSession) { _, _ in
            refresh(preserveSelection: true)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search source or translation", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .frame(maxWidth: 360)

            Spacer()

            Button {
                copyEntries(selectedEntries)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(selectedEntries.isEmpty)

            Button {
                exportEntries(selectedEntries, namePrefix: "ora-session")
            } label: {
                Label("Export Session", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedEntries.isEmpty)

            Button {
                refresh(preserveSelection: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(14)
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                emptySessionList
            } else {
                List(selection: $selectedSessionId) {
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptySessionList: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "No transcripts yet" : "No matches")
                .font(.headline)
            Text(query.isEmpty ? "Start listening and completed translations will appear here." : "Try a different search term.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let selectedSession {
            VStack(spacing: 0) {
                sessionHeader(selectedSession)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(selectedSession.entries) { entry in
                            EntryRow(entry: entry) {
                                copyEntries([entry])
                            }
                        }
                    }
                    .padding(18)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Select a session")
                    .font(.headline)
                Text("Browse completed source text and translations without leaving Ora.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sessionHeader(_ session: TranscriptSessionSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionTitle(session.startedAt))
                    .font(.headline)
                Text("\(session.entries.count) lines · \(session.targetLanguage) · \(session.audioSourceDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                copyEntries(session.entries)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                exportEntries(session.entries, namePrefix: "ora-session")
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Data

    private var filteredEntries: [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allEntries }
        return allEntries.filter {
            $0.sourceText.lowercased().contains(needle)
                || $0.translationText.lowercased().contains(needle)
                || $0.targetLanguage.lowercased().contains(needle)
        }
    }

    private var sessions: [TranscriptSessionSummary] {
        TranscriptSessionSummary.group(filteredEntries)
    }

    private var selectedSession: TranscriptSessionSummary? {
        guard let selectedSessionId else { return sessions.first }
        return sessions.first { $0.id == selectedSessionId } ?? sessions.first
    }

    private var selectedEntries: [TranscriptEntry] {
        selectedSession?.entries ?? []
    }

    private func refresh(preserveSelection: Bool = false) {
        let previousSelection = selectedSessionId
        allEntries = mergedHistoryEntries()

        let nextSessions = sessions
        if preserveSelection, let previousSelection, nextSessions.contains(where: { $0.id == previousSelection }) {
            selectedSessionId = previousSelection
        } else {
            selectedSessionId = nextSessions.first?.id
        }
    }

    private func mergedHistoryEntries() -> [TranscriptEntry] {
        var byId: [UUID: TranscriptEntry] = [:]
        for entry in history.loadAll() {
            byId[entry.id] = entry
        }
        for entry in history.currentSession {
            byId[entry.id] = entry
        }
        return byId.values.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Actions

    private func copyEntries(_ entries: [TranscriptEntry]) {
        guard !entries.isEmpty else { return }
        let data = TranscriptExporter.render(entries.sorted { $0.startedAt < $1.startedAt }, as: .txt)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func exportEntries(_ entries: [TranscriptEntry], namePrefix: String) {
        TranscriptExportCoordinator.export(
            entries: entries.sorted { $0.startedAt < $1.startedAt },
            suggestedName: "\(namePrefix)-\(TranscriptExportCoordinator.timestamp())"
        )
    }

    private func sessionTitle(_ date: Date) -> String {
        Self.titleFormatter.string(from: date)
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        formatter.locale = Locale.current
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - Session summary

private struct TranscriptSessionSummary: Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let targetLanguage: String
    let audioSource: String
    let entries: [TranscriptEntry]

    var audioSourceDisplayName: String {
        AudioSourceKind(rawValue: audioSource)?.displayName ?? audioSource
    }

    static func group(_ entries: [TranscriptEntry]) -> [TranscriptSessionSummary] {
        var order: [UUID] = []
        var grouped: [UUID: [TranscriptEntry]] = [:]

        for entry in entries.sorted(by: { $0.startedAt > $1.startedAt }) {
            if grouped[entry.sessionId] == nil {
                order.append(entry.sessionId)
            }
            grouped[entry.sessionId, default: []].append(entry)
        }

        return order.compactMap { sessionId in
            let sessionEntries = (grouped[sessionId] ?? []).sorted { $0.startedAt < $1.startedAt }
            guard let first = sessionEntries.first, let last = sessionEntries.last else { return nil }
            return TranscriptSessionSummary(
                id: sessionId,
                startedAt: first.startedAt,
                endedAt: last.endedAt,
                targetLanguage: first.targetLanguage,
                audioSource: first.audioSource,
                entries: sessionEntries
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Rows

private struct SessionRow: View {
    let session: TranscriptSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.dateFormatter.string(from: session.startedAt))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text("\(session.entries.count) lines · \(session.targetLanguage)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(preview)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        session.entries.first?.translationText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        formatter.locale = Locale.current
        formatter.timeZone = .current
        return formatter
    }()
}

private struct EntryRow: View {
    let entry: TranscriptEntry
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.timeFormatter.string(from: entry.startedAt))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this line")
            }

            if !entry.sourceText.isEmpty {
                Text(entry.sourceText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(entry.translationText)
                .font(.system(size: 16, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
