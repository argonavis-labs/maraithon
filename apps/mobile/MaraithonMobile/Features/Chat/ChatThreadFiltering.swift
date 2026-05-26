import Foundation

enum ChatThreadFiltering {
    static func filter(_ threads: [ChatThread], searchText: String) -> [ChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return threads }

        return threads.filter { thread in
            searchableValues(for: thread).contains { value in
                value.lowercased().contains(query)
            }
        }
    }

    private static func searchableValues(for thread: ChatThread) -> [String] {
        [thread.title] + thread.messages.map(\.body)
    }
}
