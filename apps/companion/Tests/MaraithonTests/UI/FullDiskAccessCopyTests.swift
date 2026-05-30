import XCTest
@testable import Maraithon

final class FullDiskAccessCopyTests: XCTestCase {
    func testOnboardingCopyNamesAllBlockedLocalSources() {
        XCTAssertEqual(
            FullDiskAccessCopy.onboardingTitle,
            "Allow access to iMessage, Notes, and Voice Memos"
        )
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("iMessage"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("Notes"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("Voice Memos"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("read-only"))
        XCTAssertFalse(FullDiskAccessCopy.onboardingTitle.localizedCaseInsensitiveContains("local source"))
        XCTAssertFalse(FullDiskAccessCopy.onboardingBody.localizedCaseInsensitiveContains("database is"))
    }

    func testOnboardingActionsAvoidSingleSourceSetupLanguage() {
        XCTAssertEqual(FullDiskAccessCopy.openSettingsButton, "Open System Settings")
        XCTAssertEqual(FullDiskAccessCopy.continueButton, "Continue")
        XCTAssertEqual(FullDiskAccessCopy.skipButton, "Skip for now")
        XCTAssertFalse(FullDiskAccessCopy.skipButton.localizedCaseInsensitiveContains("iMessage"))
        XCTAssertFalse(FullDiskAccessCopy.skipButton.localizedCaseInsensitiveContains("local source"))
    }

    func testUnblockFollowUpDoesNotRequireARestart() {
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("One Full Disk Access grant"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("iMessage"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("Notes"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("Voice Memos"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("Check again"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("anything still blocked"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("local source"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("quit"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("reopen"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("restart"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("relaunch"))
    }

    func testInstallHintFlagsDerivedDataBuilds() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/Library/Developer/Xcode/DerivedData/Maraithon/Build/Products/Debug/Maraithon.app",
            isDirectory: true
        )

        let message = FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home)

        XCTAssertTrue(message?.contains("temporary Maraithon copy") == true)
        XCTAssertTrue(message?.contains("~/Applications/Maraithon.app") == true)
        XCTAssertFalse(message?.contains("make run-companion") == true)
        XCTAssertFalse(message?.contains("xcodebuild") == true)
        XCTAssertFalse(message?.contains("DerivedData") == true)
    }

    func testInstallHintFlagsRepoLocalAppBundles() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/bliss/maraithon/apps/companion/build/Debug/Maraithon.app",
            isDirectory: true
        )

        XCTAssertNotNil(FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home))
    }

    func testInstallHintFlagsSwiftPMBuilds() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/bliss/maraithon/apps/companion/.build/debug/Maraithon",
            isDirectory: false
        )

        XCTAssertNotNil(FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home))
    }

    func testInstallHintAllowsStableDevelopmentApp() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)

        XCTAssertNil(FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home))
    }

    func testInstallHintIncludesStableAppStatusAndURL() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("maraithon-fda-hint-\(UUID().uuidString)", isDirectory: true)
        let stableApp = home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)
        let bundle = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
            .appendingPathComponent("Maraithon", isDirectory: true)
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Debug", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)

        try fileManager.createDirectory(at: stableApp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let detail = FullDiskAccessInstallHint.detail(
            for: bundle,
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertEqual(detail?.stableAppURL.path, stableApp.standardizedFileURL.path)
        XCTAssertTrue(detail?.stableAppInstalled == true)
        XCTAssertEqual(FullDiskAccessInstallHint.switchToStableAppButtonTitle, "Switch to stable app")
        XCTAssertEqual(FullDiskAccessInstallHint.installStableAppButtonTitle, "Install stable app")
        XCTAssertTrue(detail?.canInstallStableApp == true)
        XCTAssertTrue(detail?.message.contains("Switch to the stable app") == true)
        XCTAssertTrue(detail?.message.contains("before opening System Settings") == true)
    }

    func testInstallHintMarksStableAppMissing() {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/Library/Developer/Xcode/DerivedData/Maraithon/Build/Products/Debug/Maraithon.app",
            isDirectory: true
        )

        let detail = FullDiskAccessInstallHint.detail(
            for: bundle,
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertFalse(detail?.stableAppInstalled == true)
        XCTAssertTrue(detail?.canInstallStableApp == true)
        XCTAssertTrue(detail?.message.contains("Install the stable app") == true)
    }

    func testInstallHintDoesNotOfferInstallForSwiftPMBinary() {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/bliss/maraithon/apps/companion/.build/debug/Maraithon",
            isDirectory: false
        )

        let detail = FullDiskAccessInstallHint.detail(
            for: bundle,
            homeDirectory: home,
            fileManager: fileManager
        )

        XCTAssertFalse(detail?.stableAppInstalled == true)
        XCTAssertFalse(detail?.canInstallStableApp == true)
    }

    func testStableAppInstallCopiesTemporaryBundleToStablePath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("maraithon-fda-install-\(UUID().uuidString)", isDirectory: true)
        let source = root
            .appendingPathComponent("DerivedData", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)
        let sourceContents = source.appendingPathComponent("Contents", isDirectory: true)
        let stable = root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)

        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceContents, withIntermediateDirectories: true)
        try "new bundle".write(
            to: sourceContents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        try FullDiskAccessInstallHint.copyStableDevelopmentApp(
            from: source,
            to: stable,
            fileManager: fileManager
        )

        let copiedInfo = stable
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        XCTAssertTrue(fileManager.fileExists(atPath: copiedInfo.path))
    }

    func testStableAppInstallRefreshesExistingBundleContents() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("maraithon-fda-refresh-\(UUID().uuidString)", isDirectory: true)
        let source = root
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)
        let stable = root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)

        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stable, withIntermediateDirectories: true)
        try "old".write(
            to: stable.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "new".write(
            to: source.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        try FullDiskAccessInstallHint.copyStableDevelopmentApp(
            from: source,
            to: stable,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: stable.appendingPathComponent("old.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: stable.appendingPathComponent("new.txt").path))
    }
}
