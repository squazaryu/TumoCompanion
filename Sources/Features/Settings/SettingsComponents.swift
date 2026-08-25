import SwiftUI

enum AppIconOption: String, CaseIterable, Identifiable {
    case orange, dolphin, green, purple, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orange:  return "System"
        case .dolphin: return "Light"
        case .green:   return "Dark"
        case .purple:  return "Clear · Light"
        case .mono:    return "Clear · Dark"
        }
    }

    /// nil = primary AppIcon. This is also the name used by UIImage for previews.
    var alternateName: String? {
        switch self {
        case .orange:  return nil
        case .dolphin: return "AppIcon-Dolphin"
        case .green:   return "AppIcon-Green"
        case .purple:  return "AppIcon-Purple"
        case .mono:    return "AppIcon-Mono"
        }
    }

    var assetName: String { alternateName ?? "AppIcon" }

    var swatch: Color {
        switch self {
        case .orange, .dolphin: return .orange
        case .green: return Color(white: 0.12)
        case .purple: return Color(white: 0.88)
        case .mono: return Color(white: 0.22)
        }
    }
}

/// A compact entry point used by the top-level Settings screen. Long descriptions and
/// toggles live one level deeper, so Settings stays scannable even as features grow.
struct SettingsCategoryCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let destination: Destination

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination()
    }

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .card(padding: 14)
    }
}

struct SettingsHeroCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("TumoCompanion")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Personalize the app and its device bridge")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                StatusPill(text: connectionLabel, color: connectionColor, systemImage: connectionIcon)
                StatusPill(text: settings.appearance.label, color: .secondary, systemImage: "circle.lefthalf.filled")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: connectionColor)
    }

    private var connectionLabel: String {
        switch ble.state {
        case .ready: return "Flipper ready"
        case .connected, .connecting: return "Connecting"
        case .scanning: return "Scanning"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth denied"
        default: return "No Flipper"
        }
    }

    private var connectionColor: Color {
        switch ble.state {
        case .ready: return .green
        case .connected, .connecting, .scanning: return .orange
        case .poweredOff, .unauthorized: return .red
        default: return .secondary
        }
    }

    private var connectionIcon: String {
        switch ble.state {
        case .ready: return "checkmark.circle.fill"
        case .scanning: return "dot.radiowaves.left.and.right"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

extension View {
    func settingsDescription() -> some View {
        font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
