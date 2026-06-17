import SwiftUI

enum AppTab: Hashable {
    case today
    case todos
    case stream
    case crm
    case chat
}

struct AppShellView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var navigation = AppNavigation()
    @State private var identityPrefill: MobileAPIClient.IdentityResponse.Identity?
    @State private var didCheckIdentity = false
    @AppStorage("aiDataSharingConsentAccepted") private var aiConsentAccepted = false

    var body: some View {
        if aiConsentAccepted {
            shell
        } else {
            AIDataDisclosureView {
                aiConsentAccepted = true
            }
        }
    }

    private var shell: some View {
        TabView(selection: Binding(
            get: { navigation.selectedTab },
            set: { navigation.selectedTab = $0 }
        )) {
            Tab("Today", systemImage: "sparkles.rectangle.stack", value: .today) {
                TodayView()
            }

            Tab("Work", systemImage: "checklist", value: .todos) {
                TodosView()
            }

            Tab("Stream", systemImage: "wave.3.right", value: .stream) {
                StreamView()
            }

            Tab("People", systemImage: "person.2.crop.square.stack", value: .crm) {
                CRMView()
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: .chat) {
                ChatThreadsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(navigation)
        .task {
            await checkIdentity()
        }
        .sheet(item: $identityPrefill) { prefill in
            IdentityOnboardingView(prefill: prefill) {
                identityPrefill = nil
            }
        }
    }

    private func checkIdentity() async {
        guard !didCheckIdentity, let sessionToken = sessionStore.user?.sessionToken else { return }
        didCheckIdentity = true

        do {
            let identity = try await MobileAPIClient().getIdentity(sessionToken: sessionToken)
            if !identity.confirmed {
                identityPrefill = identity
            }
        } catch {
            // Identity onboarding is best-effort; the next launch retries.
        }
    }
}
