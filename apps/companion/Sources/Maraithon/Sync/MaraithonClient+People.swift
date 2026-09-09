/// Reads People snapshots through the paired-device bearer surface.
/// Source scans and ranking never run in the companion's synchronization pipeline.
import Foundation
import PeopleNetworkKit

extension MaraithonClient {
    func peopleNetwork(days: Int, query: String, focus: String?) async throws -> PeopleNetworkData.Network {
        let request = try await makeRequest(method: "GET", path: "/api/v1/companion/people/network", body: nil,
                                            queryItems: [URLQueryItem(name: "days", value: String(days)),
                                                         URLQueryItem(name: "q", value: query),
                                                         URLQueryItem(name: "focus", value: focus)])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(PeopleNetworkData.Network.self, from: data)
    }

    func networkPerson(days: Int, id: String) async throws -> PeopleNetworkData.Person {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw MaraithonClientError.invalidResponse
        }
        let request = try await makeRequest(method: "GET", path: "/api/v1/companion/people/network/\(escaped)", body: nil,
                                            queryItems: [URLQueryItem(name: "days", value: String(days))])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(PeopleNetworkData.PersonResponse.self, from: data).person
    }
}
