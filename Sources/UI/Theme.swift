import SwiftUI
import UIKit

/// Lightweight design-system seed for a modern, premium look: card containers,
/// status pills, and section headers built on native materials. Shared across the
/// app so the redesign stays consistent (Relay first, then dashboard / other tabs).
enum Theme {
    /// System orange is intentionally bright for dark surfaces, but its 2.2:1
    /// contrast against white makes small labels look washed out in light mode.
    /// Keep the familiar orange at night and use a deeper companion orange on
    /// light surfaces so icons, links, and compact status text remain legible.
    static let accent = adaptiveColor(
        light: UIColor(red: 0.76, green: 0.31, blue: 0.00, alpha: 1),
        dark: .systemOrange
    )
    static let warning = accent
    static let success = adaptiveColor(
        light: UIColor(red: 0.10, green: 0.53, blue: 0.21, alpha: 1),
        dark: .systemGreen
    )
    static let danger = adaptiveColor(
        light: UIColor(red: 0.76, green: 0.08, blue: 0.12, alpha: 1),
        dark: .systemRed
    )
    static let info = adaptiveColor(
        light: UIColor(red: 0.00, green: 0.36, blue: 0.76, alpha: 1),
        dark: .systemBlue
    )
    static let caution = adaptiveColor(
        light: UIColor(red: 0.52, green: 0.38, blue: 0.00, alpha: 1),
        dark: .systemYellow
    )
    static let purple = adaptiveColor(
        light: UIColor(red: 0.42, green: 0.20, blue: 0.70, alpha: 1),
        dark: .systemPurple
    )
    static let indigo = adaptiveColor(
        light: UIColor(red: 0.27, green: 0.27, blue: 0.67, alpha: 1),
        dark: .systemIndigo
    )
    static let teal = adaptiveColor(
        light: UIColor(red: 0.00, green: 0.43, blue: 0.48, alpha: 1),
        dark: .systemTeal
    )
    static let cyan = adaptiveColor(
        light: UIColor(red: 0.00, green: 0.43, blue: 0.56, alpha: 1),
        dark: .systemCyan
    )
    static let mint = adaptiveColor(
        light: UIColor(red: 0.10, green: 0.46, blue: 0.32, alpha: 1),
        dark: .systemMint
    )
    static let pink = adaptiveColor(
        light: UIColor(red: 0.68, green: 0.15, blue: 0.42, alpha: 1),
        dark: .systemPink
    )
    static let cardRadius: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 10

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// A premium card surface: material fill, hairline stroke, soft shadow.
struct CardBackground: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.055), radius: 12, y: 5)
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(tint: tint, padding: padding))
    }
}

/// A titled card: small uppercase header + optional icon, content below.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption).foregroundStyle(Theme.accent) }
                Text(title.uppercased())
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Compact status chip: colored dot/icon + label on a tinted capsule.
struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(colorScheme == .light ? 0.18 : 0.14), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(colorScheme == .light ? 0.18 : 0.10), lineWidth: 1)
        }
    }
}

/// A pill-style action button used for quick controls (On / Off / Toggle).
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var tint: Color = Theme.accent
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .background(
            tint.opacity(colorScheme == .light ? 0.20 : 0.16),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .light ? 0.18 : 0.10), lineWidth: 1)
        }
        .foregroundStyle(tint)
    }
}

/// Scrollable container with consistent card spacing and grouped background.
struct CardScroll<Content: View>: View {
    private let refreshAction: (() async -> Void)?
    @ViewBuilder var content: Content

    init(refreshAction: (() async -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        Group {
            if let refreshAction {
                scrollContent
                    .refreshable { await refreshAction() }
            } else {
                scrollContent
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: Theme.cardSpacing) { content }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, Theme.pagePadding)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
    }
}

/// A bottom folder tab used for secondary controls on a detail screen.
///
/// The tab remains anchored above the app's tab bar while the panel slides up
/// over the page. Keeping the panel outside the page scroll view makes the
/// interaction consistent with Home → Tools and prevents long secondary
/// content from changing the primary screen's layout.
struct BottomFolderDrawer<Panel: View>: View {
    @Binding private var isExpanded: Bool
    private let title: String
    private let summary: String?
    private let systemImage: String
    private let accessibilityIdentifier: String
    private let panel: Panel
    private let panelHeight: CGFloat?
    private let maxPanelHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredPanelHeight: CGFloat = 0

    init(
        isExpanded: Binding<Bool>,
        title: String,
        summary: String? = nil,
        systemImage: String = "folder.fill",
        accessibilityIdentifier: String,
        panelHeight: CGFloat? = nil,
        maxPanelHeight: CGFloat = 520,
        @ViewBuilder panel: () -> Panel
    ) {
        _isExpanded = isExpanded
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.panelHeight = panelHeight
        self.maxPanelHeight = maxPanelHeight
        self.panel = panel()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isExpanded {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)

                ScrollView {
                    drawerPanelContent
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity)
                .frame(height: resolvedPanelHeight)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 54)
                .accessibilityIdentifier("\(accessibilityIdentifier)-panel")
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onPreferenceChange(BottomFolderDrawerHeightKey.self) { height in
                    guard height.isFinite, height > 0 else { return }
                    let rounded = ceil(height)
                    if abs(measuredPanelHeight - rounded) > 0.5 {
                        measuredPanelHeight = rounded
                    }
                }
            }

            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                    Text(title)
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                    Spacer(minLength: 8)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: isExpanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: measuredPanelHeight)
        .zIndex(10)
    }

    private var drawerPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
            panel
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BottomFolderDrawerHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private var resolvedPanelHeight: CGFloat {
        // `panelHeight` is only the first-frame estimate. Once rendered, use
        // the content's actual intrinsic height. This keeps short drawers
        // compact, lets medium drawers grow, and caps long lists so only the
        // drawer content scrolls.
        let target = measuredPanelHeight > 0
            ? measuredPanelHeight
            : (panelHeight ?? maxPanelHeight)
        return min(max(target, 96), maxPanelHeight)
    }

    private func toggle() {
        isExpanded.toggle()
    }

    private func close() {
        isExpanded = false
    }
}

private struct BottomFolderDrawerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
