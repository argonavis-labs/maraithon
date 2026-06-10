import AppKit
import SwiftUI

/// Detail pane for the Files source. Activity and recent checks read from
/// the live `SourceStatusPublisher` so the user sees real numbers as
/// batches land.
struct FilesDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "files",
            displayName: "Files",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "file",
            syncedItemPlural: "files",
            emptyDescription: "After the first Files check, this view shows recently indexed files and recent checks.",
            extraSection: AnyView(FilesFoldersSection())
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "files")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "files added"),
            SourceStat(id: "total", title: SourceDetailCopy.totalSyncedTitle, value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}

/// User-managed scan folders. Edits write through `FilesFolderSettings`
/// and the scanner picks them up on its next cycle — no restart needed.
struct FilesFoldersSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var folderPaths: [String] = []
    @State private var isCustomized = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            Text("Folders")
                .font(.headline)

            Text(
                isCustomized
                    ? "Maraithon checks these folders for documents. It never scans the whole computer."
                    : "Maraithon checks your Documents, Desktop, and Downloads folders. Add a folder to customize the list. It never scans the whole computer."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                ForEach(folderPaths, id: \.self) { path in
                    HStack(spacing: Tokens.Spacing.small) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)

                        Text(displayPath(path))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)

                        Spacer(minLength: Tokens.Spacing.small)

                        Button {
                            FilesFolderSettings.remove(path: path)
                            logChange(action: "remove")
                            reload()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(displayPath(path)) from scanned folders")
                        .disabled(folderPaths.count == 1)
                        .help(
                            folderPaths.count == 1
                                ? "At least one folder must stay on the list."
                                : "Stop scanning this folder"
                        )
                    }
                }
            }

            HStack(spacing: Tokens.Spacing.small) {
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }

                if isCustomized {
                    Button("Reset to Defaults") {
                        FilesFolderSettings.resetToDefaults()
                        logChange(action: "reset")
                        reload()
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders for Maraithon to check for documents."

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            FilesFolderSettings.add(url)
        }
        logChange(action: "add")
        reload()
    }

    private func reload() {
        folderPaths = FilesFolderSettings.effectiveRoots().map { $0.path }
        isCustomized = FilesFolderSettings.isCustomized()
    }

    // Counts only — folder paths stay out of the logs.
    private func logChange(action: String) {
        env.eventLog.info(
            "files.folders_changed",
            source: .files,
            payload: [
                "action": action,
                "folder_count": String(FilesFolderSettings.effectiveRoots().count)
            ]
        )
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
