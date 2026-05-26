import SwiftUI

/// Settings tab that lists every Mac currently paired to this user's
/// account. The page is read-mostly: a clean row-per-device table with a
/// "This Mac" badge on the current device and a small trash button per
/// row that revokes the bearer token on the server.
///
/// We fetch from `MaraithonClient.listDevices()` on appear (and after
/// every revoke) so the table stays in sync with the server. State is
/// kept in a `@MainActor` observable view-model so the `await` calls
/// don't fight SwiftUI's view-update isolation.
struct DevicesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var viewModel = DevicesSettingsViewModel()
    @State private var revokeTarget: CompanionDevice?

    var body: some View {
        Form {
            Section {
                content
            } header: {
                Text("Paired Macs")
            } footer: {
                Text(
                    "Each Mac you sign in shows up here. Revoking signs that Mac out — the server stops accepting its data and the row is marked revoked. Re-pair to start syncing again."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await viewModel.load(env: env) }
        .refreshable { await viewModel.load(env: env) }
        .confirmationDialog(
            confirmTitle(for: revokeTarget),
            isPresented: Binding(
                get: { revokeTarget != nil },
                set: { isPresented in if !isPresented { revokeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke device", role: .destructive) {
                if let target = revokeTarget {
                    Task { await viewModel.revoke(target, env: env) }
                }
                revokeTarget = nil
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: {
            Text(
                "This signs the Mac out and stops new data from syncing. Existing rows on the server are kept."
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            HStack(spacing: Tokens.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading paired Macs…")
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Retry") { Task { await viewModel.load(env: env) } }
            }
        case .empty:
            Text("No Macs paired yet.")
                .foregroundStyle(.secondary)
        case .loaded(let devices):
            ForEach(devices) { device in
                DeviceRow(
                    device: device,
                    isBusy: viewModel.isRevoking(device.id)
                ) {
                    revokeTarget = device
                }
            }
        }
    }

    private func confirmTitle(for device: CompanionDevice?) -> String {
        guard let name = device?.deviceName, !name.isEmpty else {
            return "Revoke this Mac?"
        }
        return "Revoke \(name)?"
    }
}

private struct DeviceRow: View {
    let device: CompanionDevice
    let isBusy: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                HStack(spacing: Tokens.Spacing.small) {
                    Text(device.deviceName ?? "Untitled Mac")
                        .font(.headline)
                    if device.isCurrent {
                        ThisMacBadge()
                    }
                    if device.revokedAt != nil {
                        RevokedBadge()
                    }
                }
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(countsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            } else if device.revokedAt == nil {
                Button {
                    onRevoke()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Revoke this device")
                .accessibilityLabel("Revoke \(device.deviceName ?? "device")")
            }
        }
        .padding(.vertical, Tokens.Spacing.xsmall)
    }

    private var metadataLine: String {
        let lastSeen = formatRelative(device.lastSeenAt) ?? "never"
        return "Last seen \(lastSeen)"
    }

    private var countsLine: String {
        let total = device.counts.total
        if total == 0 {
            return "No data synced yet"
        }
        return [
            countFragment(device.counts.messages, "messages"),
            countFragment(device.counts.notes, "notes"),
            countFragment(device.counts.voiceMemos, "voice memos"),
            countFragment(device.counts.calendarEvents, "events"),
            countFragment(device.counts.reminders, "reminders"),
            countFragment(device.counts.files, "files"),
            countFragment(device.counts.browserVisits, "visits")
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func countFragment(_ count: Int, _ label: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(label)"
    }
}

private struct ThisMacBadge: View {
    var body: some View {
        Text("This Mac")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

private struct RevokedBadge: View {
    var body: some View {
        Text("Revoked")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// View-model: owns network state for the Devices tab. Kept in this
/// file (rather than promoted to its own module) because the tab is the
/// only place that talks to `/devices` today; if we add more device
/// flows later we can extract it.
@MainActor
@Observable
final class DevicesSettingsViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case error(String)
        case empty
        case loaded([CompanionDevice])
    }

    private(set) var state: LoadState = .idle
    private var revokingIds: Set<String> = []

    /// Pluggable HTTP layer so unit tests can stub the client.
    typealias ClientFactory = @MainActor () -> MaraithonClient

    var clientFactory: ClientFactory?

    func isRevoking(_ id: String) -> Bool {
        revokingIds.contains(id)
    }

    func load(env: AppEnvironment) async {
        if case .loading = state { return }
        state = .loading
        do {
            let client = clientFactory?() ?? defaultClient(env: env)
            let response = try await client.listDevices()
            if response.devices.isEmpty {
                state = .empty
            } else {
                state = .loaded(response.devices)
            }
        } catch MaraithonClientError.unauthorized {
            state = .error("Signed out. Open General and reconnect to load devices.")
        } catch {
            state = .error("Could not load devices: \(humanError(error))")
        }
    }

    func revoke(_ device: CompanionDevice, env: AppEnvironment) async {
        revokingIds.insert(device.id)
        defer { revokingIds.remove(device.id) }
        do {
            let client = clientFactory?() ?? defaultClient(env: env)
            try await client.revokeDevice(id: device.id)
            await load(env: env)
        } catch {
            state = .error("Could not revoke: \(humanError(error))")
        }
    }

    private func defaultClient(env: AppEnvironment) -> MaraithonClient {
        let auth = env.deviceAuth
        let provider: MaraithonClient.TokenProvider = { [weak auth] in
            await MainActor.run { [auth] in auth?.currentToken }
        }
        return MaraithonClient(tokenProvider: provider)
    }

    private func humanError(_ error: Error) -> String {
        switch error {
        case MaraithonClientError.clientError(_, let body) where body?.isEmpty == false:
            return body ?? "client error"
        case MaraithonClientError.serverError(let status):
            return "server returned \(status)"
        case MaraithonClientError.transport(let message):
            return message
        default:
            return String(describing: error)
        }
    }
}

private func formatRelative(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
