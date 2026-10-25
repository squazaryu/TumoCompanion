import SwiftUI

extension ConnectionStatus {
    var color: Color {
        switch self {
        case .ready: return Theme.success
        case .unresponsive: return Theme.danger
        case .checking, .connecting, .waiting, .buddy: return Theme.caution
        case .offline: return .secondary
        }
    }

    var detail: String {
        switch self {
        case .ready: return "RPC response confirmed."
        case .checking: return "Checking the device, not just the Bluetooth link."
        case .waiting: return "RPC is in use. Verification will wait."
        case .unresponsive: return "Bluetooth is present, but RPC has not replied."
        case .buddy: return "Claude Buddy is using the serial channel."
        case .connecting: return "Waiting for Bluetooth notifications."
        case .offline: return "Connect a Flipper to verify the device channel."
        }
    }
}

/// Same non-destructive check on Home and in Connectivity. The button is always
/// a native 44pt target; the explanation wraps instead of shrinking/truncating.
struct ConnectionFeedbackView: View {
    let status: ConnectionStatus
    let check: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: check) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(status.color.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(status.color)
            .disabled(status == .offline || status == .connecting || status == .buddy || status == .checking)
            .accessibilityLabel("Check connection")
            .accessibilityHint("Checks RPC only when no transfer is using it. Does not disconnect the Flipper.")
            .accessibilityIdentifier("connection-check")
        }
    }
}

struct ConnectionHealthCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var connection: ConnectionMonitor

    var body: some View {
        SectionCard(title: "Channel health", systemImage: "waveform.path.ecg") {
            HStack {
                Label(connection.status.title, systemImage: connection.status == .ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(connection.status.color)
                Spacer()
            }
            .font(.headline)
            LabeledContent("Bluetooth", value: ble.state == .ready || ble.state == .connected ? "Connected" : "Not connected")
                .accessibilityIdentifier("connection-health-ble")
            LabeledContent("RPC", value: connection.status.title)
                .accessibilityIdentifier("connection-health-rpc")
            LabeledContent("App Bridge", value: ble.appBridgeV2 ? "v2 confirmed" : "Not confirmed")
                .accessibilityIdentifier("connection-health-bridge")
            ConnectionFeedbackView(status: connection.status, check: check)
        }
    }

    private func check() { Task { await connection.verifyNow() } }
}

/// A stored image is never labelled LIVE. Only real incoming frames refresh the
/// timestamp; the small timeline updates its badge without invalidating the app.
struct FlipperScreenFreshness: ViewModifier {
    let receivedAt: Date?
    let status: ConnectionStatus

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fresh = receivedAt.map { context.date.timeIntervalSince($0) <= 5 } ?? false
                if status != .offline, status != .connecting, !fresh || status != .ready {
                    Text(receivedAt == nil ? "Waiting for frame" : "Last frame")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(5)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
