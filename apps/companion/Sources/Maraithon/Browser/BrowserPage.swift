/// Page snapshots issue opaque local references. Interactions recheck the exact URL and accessible label.
import Foundation

enum BrowserPage {
    struct Reference: Sendable {
        let todoID: String
        let targetID: String
        let backendID: Int
        let label: String
        let url: String
    }
    struct Snapshot: Sendable { let result: [String: String]; let references: [String: Reference] }

    static func snapshot(_ chrome: ChromeConnection, session: String, todoID: String, targetID: String) async throws -> Snapshot {
        let info = try await location(chrome, session: session)
        guard let url = info["url"].string, TodoChromeBrowser.webURL(url) else {
            return Snapshot(result: ["status": "empty", "message": "The todo browser is ready. Navigate to an exact http(s) source URL."], references: [:])
        }
        let tree = try await chrome.call("Accessibility.getFullAXTree", [:], session: session)
        var references: [String: Reference] = [:]
        var lines: [String] = []
        var bytes = 0
        let interactive = Set(["button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "menuitem", "tab"])
        for node in tree["nodes"].array {
            if case .bool(true) = node["ignored"] { continue }
            let role = node["role"]["value"].string ?? ""
            let label = String((node["name"]["value"].string ?? "").prefix(300))
            guard !label.isEmpty, !["InlineTextBox", "generic", "none"].contains(role) else { continue }
            var line = "\(role): \(label)"
            if interactive.contains(role), let backendID = node["backendDOMNodeId"].integer {
                let id = UUID().uuidString.lowercased()
                references[id] = Reference(todoID: todoID, targetID: targetID, backendID: backendID, label: label, url: url)
                line = "[\(id)] " + line
            }
            guard bytes + line.utf8.count < 22_000, lines.count < 220 else { break }
            bytes += line.utf8.count
            lines.append(line)
        }
        return Snapshot(result: ["url": url, "title": info["title"].string ?? "", "snapshot": lines.joined(separator: "\n"),
            "message": "Read the live page in Chrome on your Mac."], references: references)
    }

    static func interact(_ command: BrowserRelay.Command, reference: Reference, chrome: ChromeConnection, session: String) async throws {
        let info = try await location(chrome, session: session)
        guard info["url"].string == reference.url, command.payload["url"] == reference.url,
              command.payload["label"] == reference.label else { throw BrowserFailure("The page or element changed since review. Inspect it and prepare a fresh step.") }
        let current = try await chrome.call("Accessibility.getPartialAXTree", ["backendNodeId": .number(Double(reference.backendID)), "fetchRelatives": .bool(false)], session: session)
        guard current["nodes"].array.contains(where: { String(($0["name"]["value"].string ?? "").prefix(300)) == reference.label }) else {
            throw BrowserFailure("The reviewed element changed. Inspect the page again.")
        }
        let resolved = try await chrome.call("DOM.resolveNode", ["backendNodeId": .number(Double(reference.backendID))], session: session)
        guard let objectID = resolved["object"]["objectId"].string else { throw BrowserFailure("The reviewed element no longer exists.") }
        guard command.deadline > Date() else { throw BrowserFailure("Browser request expired before interaction.") }
        let params: [String: BrowserJSON] = ["objectId": .string(objectID), "functionDeclaration": .string(interactionFunction),
            "arguments": .array([.object(["value": .string(command.operation)]), .object(["value": .string(command.payload["text"] ?? "")])]),
            "returnByValue": .bool(true), "userGesture": .bool(true)]
        let result = try await chrome.call("Runtime.callFunctionOn", params, session: session)
        guard result["exceptionDetails"]["text"].string == nil, result["result"]["value"].string == "ok" else {
            throw BrowserFailure("This element cannot be automated safely. Open the browser to complete the step, then inspect the page.")
        }
        if command.operation == "press" {
            let key = command.payload["text"] ?? ""
            let codes = ["Enter": 13, "Tab": 9, "Escape": 27]
            guard let code = codes[key] else { throw BrowserFailure("Unsupported browser key.") }
            _ = try await chrome.call("Input.dispatchKeyEvent", ["type": .string("keyDown"), "key": .string(key), "code": .string(key),
                "windowsVirtualKeyCode": .number(Double(code)), "text": .string(key == "Enter" ? "\r" : "")], session: session)
            _ = try await chrome.call("Input.dispatchKeyEvent", ["type": .string("keyUp"), "key": .string(key), "code": .string(key)], session: session)
        }
    }

    static func waitForDocument(_ chrome: ChromeConnection, session: String, loaderID: String?) async throws {
        for _ in 0..<12 {
            let frame = try? await chrome.call("Page.getFrameTree", [:], session: session)
            let navigated = loaderID == nil || frame?["frameTree"]["frame"]["loaderId"].string == loaderID
            let state = try? await chrome.call("Runtime.evaluate", ["expression": .string("document.readyState"), "returnByValue": .bool(true)], session: session)
            if navigated && ["interactive", "complete"].contains(state?["result"]["value"].string ?? "") { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func location(_ chrome: ChromeConnection, session: String) async throws -> BrowserJSON {
        let result = try await chrome.call("Runtime.evaluate", ["expression": .string("({url: location.href, title: document.title})"), "returnByValue": .bool(true)], session: session)
        return result["result"]["value"]
    }

    // Fixed application code, never model-supplied JavaScript. Passwords,
    // uploads and authentication fields require the user's visible browser.
    private static let interactionFunction = #"""
    function(operation, text) {
      if (!this.isConnected || this.disabled || this.getClientRects().length === 0) return 'stale';
      if (this.matches('input[type=password],input[type=file],[autocomplete=one-time-code],[autocomplete=current-password],[autocomplete=new-password]')) return 'manual';
      if (operation === 'click') {
        if (this.tagName === 'A') {
          const url = new URL(this.href, location.href);
          if (!['https:', 'http:'].includes(url.protocol)) return 'manual';
          this.target = '_self';
        }
        this.click(); return 'ok';
      }
      this.focus();
      if (operation === 'press') return 'ok';
      if (operation !== 'fill') return 'unsupported';
      if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement) {
        const prototype = this instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, 'value').set.call(this, text);
      } else if (this.isContentEditable) this.textContent = text;
      else return 'manual';
      this.dispatchEvent(new Event('input', {bubbles: true}));
      this.dispatchEvent(new Event('change', {bubbles: true}));
      return 'ok';
    }
    """#
}
