import ActivityKit
import SwiftUI
import UnleashedShared
import WidgetKit

@main
struct UnleashedWidgetsBundle: WidgetBundle {
    var body: some Widget {
        InstallLiveActivity()
    }
}

private let accent = Color.orange

/// The extension intentionally contains no Home Screen widgets. WidgetKit remains
/// because ActivityKit renders Lock Screen and Dynamic Island Live Activities through
/// an ActivityConfiguration hosted by a widget extension.
struct InstallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InstallActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    activityIcon(context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progressText)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.attributes.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        progress(context.state)
                        Text(detailText(context))
                            .font(.caption2)
                            .foregroundStyle(context.isStale ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } compactLeading: {
                activityIcon(context.state)
            } compactTrailing: {
                Text(context.state.compactProgressText)
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                activityIcon(context.state)
            }
            .keylineTint(accent)
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<InstallActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                activityIcon(context.state)
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 8)
                Text(context.state.progressText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            progress(context.state)
            Text(detailText(context))
                .font(.caption)
                .foregroundStyle(context.isStale ? .orange : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding()
    }

    @ViewBuilder
    private func activityIcon(
        _ state: InstallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .running:
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(accent)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .completedWithIssues:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func progress(
        _ state: InstallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .running {
            ProgressView(value: state.fraction)
                .tint(accent)
        } else {
            ProgressView(value: state.fraction)
                .tint(state.phase == .succeeded ? .green : .orange)
        }
    }

    private func detailText(
        _ context: ActivityViewContext<InstallActivityAttributes>
    ) -> String {
        if context.isStale, context.state.phase == .running {
            return "Waiting for TumoCompanion…"
        }
        return context.state.detail
    }
}
