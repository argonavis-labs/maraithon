import AppKit
import SwiftUI

/// User-managed scan folders on the Files page, as one card section:
/// explanation row, one row per folder with a remove control, and an
/// actions row. Edits write through `FilesFolderSettings` and the
/// scanner picks them up on its next cycle — no restart needed.
struct FilesFoldersSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var folderPaths: [String] = []
    @State private var isCustomized = false

    var body: some View {
        RunnerSection(title: "Folders") {
            RunnerCard {
                VStack(spacing: 0) {
                    Text(
                        isCustomized
                            ? "Maraithon checks these folders for documents. It never scans the whole computer."
                            : "Maraithon checks your Documents, Desktop, and Downloads folders. Add a folder to customize the list. It never scans the whole computer."
                    )
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .runnerCardRow()

                    ForEach(folderPaths, id: \.self) { path in
                        RunnerHairline()
                        folderRow(path)
                    }

                    RunnerHairline()
                    actionsRow
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func folderRow(_ path: String) -> some View {
        HStack(spacing: Tokens.Spacing.snug) {
            Image(systemName: "folder")
                .font(Tokens.Typography.navIcon)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .frame(width: Tokens.SourcesLayout.rowIconColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            Text(displayPath(path))
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
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
            .buttonStyle(RunnerButtonStyle(.plain))
            .accessibilityLabel("Remove \(displayPath(path)) from scanned folders")
            .disabled(folderPaths.count == 1)
            .help(
                folderPaths.count == 1
                    ? "At least one folder must stay on the list."
                    : "Stop scanning this folder"
            )
        }
        .runnerCardRow()
    }

    private var actionsRow: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Button {
                addFolder()
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("Add Folder…")
                }
            }
            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))

            if isCustomized {
                Button("Reset to Defaults") {
                    FilesFolderSettings.resetToDefaults()
                    logChange(action: "reset")
                    reload()
                }
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            }
        }
        .runnerCardRow()
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
