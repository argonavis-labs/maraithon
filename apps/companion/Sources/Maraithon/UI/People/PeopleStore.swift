import Foundation
import Observation
import PeopleNetworkKit

/// Main-actor state for the People page. Loads only the visible network and
/// the selected person's evidence; request versions keep stale responses
/// from replacing a newer selection.
@MainActor
@Observable
final class PeopleStore {
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
        guard let selectedID else {
            loadingPerson = false
            return
        }
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
