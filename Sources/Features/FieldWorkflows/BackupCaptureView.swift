import SwiftUI

struct BackupCapturesHomeView: View {
  let url: URL
  @EnvironmentObject private var updates: UpdatesCoordinator
  @State private var context: FieldWorkflowContext?
  var body: some View {
    Group {
      if let context { BackupCaptureListView(url: url, context: context) } else { ProgressView() }
    }.task {
      if context == nil { context = .live(otherTransferBusy: { updates.hasActiveDeviceTransfer }) }
    }
  }
}

struct BackupCaptureListView: View {
  let url: URL
  let context: FieldWorkflowContext
  @State private var index: BackupCaptureIndex?
  @State private var preview: CaptureRestorePreview?
  @State private var operation = FieldOperation()
  var body: some View {
    List {
      Section {
        Text(url.lastPathComponent).font(.headline).lineLimit(3)
        Text(
          "The complete archive and manifest are checked locally. Selecting a recording prepares a new copy; it never restores over its original path."
        )
        .font(.subheadline).foregroundStyle(.secondary)
      }
      FieldOperationSection(operation: operation)
      if let index {
        Section("Supported recordings · \(index.files.count)") {
          ForEach(index.files) { capture in
            Button {
              operation.run {
                let data = try await FieldBackgroundRead.run {
                  try FlipperBackup.captureData(from: index, path: capture.path)
                }
                try Task.checkCancellation()
                let device = try await context.access.deviceID()
                preview = CaptureRestorePreview(capture: capture, data: data, deviceID: device)
                return nil
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(capture.path).font(.system(.subheadline, design: .monospaced)).lineLimit(3)
                Text(
                  ByteCountFormatter.string(fromByteCount: Int64(capture.size), countStyle: .file)
                ).font(.caption).foregroundStyle(.secondary)
              }
            }.disabled(operation.busy).accessibilityIdentifier(
              "field-backup-capture-\(capture.path)")
          }
        }
      } else if !operation.busy {
        Button("Verify archive") { load() }
      }
    }.navigationTitle("Recover one recording").navigationBarTitleDisplayMode(.inline)
      .task { if index == nil { load() } }.onDisappear { operation.cancel() }
      .sheet(item: $preview) { value in
        NavigationStack { CaptureRestoreView(context: context, preview: value) }
      }
  }
  private func load() {
    let selectedURL = url
    operation.run {
      index = try await FieldBackgroundRead.run { try FlipperBackup.captureIndex(at: selectedURL) }
      try Task.checkCancellation()
      return nil
    }
  }
}

private enum FieldBackgroundRead {
  static func run<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
    let worker = Task.detached(priority: .userInitiated, operation: action)
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
  }
}

private struct CaptureRestorePreview: Identifiable {
  let id = UUID()
  let capture: BackupCapture
  let data: Data
  let deviceID: String
}

private struct CaptureRestoreView: View {
  @Environment(\.dismiss) private var dismiss
  let context: FieldWorkflowContext
  let preview: CaptureRestorePreview
  @State private var operation = FieldOperation()
  @State private var restored = false
  var body: some View {
    Form {
      Section("New copy only") {
        LabeledContent("Backup source", value: "/ext/" + preview.capture.path)
        FieldDigestView(title: "Capture SHA256", digest: preview.capture.sha256)
        Text(
          "Destination: the same signal category, under Restored, with a new UUID filename. No original is removed or overwritten. A failed transfer may leave an incomplete new copy."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        Button("Confirm recovery as a new copy") {
          operation.run {
            let path = try await context.writes.copyCapture(
              preview.data, originalPath: "/ext/" + preview.capture.path, deviceID: preview.deviceID
            )
            restored = true
            return "New copy verified: \(path)"
          }
        }.disabled(operation.busy || restored).accessibilityIdentifier(
          "field-capture-restore-confirm")
      }
      FieldOperationSection(operation: operation)
    }.navigationTitle("Review recovery").navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(operation.busy)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(restored ? "Done" : "Cancel") { dismiss() }.disabled(operation.busy)
        }
      }
      .onDisappear { operation.cancel() }
  }
}
