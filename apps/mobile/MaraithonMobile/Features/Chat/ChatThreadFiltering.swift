import Foundation

enum ChatThreadFiltering {
    static func filter(_ threads: [ChatThread], searchText: String) -> [ChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }

        return threads.filter { thread in
            if thread.title.localizedCaseInsensitiveContains(query) {
                return true
            }

            return thread.messages.contains { message in
                message.body.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
