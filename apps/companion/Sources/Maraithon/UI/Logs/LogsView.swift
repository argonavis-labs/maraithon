import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Live tail of the in-memory `EventLog`. Tracks the spec's M6 surface:
/// level + source `Picker`s, searchable, selection-driven `Inspector`
/// with the pretty-printed structured payload, and a "···" toolbar menu
/// exposing "Reveal in Finder" and "Copy visible rows".
///
/// Invariant: this view never mutates `EventLog`. All filter state is
/// view-local so navigating away (or relaunching) resets to a clean
/// default tail.
struct LogsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var levelFilter: LogLevel? = nil
    @State private var sourceFilter: LogSource? = nil
    @State private var search: String = ""
    @State private var selection: LogEntry.ID? = nil
    @State private var inspectorShown: Bool = false

    private var filtered: [LogEntry] {
        env.eventLog.entries.reversed().filter { entry in
            (levelFilter == nil || entry.level == levelFilter) &&
            (sourceFilter == nil || entry.source == sourceFilter) &&
            (search.isEmpty
             || entry.message.localizedCaseInsensitiveContains(search)
             || LogDisplayCopy.label(for: entry.level).localizedCaseInsensitiveContains(search)
             || LogDisplayCopy.label(for: entry.source).localizedCaseInsensitiveContains(search)
             || entry.payload.contains(where: {
                $0.key.localizedCaseInsensitiveContains(search) ||
                $0.value.localizedCaseInsensitiveContains(search)
             }))
        }
    }

    private var selectedEntry: LogEntry? {
        guard let selection else { return nil }
        return env.eventLog.entries.first(where: { $0.id == selection })
    }

    var body: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Time") { entry in
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Level") { entry in
                Text(LogDisplayCopy.label(for: entry.level))
                    .font(.caption)
                    .foregroundStyle(color(for: entry.level))
            }
            .width(min: 70, ideal: 80)

            TableColumn("Source") { entry in
                Text(LogDisplayCopy.label(for: entry.source))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Message") { entry in
                Text(entry.message)
                    .lineLimit(1)
            }
        }
        .navigationTitle("Logs")
        .searchable(text: $search, placement: .toolbar, prompt: "Search messages")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Level", selection: $levelFilter) {
                    Text("All levels").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(LogDisplayCopy.label(for: level)).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)

                Picker("Source", selection: $sourceFilter) {
                    Text("All sources").tag(LogSource?.none)
                    ForEach(LogSource.allCases, id: \.self) { source in
                        Text(LogDisplayCopy.label(for: source)).tag(LogSource?.some(source))
                    }
                }
                .pickerStyle(.menu)

                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector")

                Menu {
                    Button("Reveal in Finder", systemImage: "folder") {
                        revealLogFile()
                    }
                    Button("Copy visible rows", systemImage: "doc.on.doc") {
                        copyVisibleRows()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .inspector(isPresented: $inspectorShown) {
            LogInspector(entry: selectedEntry)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 480)
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { inspectorShown = true }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .accentColor
        case .warning: return StatusTone.attention.color
        case .error: return StatusTone.error.color
        }
    }

    private func revealLogFile() {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Maraithon", isDirectory: true) else {
            env.eventLog.warning("logs.reveal.no_logs_dir", source: .ui)
            return
        }
        let target = logsDir.appendingPathComponent("companion.log")
        #if canImport(AppKit)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(logsDir)
        }
        #endif
        env.eventLog.info("logs.reveal_in_finder", source: .ui)
    }

    private func copyVisibleRows() {
        let header = LogDisplayCopy.copiedRowsHeader
        let rows = filtered.map { entry -> String in
            let payload = entry.payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return [
                ISO8601DateFormatter().string(from: entry.timestamp),
                LogDisplayCopy.label(for: entry.level),
                LogDisplayCopy.label(for: entry.source),
                entry.message.replacingOccurrences(of: "\t", with: " "),
                payload
            ].joined(separator: "\t")
        }
        let tsv = ([header] + rows).joined(separator: "\n")
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
        #endif
        env.eventLog.info(
            "logs.copy_visible_rows",
            source: .ui,
            payload: ["rows": String(rows.count)]
        )
    }
}

/// Detail pane for the selected log row. Renders a pretty-printed JSON
/// view of the structured payload so the user can copy/inspect without
/// reaching for the log file.
private struct LogInspector: View {
    let entry: LogEntry?

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                            SectionHeader("Message")
                            Text(entry.message)
                                .font(.body)
                                .textSelection(.enabled)
                        }

                        VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                            SectionHeader("Meta")
                            metaRow("Time", entry.timestamp.formatted(.iso8601))
                            metaRow("Level", LogDisplayCopy.label(for: entry.level))
                            metaRow("Source", LogDisplayCopy.label(for: entry.source))
                        }

                        VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                            SectionHeader(LogDisplayCopy.detailsSectionTitle)
                            Text(prettyPrinted(entry.payload))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Tokens.Spacing.medium)
                }
            } else {
                ContentUnavailableView(
                    LogDisplayCopy.noSelectionTitle,
                    systemImage: "text.magnifyingglass",
                    description: Text(LogDisplayCopy.noSelectionDescription)
                )
            }
        }
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        LabeledContent(key) {
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    private func prettyPrinted(_ payload: [String: String]) -> String {
        guard !payload.isEmpty else { return "{}" }
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
