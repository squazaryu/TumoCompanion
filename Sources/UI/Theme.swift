import SwiftUI

/// Lightweight design-system seed for a modern, premium look: card containers,
/// status pills, and section headers built on native materials. Shared across the
/// app so the redesign stays consistent (Relay first, then dashboard / other tabs).
enum Theme {
    static let accent = Color.orange
    static let cardRadius: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
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
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A pill-style action button used for quick controls (On / Off / Toggle).
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            }

            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                    Text(title)
                        .font(.caption.weight(.bold))
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
        .zIndex(10)
    }

    private var drawerPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
            panel
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var resolvedPanelHeight: CGFloat {
        // Callers with a finite, content-derived height get the same compact
        // behavior as Home → Tools. A long details list remains scrollable at
        // the cap instead of forcing the primary page to grow.
        min(max(panelHeight ?? maxPanelHeight, 96), maxPanelHeight)
    }

    private func toggle() {
        isExpanded.toggle()
    }

    private func close() {
        isExpanded = false
    }
}
