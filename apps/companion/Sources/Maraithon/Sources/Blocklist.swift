import Foundation
import Observation

/// Local-only list of handles (phone numbers or emails) the user has opted
/// out of syncing. Filtering happens before push, so the server never sees
/// blocked entries.
///
/// The list is persisted to `UserDefaults` under a stable key; on first
/// run it is empty.
@Observable
@MainActor
final class Blocklist {
    private(set) var handles: Set<String> = []
    private let defaultsKey = "com.maraithon.companion.blocklist"

    init() {
        if let array = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            self.handles = Set(array)
        }
    }

    func contains(_ handle: String) -> Bool {
        handles.contains(canonicalize(handle))
    }

    func add(_ handle: String) {
        handles.insert(canonicalize(handle))
        persist()
    }

    func remove(_ handle: String) {
        handles.remove(canonicalize(handle))
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(handles), forKey: defaultsKey)
    }

    /// Best-effort handle normalisation. Phones get `+` and digits only;
    /// emails get lowercased. Anything else is passed through unchanged.
    private func canonicalize(_ handle: String) -> String {
        if handle.contains("@") {
            return handle.lowercased()
        }
        let digits = handle.filter { $0.isNumber || $0 == "+" }
        return digits
    }
}
