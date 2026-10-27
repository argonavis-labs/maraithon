import Foundation

enum AppConfiguration {
    private enum Keys {
        static let mobileAPIBaseURL = "MaraithonMobileAPIBaseURL"
    }

    // Evaluated once; a missing or invalid Info.plist value still traps on
    // first access, matching the old computed-var precondition semantics
    // without re-parsing the plist on every request.
    static let mobileAPIBaseURL: URL = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: Keys.mobileAPIBaseURL) as? String,
              let url = URL(string: value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("Missing or invalid \(Keys.mobileAPIBaseURL) in Info.plist.")
        }

        return url
    }()
}
