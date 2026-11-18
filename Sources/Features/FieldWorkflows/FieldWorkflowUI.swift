import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable final class FieldOperation {
  private(set) var busy = false
  private(set) var error: String?
  private(set) var message: String?
  private var task: Task<Void, Never>?

  func run(_ action: @escaping @MainActor () async throws -> String?) {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    task = Task { @MainActor in
      defer {
        busy = false
        task = nil
      }
      do { message = try await action() } catch is CancellationError {
        message = "Cancelled. Check recovery if a write had started."
      } catch { self.error = error.localizedDescription }
    }
  }
  func cancel() { task?.cancel() }
}

struct FieldOperationSection: View {
  let operation: FieldOperation
  var body: some View {
    if operation.busy || operation.error != nil || operation.message != nil {
      Section {
        if operation.busy {
          HStack {
            ProgressView()
            Text("Working…")
            Spacer()
            Button("Cancel") { operation.cancel() }
          }
        }
        if let error = operation.error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
        }
        if let message = operation.message { Text(message).foregroundStyle(.secondary) }
      }
    }
  }
}

struct FieldDigestView: View {
  let title: String
  let digest: String
  private var grouped: String {
    guard [32, 64].contains(digest.utf8.count),
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return digest }
    var groups: [String] = []
    var rest = digest[...]
    while !rest.isEmpty {
      groups.append(String(rest.prefix(8)))
      rest = rest.dropFirst(8)
    }
    return groups.joined(separator: " ")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button {
          UIPasteboard.general.string = digest
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless).font(.caption).accessibilityLabel("Copy \(title)")
      }
      Text(verbatim: grouped).font(.system(.caption2, design: .monospaced))
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct FieldBinaryExport: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

enum FieldLocalFile {
  static func read(_ url: URL, limit: Int) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= limit
    else { throw FieldWorkflowError.invalid("local file size/type") }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count == size, data.count <= limit else {
      throw FieldWorkflowError.invalid("local file changed or is too large")
    }
    return data
  }
}

/// A stable context is created once, not reconstructed by every body update.
struct FieldWorkflowsHomeView: View {
  @EnvironmentObject private var updates: UpdatesCoordinator
  @State private var context: FieldWorkflowContext?
  var body: some View {
    Group {
      if let context {
        FieldWorkflowsView(context: context)
      } else {
        ProgressView("Preparing field tools…")
      }
    }
    .task {
      if context == nil { context = .live(otherTransferBusy: { updates.hasActiveDeviceTransfer }) }
    }
  }
}

struct FieldWorkflowsView: View {
  let context: FieldWorkflowContext
  var body: some View {
    Form {
      Section("Field evidence") {
        NavigationLink {
          FieldEvidenceListView(context: context)
        } label: {
          Label("Object rounds & inventories", systemImage: "checklist")
        }.accessibilityIdentifier("field-kit-evidence")
        NavigationLink {
          FieldReportsView()
        } label: {
          Label("Sensor & power reports", systemImage: "chart.xyaxis.line")
        }
      }
      Section {
        NavigationLink {
          SubGhzProfileEditorView(context: context)
        } label: {
          Label("Sub-GHz profiles", systemImage: "slider.horizontal.3")
        }.accessibilityIdentifier("field-kit-profile")
        NavigationLink {
          PortableObjectEditorView(context: context)
        } label: {
          Label("Object cards", systemImage: "rectangle.stack")
        }.accessibilityIdentifier("field-kit-objects")
        NavigationLink {
          BackupView()
        } label: {
          Label("Backups & individual recordings", systemImage: "externaldrive.badge.timemachine")
        }
      } header: {
        Text("Prepare & recover")
      } footer: {
        Text(
          "Nothing is written on opening these tools. Profile changes need a preview, a local backup and explicit confirmation. Card imports and recording recovery create new copies."
        )
      }
    }.navigationTitle("Field Kit").navigationBarTitleDisplayMode(.inline)
  }
}
