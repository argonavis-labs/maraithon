import Foundation
import Observation
import PeopleNetworkKit

/// Main-actor state for the People page. Loads only the visible network;
/// request versions keep a stale response from replacing a newer one. The
/// selected person's evidence loads on the pushed person page itself.
@MainActor
@Observable
final class PeopleNetworkPageStore {
    typealias Loader = @Sendable (Int, String, String?) async throws -> PeopleNetworkData.Network
    typealias DetailLoader = @Sendable (Int, String) async throws -> PeopleNetworkData.Person

    var network: PeopleNetworkData.Network?
    var selectedID: String?
    var connection: PeopleNetworkData.Edge?
    var error: String?
    var loading = false

    private var networkVersion = UUID()

    func load(days: Int, query: String, loader: Loader) async {
        let version = UUID()
        networkVersion = version
        loading = true
        defer { if networkVersion == version { loading = false } }
        do {
            let result = try await loader(days, query, selectedID)
            try Task.checkCancellation()
            guard networkVersion == version else { return }
            network = result
            error = nil
        } catch is CancellationError {
        } catch {
            guard networkVersion == version, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
