import SwiftUI

/// `Commands` group that adds **Help → Export Diagnostic Bundle…** to the
/// main menu. Drop into `MaraithonApp.commands` once.
///
/// The actual export work lives in `DiagnosticExporter`. This file is the
/// menu glue + the bundle of UI niceties — toast text, success/failure
/// reporting — so the exporter itself stays SwiftUI-free.
struct DiagnosticExportCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button("Export Diagnostic Bundle…") {
                let captured = env
                Task { @MainActor in
                    DiagnosticExportCommands.exportBundle(env: captured)
                }
            }
            .accessibilityLabel("Export diagnostic bundle to Downloads")
        }
    }

    /// Run the exporter against the live environment. Public so the
    /// diagnostics view can offer the same action inline (e.g., a
    /// "Generate diagnostic bundle" button on the pane).
    @MainActor
    static func exportBundle(env: AppEnvironment) {
        let log = env.eventLog
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log.info("diagnostics.export.started", source: .system)
        do {
            _ = try DiagnosticExporter.export(
                log: log,
                deviceId: env.deviceAuth.deviceId,
                appVersion: version,
                recentEntries: log.entries
            )
        } catch {
            log.error(
                "diagnostics.export.failed",
                source: .system,
                payload: ["error": String(describing: error)]
            )
        }
    }
}
