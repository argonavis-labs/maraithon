import Foundation

/// User-facing labels for companion diagnostic log metadata.
///
/// The persisted log schema keeps compact enum values so support bundles
/// stay stable. The UI should render those values as readable labels.
enum LogDisplayCopy {
    static let detailsSectionTitle = "Details"
    static let noSelectionTitle = "Select a log entry"
    static let noSelectionDescription = "Pick a row in the table to see its full details."
    static let copiedRowsHeader = "time\tlevel\tsource\tmessage\tdetails"

    static func label(for level: LogLevel) -> String {
        switch level {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    static func label(for source: LogSource) -> String {
        switch source {
        case .system: "System"
        case .auth: "Sign-in"
        case .imessage: "iMessage"
        case .notes: "Notes"
        case .voiceMemos: "Voice Memos"
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .contacts: "Contacts"
        case .browser: "Browser"
        case .files: "Files"
        case .sync: "Sync"
        case .realtime: "Live updates"
        case .cloud: "Cloud"
        case .ui: "App UI"
        }
    }
}
