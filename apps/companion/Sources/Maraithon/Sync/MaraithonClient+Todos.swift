/// Todo requests fetch every page before replacing the visible collection.
/// Mutations stay scoped to the paired device's authenticated user.
import Foundation
import AssistantProgressKit

extension MaraithonClient {
    func transitionTodo(id: String, change: TodoWorkflowChange) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(method: "POST", path: "/api/v1/companion/todos/\(id)/workflow",
            body: try JSONEncoder().encode(change), extraHeaders: ["Content-Type": "application/json"])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
    }

    func createTodo(_ draft: CompanionTodoDraft) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/todos",
            body: try JSONEncoder().encode(draft),
            extraHeaders: ["Content-Type": "application/json"]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
    }

    func listTodos(
        filter: TodoListFilter,
        query: String? = nil
    ) async throws -> CompanionTodosResponse {
        var offset = 0
        var todos: [CompanionTodo] = []
        var seenIDs = Set<String>()

        // Bound a malformed server response without presenting a partial list
        // as complete. Fifty pages accommodates 10,000 todos per filter.
        for _ in 0..<50 {
            try Task.checkCancellation()
            let page = try await todoPage(filter: filter, query: query, offset: offset)
            for todo in page.todos where seenIDs.insert(todo.id).inserted {
                todos.append(todo)
            }

            guard let nextOffset = page.pagination.nextOffset else {
                return CompanionTodosResponse(
                    todos: todos,
                    pagination: CompanionTodoPagination(
                        limit: page.pagination.limit,
                        offset: 0,
                        count: todos.count,
                        nextOffset: nil
                    )
                )
            }
            guard nextOffset > offset, !page.todos.isEmpty else {
                throw MaraithonClientError.invalidResponse
            }
            offset = nextOffset
        }
        throw MaraithonClientError.invalidResponse
    }

    /// Lists Todos through the paired-device bearer surface. The server
    /// derives the account from the token; the client never sends a user id.
    private func todoPage(
        filter: TodoListFilter,
        query: String?,
        offset: Int
    ) async throws -> CompanionTodosResponse {
        var queryItems = [
            URLQueryItem(name: "status", value: filter.rawValue),
            URLQueryItem(name: "sort", value: filter == .active ? "rank" : "updated"),
            URLQueryItem(name: "dir", value: "desc"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_cards", value: "false"),
            URLQueryItem(name: "open_cards_only", value: "true")
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/todos",
            body: nil,
            queryItems: queryItems
        )
        var retries = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse,
               retries < 3,
               [429, 502, 503, 504].contains(http.statusCode),
               let delay = Self.todoReadRetryDelay(http, retries: retries) {
                retries += 1
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            try Self.validate(response: response, data: data)
            return try JSONDecoder().decode(CompanionTodosResponse.self, from: data)
        }
    }

    /// Retry only the current read page. Keep prior pages and honor short
    /// server cooldowns without leaving a manual refresh waiting indefinitely.
    private static func todoReadRetryDelay(_ response: HTTPURLResponse, retries: Int) -> TimeInterval? {
        let fallback = pow(2.0, Double(retries))
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return fallback }

        let delay: TimeInterval
        if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
            delay = seconds
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: header) else { return fallback }
            delay = max(0, date.timeIntervalSinceNow)
        }
        return delay <= 30 ? max(1, delay) : nil
    }

    /// Sends only after the user reviews and confirms the exact message.
    func sendTodoReply(id: String, body: String, subject: String) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(method: "POST", path: "/api/v1/companion/todos/\(id)/reply",
            body: try JSONEncoder().encode(["body": body, "subject": subject]),
            extraHeaders: ["Content-Type": "application/json"])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
    }

    func markTodoOpened(id: String) async throws {
        let request = try await makeRequest(method: "POST", path: "/api/v1/companion/todos/\(id)/opened", body: nil)
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
    }

    /// Fetches richer source context only for the item being inspected.
    func todoDetails(id: String) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/todos/\(id)",
            body: nil,
            queryItems: [URLQueryItem(name: "include_cards", value: "true")]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let details = try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
        guard details.todo.id == id else { throw MaraithonClientError.invalidResponse }
        return details
    }

    /// Completes, dismisses, or reopens a Todo through the paired-device
    /// least-privilege action surface.
    func updateTodo(id: String, action: CompanionTodoAction) async throws -> CompanionTodoActionResponse {
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/todos/\(id)/actions/\(action.rawValue)",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoActionResponse.self, from: data)
    }

}
