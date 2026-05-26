import Foundation

enum AppConfiguration {
    private enum Keys {
        static let mobileAPIBaseURL = "MaraithonMobileAPIBaseURL"
    }

    static var mobileAPIBaseURL: URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: Keys.mobileAPIBaseURL) as? String,
              let url = URL(string: value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("Missing or invalid \(Keys.mobileAPIBaseURL) in Info.plist.")
        }

        return url
    }
}
