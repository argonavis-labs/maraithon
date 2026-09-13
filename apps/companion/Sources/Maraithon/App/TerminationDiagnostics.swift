import AppKit
import Foundation

/// App delegate that records how the process ends. Graceful terminations
/// log the caller's stack; fatal signals write a marker file before the
/// default handler runs so a silent exit still leaves evidence. Signal
/// hooks are DEBUG-only.
@MainActor
final class TerminationDiagnostics: NSObject, NSApplicationDelegate {
    var eventLog: EventLog?

    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ignorePoliteKills()
        #if DEBUG
        Self.installSignalMarkers()
        #endif
    }

    /// Maraithon Desktop (the Electron app) sends SIGTERM to any process
    /// whose bundle id is `com.maraithon.companion` once it holds its own
    /// device token, to retire the old companion. This app is the native
    /// workspace, not that companion, so it stays up and records the attempt.
    /// Quit still works through the menu, Cmd-Q, and Activity Monitor.
    private func ignorePoliteKills() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.eventLog?.warning("app.sigterm_ignored", source: .system, payload: ["from": "external process"])
            }
        }
        source.resume()
        termSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let stack = Thread.callStackSymbols.prefix(14).map { String($0.suffix(90)) }.joined(separator: " | ")
        eventLog?.info("app.should_terminate", source: .system, payload: ["stack": stack])
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventLog?.info("app.will_terminate", source: .system)
    }

    #if DEBUG
    /// Marker path: ~/Library/Logs/Maraithon/last_signal.txt
    private static func installSignalMarkers() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Maraithon", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let path = logs.appendingPathComponent("last_signal.txt").path
        signalMarkerDescriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGPIPE, SIGFPE] {
            signal(sig, signalMarkerHandler)
        }
    }
    #endif
}

#if DEBUG
nonisolated(unsafe) private var signalMarkerDescriptor: Int32 = -1

private let signalMarkerHandler: @convention(c) (Int32) -> Void = { sig in
    // Async-signal-safe only: write a fixed message, then let the default action run.
    if signalMarkerDescriptor >= 0 {
        var text: [UInt8] = Array("signal ".utf8)
        var digits: [UInt8] = []
        var value = sig
        if value == 0 { digits = [48] }
        while value > 0 { digits.insert(UInt8(48 + value % 10), at: 0); value /= 10 }
        text.append(contentsOf: digits)
        text.append(10)
        text.withUnsafeBufferPointer { _ = write(signalMarkerDescriptor, $0.baseAddress, $0.count) }
        fsync(signalMarkerDescriptor)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
#endif
