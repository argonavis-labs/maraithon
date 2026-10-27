/// Authenticated, bounded reads of the independent People projection.
import Foundation
import PeopleNetworkKit

extension MobileAPIClient {
    func peopleNetwork(sessionToken: String, days: Int, query: String, focus: String?) async throws -> PeopleNetworkData.Network {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "days", value: String(days)),
                                 URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "focus", value: focus)]
        return try await send(path: "/people/network?\(components.percentEncodedQuery ?? "")",
                              sessionToken: sessionToken, responseType: PeopleNetworkData.Network.self)
    }

    func networkPerson(sessionToken: String, days: Int, id: String) async throws -> PeopleNetworkData.Person {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw MobileAPIError.invalidRequest
        }
        let response = try await send(path: "/people/network/\(escaped)?days=\(days)",
                                       sessionToken: sessionToken, responseType: PeopleNetworkData.PersonResponse.self)
        return response.person
    }
}
