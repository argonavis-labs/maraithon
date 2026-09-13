/// One persistent Chrome profile per account, with owned tabs per todo and loopback-only DevTools.
import Foundation
import AppKit

actor TodoChromeBrowser {
    static let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: chromeApp.path) }
    private let directory: URL
    private var connection: ChromeConnection?
    private var targets: [String: String] = [:]
    private var references: [String: BrowserPage.Reference] = [:]
    private var browserIdentity: String?

    init(accountScope: String) {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maraithon/Browser/\(accountScope)", isDirectory: true)
    }

    func disconnect() async {
        await connection?.close()
        connection = nil
        references.removeAll()
    }

    func execute(_ command: BrowserRelay.Command) async throws -> [String: String] {
        do {
            let chrome = try await ready()
            let target = try await target(for: command.todo_id, chrome: chrome)
            let attach = try await chrome.call("Target.attachToTarget", ["targetId": .string(target), "flatten": .bool(true)])
            guard let session = attach["sessionId"].string else { throw BrowserFailure("Could not connect to the todo's tab.") }
            do {
                let result = try await perform(command, chrome: chrome, target: target, session: session)
                _ = try? await chrome.call("Target.detachFromTarget", ["sessionId": .string(session)])
                return result
            } catch {
                _ = try? await chrome.call("Target.detachFromTarget", ["sessionId": .string(session)])
                throw error
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    private func perform(_ command: BrowserRelay.Command, chrome: ChromeConnection, target: String, session: String) async throws -> [String: String] {
        guard command.deadline > Date() else { throw BrowserFailure("Browser request expired before execution.") }
        switch command.operation {
        case "navigate":
            guard let raw = command.payload["url"], Self.webURL(raw) else { throw BrowserFailure("Only http(s) pages are supported.") }
            references = references.filter { $0.value.todoID != command.todo_id }
            let outcome = try await chrome.call("Page.navigate", ["url": .string(raw)], session: session)
            if outcome["errorText"].string != nil { throw BrowserFailure("Chrome could not load the requested page.") }
            try await BrowserPage.waitForDocument(chrome, session: session, loaderID: outcome["loaderId"].string)
        case "show":
            _ = try await chrome.call("Target.activateTarget", ["targetId": .string(target)])
            return ["status": "visible", "message": "The todo's Chrome tab is open on your Mac. Complete sign-in there, then ask Maraithon to inspect the page."]
        case "snapshot": break
        case "click", "fill", "press":
            guard let id = command.payload["element_id"], let reference = references[id],
                  reference.todoID == command.todo_id, reference.targetID == target else {
                throw BrowserFailure("The page snapshot changed. Inspect the page and review a new step.")
            }
            try await BrowserPage.interact(command, reference: reference, chrome: chrome, session: session)
            references = references.filter { $0.value.todoID != command.todo_id }
            return ["status": "performed", "message": "Chrome performed the reviewed step. Take a fresh snapshot to verify the website's result."]
        default: throw BrowserFailure("Unsupported browser operation.")
        }
        let snapshot = try await BrowserPage.snapshot(chrome, session: session, todoID: command.todo_id, targetID: target)
        references = references.filter { $0.value.todoID != command.todo_id }
        references.merge(snapshot.references) { _, latest in latest }
        return snapshot.result
    }

    private func ready() async throws -> ChromeConnection {
        if let connection {
            do { _ = try await connection.call("Target.getTargets"); return connection }
            catch { await disconnect() }
        }
        guard Self.isInstalled else { throw BrowserFailure("Install Google Chrome on your Mac to use browser actions.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var endpoint = await endpointIfRunning()
        if endpoint == nil {
            // LaunchServices creates a separate background instance using only Maraithon's profile.
            try await Self.launch(profile: directory.path)
            for _ in 0..<30 {
                if let found = await endpointIfRunning() { endpoint = found; break }
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        guard let endpoint else { throw BrowserFailure("Maraithon's Chrome did not start. Close its browser window and try again; your normal Chrome is unaffected.") }
        if browserIdentity != endpoint.path {
            references.removeAll()
            browserIdentity = endpoint.path
            restoreTabs(identity: endpoint.path)
        }
        let chrome = ChromeConnection(url: endpoint)
        connection = chrome
        // Browser automation cannot silently download files to the Mac.
        _ = try await chrome.call("Browser.setDownloadBehavior", ["behavior": .string("deny")])
        return chrome
    }

    private func endpointIfRunning() async -> URL? {
        let portFile = directory.appendingPathComponent("DevToolsActivePort")
        guard let text = try? String(contentsOf: portFile, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        guard lines.count >= 2, let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].hasPrefix("/devtools/browser/"),
              let endpoint = URL(string: "http://127.0.0.1:\(port)/json/version") else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let version = try? JSONDecoder().decode(BrowserJSON.self, from: data),
              let raw = version["webSocketDebuggerUrl"].string, let socket = URL(string: raw),
              socket.host == "127.0.0.1" || socket.host == "localhost",
              socket.port == port, socket.path == String(lines[1]) else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
    }

    private func target(for todoID: String, chrome: ChromeConnection) async throws -> String {
        let live = try await chrome.call("Target.getTargets")
        let liveIDs = Set(live["targetInfos"].array.compactMap { $0["targetId"].string })
        targets = targets.filter { liveIDs.contains($0.value) }
        if let target = targets[todoID] { return target }
        guard targets.count < 20 else { throw BrowserFailure("Close a finished Maraithon Chrome tab before opening another todo browser.") }
        let created = try await chrome.call("Target.createTarget", ["url": .string("about:blank"), "background": .bool(true)])
        guard let id = created["targetId"].string else { throw BrowserFailure("Could not open a todo tab.") }
        targets[todoID] = id
        try persistTabs()
        return id
    }

    private func restoreTabs(identity: String) {
        targets = [:]
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("maraithon-tabs.json")),
              let saved = try? JSONDecoder().decode([String: String].self, from: data), saved["browser"] == identity else { return }
        targets = saved.filter { $0.key != "browser" }
    }

    private func persistTabs() throws {
        var saved = targets
        saved["browser"] = browserIdentity
        let file = directory.appendingPathComponent("maraithon-tabs.json")
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func webURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
    }

    @MainActor private static func launch(profile: String) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.hides = true
        config.arguments = ["--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
            "--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", "--no-startup-window"]
        _ = try await NSWorkspace.shared.openApplication(at: chromeApp, configuration: config)
    }
}
