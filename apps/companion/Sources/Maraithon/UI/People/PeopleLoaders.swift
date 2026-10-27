/// People reads retain paired-device authentication and report read failures without contact data.
import Foundation

@MainActor
enum PeopleLoaders {
    static func network(_ env: AppEnvironment) -> PeopleStore.Loader {
        let auth = env.deviceAuth
        let log = env.eventLog
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        return { days, query, focus in
            do { return try await client.peopleNetwork(days: days, query: query, focus: focus) }
            catch MaraithonClientError.unauthorized {
                await auth.tokenRejected()
                throw MaraithonClientError.unauthorized
            } catch {
                await log.warning("people.read_failed", source: .cloud)
                throw error
            }
        }
    }

    static func person(_ env: AppEnvironment) -> PeopleStore.DetailLoader {
        let auth = env.deviceAuth
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        return { days, id in
            do { return try await client.networkPerson(days: days, id: id) }
            catch MaraithonClientError.unauthorized {
                await auth.tokenRejected()
                throw MaraithonClientError.unauthorized
            }
        }
    }
}
