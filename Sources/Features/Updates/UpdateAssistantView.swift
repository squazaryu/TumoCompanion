import SwiftUI

struct UpdateAssistantView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @StateObject private var model: UpdateAssistantModel
    @StateObject private var backup = FlipperBackup()
    @State private var receipt: FlipperBackupReceipt?
    @State private var backupError: String?
    @State private var includeAppData = false

    init(fixture: Bool = false) {
        _model = StateObject(wrappedValue: UpdateAssistantModel(fixture: fixture))
    }

    var body: some View {
        CardScroll {
            SectionCard(title: "Update assistant", systemImage: "checklist") {
                Text("Before: verify and save a checkpoint. After: run checks again to compare. No automatic cleanup or restore.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Button { Task { await model.refresh() } } label: {
                    HStack {
                        if model.running { ProgressView() }
                        Text(model.running ? "Checking device…" : "Run checks")
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.running || backup.running || ble.state != .ready || model.isFixture)
                if model.running { Text(model.progress).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(model.checks) { check in
                SectionCard(title: check.title, systemImage: icon(check.state)) {
                    Text(label(check.state)).font(.headline).foregroundStyle(color(check.state))
                    Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.differences.isEmpty {
                SectionCard(title: "File differences", systemImage: "doc.text.magnifyingglass") {
                    Text("Scope: Sub-GHz, IR, NFC, RFID and iButton folders. A missing path does not identify who changed the SD.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.differences.prefix(100))) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.kind.rawValue.capitalized).font(.caption).foregroundStyle(Theme.accent)
                            Text(item.path).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if model.differences.count > 100 { Text("Showing first 100 differences.").font(.caption) }
                }
            }
            SectionCard(title: "Backup & checkpoint", systemImage: "externaldrive") {
                Toggle("Include app data in backup", isOn: $includeAppData)
                    .disabled(backup.running)
                Button { Task { await createBackup() } } label: {
                    Label(backup.running ? "Verifying backup…" : "Create verified backup", systemImage: "externaldrive.badge.checkmark")
                }.disabled(backup.running || model.running || ble.state != .ready || model.isFixture)
                if backup.running { ProgressView(backup.status ?? "Backing up…") }
                if let receipt {
                    Text("Verified \(receipt.files) files; reused \(receipt.reusedFiles) unchanged files. Every archive remains standalone.")
                        .font(.caption).foregroundStyle(Theme.success)
                    ShareLink(item: receipt.url) { Label("Export backup", systemImage: "square.and.arrow.up") }
                }
                Button("Save current inventory as checkpoint") { model.saveCheckpoint() }
                    .disabled(model.running || backup.running || ble.state != .ready || model.isFixture)
                if model.checkpointSaved { Text("Checkpoint saved for this device.").foregroundStyle(Theme.success) }
                Text("A checkpoint stores names/hashes, not file contents. It is not a backup. Saving replaces the comparison baseline only when you press this button.")
                    .font(.caption).foregroundStyle(.secondary)
                if let backupError { Text(backupError).font(.caption).foregroundStyle(Theme.danger) }
            }
            if let report = model.report {
                SectionCard(title: "Acceptance report", systemImage: "doc.text") {
                    DisclosureGroup("View source report") {
                        Text(report.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Theme.danger).font(.footnote).card(tint: Theme.danger)
            }
        }
        .navigationTitle("Update Checks")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ble.$state) { state in
            if state != .ready { model.invalidate(); receipt = nil }
        }
    }

    private func createBackup() async {
        backupError = nil
        do {
            let folders = try await backup.requiredTopLevelFolders().filter {
                ["subghz", "infrared", "nfc", "lfrfid", "ibutton"].contains($0) || (includeAppData && $0 == "apps_data")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).filter { $0.isLetter || $0.isNumber }
            receipt = try await backup.backup(folders: folders, stamp: stamp)
        } catch { backupError = error.localizedDescription; receipt = nil }
    }

    private func label(_ state: UpdateCheck) -> String {
        switch state { case .unknown: return "Not verified"; case .passed: return "Evidence checked"
        case .failed: return "Check failed"; case .manual: return "Needs your check" }
    }
    private func icon(_ state: UpdateCheck) -> String {
        switch state { case .unknown: return "questionmark.circle"; case .passed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"; case .manual: return "hand.raised" }
    }
    private func color(_ state: UpdateCheck) -> Color {
        switch state { case .passed: return Theme.success; case .failed: return Theme.danger
        case .manual: return Theme.accent; case .unknown: return .secondary }
    }
}
