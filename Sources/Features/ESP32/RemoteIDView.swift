import SwiftUI

struct RemoteIDView: View {
    @State private var report: RemoteIDReport?
    @State private var files: [FlipperFile] = []
    @State private var errorMessage: String?
    @State private var loading = false
    private let fixture: RemoteIDReport?
    private let directory = "/ext/apps_data/marauder/logs"

    init(fixture: RemoteIDReport? = nil) {
        self.fixture = fixture; _report = State(initialValue: fixture)
    }

    var body: some View {
        CardScroll {
            SectionCard(title: "Own drone diagnostics", systemImage: "antenna.radiowaves.left.and.right") {
                Text("Receive-only Remote ID logs")
                    .font(.headline).foregroundStyle(Theme.accent)
                Text("On Flipper, enable Marauder output logging, start Remote ID scan, then Back to stop before opening its log here. Requires ESP32 firmware with Remote ID support.")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                Text("Offline broadcast observations, not a live position or proof of authenticity. No operator identity/location is retained by this viewer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Reading log…") }
            if let report {
                SectionCard(title: "Report", systemImage: "doc.text") {
                    LabeledContent("Devices", value: "\(report.records.count)")
                    LabeledContent("Observations", value: "\(report.observations)")
                    Text("Latest row per reported ID; ID is not a paired Bluetooth device name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(report.records) { record in
                    SectionCard(title: record.uasID, systemImage: "paperplane") {
                        LabeledContent("State", value: record.lost ? "Signal lost" : "Observed")
                        LabeledContent("RSSI", value: "\(record.rssi) dBm")
                        LabeledContent("Packets", value: "\(record.packets) · \(String(format: "%.1f", record.rateHz)) /s")
                        LabeledContent("Transport", value: transports(record.transports))
                        if let lat = record.latitude, let lon = record.longitude {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reported location").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.6f, %.6f", lat, lon)).font(.body.monospacedDigit())
                            }
                        } else { Text("Location not provided").foregroundStyle(.secondary) }
                        LabeledContent("Altitude", value: record.altitudeM.map { String(format: "%.1f m", $0) } ?? "Unknown")
                        LabeledContent("Speed", value: record.speedMps.map { String(format: "%.1f m/s", $0) } ?? "Unknown")
                        Text("ESP32 uptime: \(record.uptimeMs) ms; not a wall-clock timestamp.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SectionCard(title: "Saved logs", systemImage: "folder") {
                if files.isEmpty { Text("No Remote ID logs loaded.").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    Button(file.name) { Task { await open(file) } }
                        .disabled(loading).multilineTextAlignment(.leading)
                }
                Button("Refresh logs") { Task { await refresh() } }
                    .disabled(loading || fixture != nil)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true).card(tint: Theme.danger)
            }
        }
        .navigationTitle("Remote ID")
        .navigationBarTitleDisplayMode(.inline)
        .task { if fixture == nil { await refresh() } }
    }

    private func transports(_ mask: UInt8) -> String {
        [(1, "Wi-Fi beacon"), (2, "Wi-Fi NAN"), (4, "BLE"), (8, "BLE extended")]
            .filter { Int(mask) & $0.0 != 0 }.map(\.1).joined(separator: " + ")
    }
    @MainActor private func refresh() async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let entries = try await FlipperStorage().list(directory)
            try Task.checkCancellation()
            files = Array(entries.filter { !$0.isDirectory && $0.name.hasPrefix("remoteid") &&
                $0.size <= 2 * 1024 * 1024 && CaptureInventory.safePath(String($0.path.dropFirst(5))) }
                .sorted { $0.name > $1.name }.prefix(100))
        } catch is CancellationError { }
        catch { files = []; errorMessage = error.localizedDescription }
    }
    @MainActor private func open(_ file: FlipperFile) async {
        loading = true; errorMessage = nil; report = nil
        defer { loading = false }
        do {
            let data = try await FlipperStorage().read(file.path)
            guard data.count == Int(file.size) else { throw SignalAnalysisError.invalid("Log changed while reading") }
            let parsed = try await Task.detached(priority: .userInitiated) { try RemoteIDReport.parse(data) }.value
            try Task.checkCancellation()
            report = parsed
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}
