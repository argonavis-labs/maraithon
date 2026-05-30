import Foundation

/// User-facing copy for the Full Disk Access step. Keeps onboarding,
/// banners, and tests aligned around the real permission scope: one
/// macOS grant unlocks multiple local Apple sources.
enum FullDiskAccessCopy {
    static let onboardingTitle = "Allow access to iMessage, Notes, and Voice Memos"
    static let onboardingBody = "Full Disk Access lets Maraithon read iMessage, Notes, and Voice Memos stored on this Mac. It opens those files read-only and never modifies them."
    static let openSettingsButton = "Open System Settings"
    static let continueButton = "Continue"
    static let skipButton = "Skip for now"
    static let grantedStatus = "Full Disk Access granted"
    static let autoAdvanceStatus = "Granted, continuing..."
    static let waitingStatus = "Waiting for Full Disk Access..."
    static let unblockFollowUp = "One Full Disk Access grant unlocks iMessage, Notes, and Voice Memos. After enabling Maraithon, return here and click Check again; Maraithon will recheck anything still blocked."
}
