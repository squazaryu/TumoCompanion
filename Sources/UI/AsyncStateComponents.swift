import SwiftUI

/// The common loading treatment used by catalog screens. Keeping the indeterminate
/// state in one component prevents each feature from inventing a different spinner
/// and makes loading states readable with Dynamic Type.
struct LoadingStateView: View {
    let title: String
    var detail: String?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 9 : 12) {
            ProgressView()
                .controlSize(compact ? .small : .regular)
                .tint(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(compact ? .caption : .subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A determinate/indeterminate progress row shared by BLE, USB and network work.
/// A nil fraction intentionally means "work is active, but no reliable total exists".
struct UnifiedProgressView: View {
    let title: String
    var detail: String?
    var fraction: Double?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView()
            }
        }
        .tint(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(progressAccessibilityValue)
    }

    private var progressAccessibilityValue: String {
        guard let fraction else { return detail ?? "In progress" }
        return "(Int(min(max(fraction, 0), 1) * 100)) percent" +
            (detail.map { " · \($0)" } ?? "")
    }
}

/// A compact error surface with one explicit recovery action. The action stays next
/// to the explanation instead of forcing the user to hunt through a toolbar or menu.
struct ActionableErrorView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var accessibilityIdentifier: String?
    var tint: Color
    var systemImage: String

    init(
        title: String,
        message: String,
        actionTitle: String,
        accessibilityIdentifier: String? = nil,
        tint: Color = Theme.danger,
        systemImage: String = "exclamationmark.triangle.fill",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tint = tint
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                titleText
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, systemImage: "arrow.clockwise", action: action)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var titleText: some View {
        if let accessibilityIdentifier {
            Text(title).accessibilityIdentifier(accessibilityIdentifier)
        } else {
            Text(title)
        }
    }
}
