/// Native network destination. Reads use the current paired-device credential.
/// This view owns no ingestion tasks and cannot delay local source synchronization.
import SwiftUI
import PeopleNetworkKit

struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    let openTodo: (String) -> Void

    var body: some View {
        let auth = env.deviceAuth
        let log = env.eventLog
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        PeopleNetworkExplorer(
            loadNetwork: { days, query, focus in
                do {
                    return try await client.peopleNetwork(days: days, query: query, focus: focus)
                } catch MaraithonClientError.unauthorized {
                    await auth.tokenRejected()
                    throw MaraithonClientError.unauthorized
                } catch {
                    await log.warning("people.read_failed", source: .cloud)
                    throw error
                }
            },
            loadPerson: { days, id in
                do { return try await client.networkPerson(days: days, id: id) }
                catch MaraithonClientError.unauthorized {
                    await auth.tokenRejected()
                    throw MaraithonClientError.unauthorized
                }
            },
            openTodo: openTodo,
            managePerson: { id in
                var components = URLComponents(url: MaraithonClient.defaultBaseURL, resolvingAgainstBaseURL: false)
                components?.path = "/operator/people/manage"
                components?.queryItems = id.map { [URLQueryItem(name: "person_id", value: $0)] }
                if let url = components?.url { openURL(url) }
            }
        )
    }
}
