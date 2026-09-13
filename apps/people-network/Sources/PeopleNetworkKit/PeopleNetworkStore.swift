/// Loads only the visible network and selected person's evidence.
/// Cancellation and request versions prevent stale responses replacing a new selection.
import Foundation
import Observation

@MainActor @Observable
final class PeopleNetworkStore {
    typealias Loader = @Sendable (Int, String, String?) async throws -> PeopleNetworkData.Network
    typealias DetailLoader = @Sendable (Int, String) async throws -> PeopleNetworkData.Person

    var network: PeopleNetworkData.Network?
    var person: PeopleNetworkData.Person?
    var selectedID: String?
    var connection: PeopleNetworkData.Edge?
    var error: String?
    var detailError: String?
    var loading = false
    var loadingPerson = false
    private var networkVersion = UUID()
    private var detailVersion = UUID()

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
            connection = nil
            error = nil
        } catch is CancellationError {
        } catch {
            guard networkVersion == version, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func detail(days: Int, loader: DetailLoader) async {
        let version = UUID()
        detailVersion = version
        person = nil
        detailError = nil
        guard let selectedID else { loadingPerson = false; return }
        loadingPerson = true
        defer { if detailVersion == version { loadingPerson = false } }
        do {
            let result = try await loader(days, selectedID)
            try Task.checkCancellation()
            guard detailVersion == version, self.selectedID == selectedID else { return }
            person = result
        } catch is CancellationError {
        } catch {
            guard detailVersion == version, !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
    }
}
