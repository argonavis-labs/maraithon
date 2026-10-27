import SwiftUI
import UIKit

/// Applies the workspace theme to the UIKit chrome SwiftUI still draws:
/// navigation bars, tab bars, and the tint. Call once at launch.
enum RunnerAppearance {
    @MainActor
    static func apply() {
        let background = Runner.Palette.backgroundShade
        let foreground = Runner.Palette.foregroundShade
        let ink = UIColor { traits in
            (traits.userInterfaceStyle == .dark ? foreground.dark : foreground.light).uiColor
        }
        let ground = UIColor { traits in
            (traits.userInterfaceStyle == .dark ? background.dark : background.light).uiColor
        }
        let hairline = UIColor { traits in
            (traits.userInterfaceStyle == .dark ? foreground.dark : foreground.light).withAlpha(0.1).uiColor
        }

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = ground
        navigation.shadowColor = hairline
        navigation.titleTextAttributes = [.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 16, weight: .semibold)]
        navigation.largeTitleTextAttributes = [.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 26, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = ground
        tabs.shadowColor = hairline
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
    }
}

extension View {
    /// Page container: workspace background behind lists and scroll views,
    /// themed bars, terracotta tint for interactive elements.
    func runnerPage() -> some View {
        self
            .background(Runner.Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .tint(Runner.Palette.accent)
            .toolbarBackground(Runner.Palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
