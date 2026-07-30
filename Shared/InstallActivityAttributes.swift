import ActivityKit
import Foundation

/// Shared between the app and the widget extension (same type, same module) so
/// ActivityKit can match the requested Activity to the widget's configuration.
public struct InstallActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case running
            case succeeded
            case completedWithIssues
            case failed
            case stopped
        }

        public var current: Int
        public var total: Int
        public var detail: String
        public var phase: Phase

        public init(current: Int, total: Int, detail: String, phase: Phase) {
            self.current = max(0, current)
            self.total = max(1, total)
            self.detail = detail
            self.phase = phase
        }

        public var fraction: Double {
            min(1, Double(min(current, total)) / Double(total))
        }

        public var progressText: String {
            switch phase {
            case .running:
                return "\(Int((fraction * 100).rounded()))%"
            case .succeeded:
                return "Done"
            case .completedWithIssues:
                return "Issues"
            case .failed:
                return "Failed"
            case .stopped:
                return "Stopped"
            }
        }

        public var compactProgressText: String {
            switch phase {
            case .running:
                return "\(min(current, total))/\(total)"
            case .succeeded:
                return "✓"
            case .completedWithIssues:
                return "!"
            case .failed:
                return "!"
            case .stopped:
                return "■"
            }
        }
    }

    public var title: String
    public init(title: String) { self.title = title }
}
