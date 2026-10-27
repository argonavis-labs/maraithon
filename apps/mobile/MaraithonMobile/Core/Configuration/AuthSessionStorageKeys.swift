enum AuthSessionStorageKeys {
    static let authenticatedUser = "maraithon.authenticatedUser"
    /// Mirrors the `@AppStorage` key in `AppShellView`; cleared on sign-out so
    /// the next account re-confirms AI data sharing.
    static let aiConsentAccepted = "aiDataSharingConsentAccepted"
}
