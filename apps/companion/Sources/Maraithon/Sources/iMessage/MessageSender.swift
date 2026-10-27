/// Executes one explicitly approved send through Messages. User text is passed
/// as Apple event arguments, never executable source. A timeout is never retried.
import Foundation
import Carbon

enum MessageSender {
    private static let queue = DispatchQueue(label: "com.maraithon.messages.send", qos: .userInitiated)
    static func send(recipient: String, body: String) async -> [String: String] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: execute(recipient: recipient, body: body))
            }
        }
    }

    private static func execute(recipient: String, body: String) -> [String: String] {
        let source = """
        on deliverMessage(recipientHandle, messageBody)
            with timeout of 25 seconds
                tell application "Messages"
                    set sendingAccount to first account whose service type is iMessage and enabled is true
                    set destination to participant recipientHandle of sendingAccount
                    send messageBody to destination
                end tell
            end timeout
            return "sent"
        end deliverMessage
        """
        guard !recipient.isEmpty, !body.isEmpty, body.utf8.count <= 16_384,
              let script = NSAppleScript(source: source) else {
            return ["status": "failed", "error": "The message is empty or too long."]
        }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: recipient), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: body), at: 2)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "deliverMessage"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if error == nil && result.stringValue == "sent" {
            return ["status": "sent", "sent_at": ISO8601DateFormatter().string(from: Date())]
        }
        let code = error?[NSAppleScript.errorNumber] as? Int
        if code == -1743 || code == -1744 {
            return ["status": "failed", "error": "Allow Maraithon to control Messages in System Settings → Privacy & Security → Automation, then prepare the message again."]
        }
        if code == -1728 || code == -600 {
            return ["status": "failed", "error": "Open Messages on your Mac and sign in to iMessage, then prepare the message again."]
        }
        return ["status": "unknown", "error": "Messages did not confirm the send. Check the conversation before trying again."]
    }
}
