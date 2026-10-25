import CoreGraphics

enum ConsolePreviewMetrics {
    static let minimumHeight: CGFloat = 108

    static func height(matchingControls measured: CGFloat) -> CGFloat {
        guard measured.isFinite else { return minimumHeight }
        return max(minimumHeight, measured.rounded(.up))
    }
}
