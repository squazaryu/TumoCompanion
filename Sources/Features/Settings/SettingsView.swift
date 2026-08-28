import SwiftUI
import UIKit

/// Applies the chosen interface style directly to the host UIWindow. Doing this at the
/// window level keeps the tab bar metrics stable when the user forces Light or Dark.
struct WindowStyleApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        apply(uiView.window, style: style)
        // The first update can happen before the representable is attached to a window.
        DispatchQueue.main.async { apply(uiView.window, style: style) }
    }

    private func apply(_ window: UIWindow?, style: UIUserInterfaceStyle) {
        if let window {
            window.overrideUserInterfaceStyle = style
            return
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        CardScroll {
            SettingsHeroCard()

            SettingsCategoryCard(
                title: "Personalization",
                subtitle: "Dolphin Gallery, theme and iOS Home Screen icon styles",
                systemImage: "paintbrush.pointed",
                tint: Theme.accent
            ) {
                PersonalizationSettingsView()
            }

            SettingsCategoryCard(
                title: "Home dashboard",
                subtitle: "Choose Tools for Quick Access and the More Tools drawer",
                systemImage: "square.grid.2x2",
                tint: Theme.purple
            ) {
                CustomizeHomeView()
            }

            SettingsCategoryCard(
                title: "Connectivity",
                subtitle: "BLE keep-alive, iPhone services and Claude Buddy passthrough",
                systemImage: "antenna.radiowaves.left.and.right",
                tint: Theme.info
            ) {
                ConnectivitySettingsView()
            }

            SettingsCategoryCard(
                title: "Automation",
                subtitle: "Local update notifications and background refresh status",
                systemImage: "bolt.badge.clock",
                tint: Theme.success
            ) {
                AutomationSettingsView()
            }

            SettingsCategoryCard(
                title: "Developer",
                subtitle: "GitHub access, App Bridge console and protocol diagnostics",
                systemImage: "wrench.and.screwdriver",
                tint: Theme.indigo
            ) {
                DeveloperSettingsView()
            }

            SettingsCategoryCard(
                title: "About",
                subtitle: "App Bridge status and onboarding",
                systemImage: "info.circle",
                tint: .secondary
            ) {
                AboutSettingsView()
            }

        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
