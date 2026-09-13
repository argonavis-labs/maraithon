import SwiftUI

/// Workspace sidebar: brand, task search, Workspace destinations, the Mac
/// sources this app syncs, and the connection, appearance, and account
/// rows pinned to the bottom. Styled after the web workspace shell rather
/// than the stock macOS sidebar so both apps read as one product.
///
/// Keep `SidebarItem` and `RootWindow.detailView` in sync when adding
/// top-level destinations.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: SidebarItem?
    /// Fired by the "Find a task" row; the root window routes it to the
    /// task list's search field.
    let requestSearch: () -> Void

    /// Developer-only surfaces (Logs pane, Settings → Diagnostics tab)
    /// are gated on this flag. Toggle in Settings → General →
    /// Developer mode. Defaults off so the day-to-day sidebar stays
    /// clean for non-debug use.
    @AppStorage("developer_mode") private var developerMode: Bool = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarBrand { selection = .todos }
                .padding(.bottom, Tokens.Spacing.large)

            SidebarSearchRow(action: requestSearch)
                .padding(.bottom, Tokens.Spacing.large)

            SidebarSectionLabel("Workspace")
            SidebarNavRow(title: "Tasks", symbol: "checkmark.square", isActive: selection == .todos) {
                selection = .todos
            }
            SidebarNavRow(title: "People", symbol: "person.2", isActive: selection == .people) {
                selection = .people
            }
            SidebarNavRow(title: "Recall", symbol: "magnifyingglass", isActive: selection == .recall) {
                selection = .recall
            }

            SidebarSectionLabel("Mac sources")
                .padding(.top, Tokens.Spacing.large)
            ForEach(env.sources.sources) { source in
                SidebarSourceRow(source: source, isActive: selection == .source(id: source.id)) {
                    selection = .source(id: source.id)
                }
            }

            if developerMode {
                SidebarSectionLabel("Developer")
                    .padding(.top, Tokens.Spacing.large)
                SidebarNavRow(title: "Logs", symbol: "list.bullet.rectangle", isActive: selection == .logs) {
                    selection = .logs
                }
            }

            Spacer(minLength: Tokens.Spacing.xlarge)

            SidebarConnectionRow(isPaused: env.isPaused)
            SidebarNavRow(
                title: "Appearance",
                symbol: "circle.lefthalf.filled",
                trailing: appearance.label,
                isActive: false
            ) {
                appearanceRaw = appearance.next.rawValue
            }
            .accessibilityLabel("Appearance, \(appearance.label)")
            .accessibilityHint("Cycles between System, Light, and Dark")

            if case .signedIn(let account) = env.deviceAuth.state {
                SidebarAccountRow(account: account) {
                    env.deviceAuth.signOut()
                }
                .padding(.top, Tokens.Spacing.small)
            }
        }
        .padding(.top, Tokens.Layout.sidebarTopInset)
        .padding(.horizontal, Tokens.Layout.sidebarHorizontalInset)
        .padding(.bottom, Tokens.Spacing.tight)
        .frame(width: Tokens.Layout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.Palette.background)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(width: Tokens.Stroke.hairline)
        }
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
}

/// Small muted heading above each sidebar group.
struct SidebarSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.mutedForeground)
            .padding(.horizontal, Tokens.Spacing.snug)
            .padding(.bottom, Tokens.Spacing.compact)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Find a task" row: looks like a search field, acts as a shortcut to the
/// task list's search box.
private struct SidebarSearchRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .font(Tokens.Typography.small)
                Text("Find a task")
                    .font(Tokens.Typography.small)
                Spacer(minLength: Tokens.Spacing.xsmall)
                RunnerKeyCap(key: "/")
            }
            .foregroundStyle(hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
            .padding(.horizontal, Tokens.Spacing.snug)
            .padding(.vertical, Tokens.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Find a task")
        .accessibilityHint("Focuses the task search field")
    }
}

/// Connection status pinned above the account row.
private struct SidebarConnectionRow: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.compact + 1) {
            Circle()
                .fill(isPaused ? Tokens.Palette.statusOffline : Tokens.Palette.statusOnline)
                .frame(width: Tokens.Layout.statusDotSize, height: Tokens.Layout.statusDotSize)
            Text(isPaused ? "Paused" : "Connected")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
        }
        .padding(Tokens.Spacing.snug)
        .accessibilityElement(children: .combine)
    }
}
