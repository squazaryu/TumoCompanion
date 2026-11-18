import SwiftUI
import UniformTypeIdentifiers

struct PortableObjectEditorView: View {
  @Environment(\.dynamicTypeSize) private var textSize
  let context: FieldWorkflowContext
  @State private var card = PortableObjectCard(
    name: "Object", notes: "", tags: "", checkedAt: "", links: [])
  @State private var payloads: [String: Data] = [:]
  @State private var exports: [FlipperFile] = []
  @State private var picker = false
  @State private var importing = false
  @State private var preview: ObjectPreview?
  @State private var operation = FieldOperation()

  var body: some View {
    Form {
      Section {
        Text(
          "Edit a portable object, not the installed card database. Export an existing card as .tobj in Field Tools first. Importing the edited package on Flipper creates a new card and new recording copies."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        Button("Open .tobj from Files") { importing = true }.disabled(operation.busy)
        Button("Refresh Flipper exports") { refresh() }.disabled(operation.busy)
        ForEach(exports) { file in
          Button {
            open(file)
          } label: {
            Label(file.name, systemImage: "doc.zipper").lineLimit(2).truncationMode(.middle)
          }
          .disabled(operation.busy)
        }
      }
      FieldOperationSection(operation: operation)
      Section("Object card") {
        TextField("Name · up to 24 ASCII characters", text: $card.name).textInputAutocapitalization(
          .words
        )
        .accessibilityIdentifier("field-object-name")
        TextField("Notes", text: $card.notes, axis: .vertical).lineLimit(2...4)
        TextField("Tags", text: $card.tags)
        TextField("Last checked · manual text", text: $card.checkedAt)
        Text(
          "Native limits: name 24 ASCII characters, notes 127 UTF-8 bytes, tags 63, checked text 23. Editing text is not a passed field test."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.disabled(operation.busy)
      Section("Recording actions · \(card.links.count)/8") {
        ForEach($card.links) { link in
          VStack(alignment: .leading, spacing: 8) {
            TextField("Action label", text: link.label)
            Text(link.wrappedValue.path).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
            Button("Remove from new package", role: .destructive) {
              let path = link.wrappedValue.path
              card.links.removeAll { $0.path == path }
              payloads[path] = nil
            }
          }
        }
        Button("Add recording from Flipper") { picker = true }.disabled(
          card.links.count >= 8 || operation.busy
        )
        .accessibilityIdentifier("field-object-add")
      }.disabled(operation.busy)
      Section {
        Button("Review new package") {
          operation.run {
            let document = try PortableObjectDocument(card: card, files: payloads)
            preview = ObjectPreview(document: document, data: try document.encoded())
            return nil
          }
        }.disabled(operation.busy).accessibilityIdentifier("field-object-review")
        Text(
          "Only .sub, .ir, .nfc, .rfid and .ibtn payloads are accepted. No app or script is executed by this editor."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.navigationTitle("Object cards").navigationBarTitleDisplayMode(.inline)
      .scrollDismissesKeyboard(.interactively)
      .onDisappear { operation.cancel() }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
        operation.run {
          let url = try result.get()
          guard url.pathExtension.lowercased() == "tobj" else {
            throw FieldWorkflowError.invalid("choose a .tobj package")
          }
          let bytes = try FieldLocalFile.read(url, limit: PortableObjectDocument.maximumBytes)
          let document = try PortableObjectDocument.decode(bytes)
          card = document.card
          payloads = document.files
          return "Opened a verified local package. No SD files changed."
        }
      }
      .sheet(isPresented: $picker) {
        NavigationStack {
          CapturePickerView(context: context, directory: "/ext", depth: 0) { file, bytes in
            guard card.links.count < 8,
              !card.links.contains(where: { $0.path.lowercased() == file.path.lowercased() })
            else {
              throw FieldWorkflowError.invalid("already selected or eight-action limit")
            }
            var label = (file.name as NSString).deletingPathExtension
            while label.utf8.count >= 32 { label.removeLast() }
            card.links.append(.init(path: file.path, label: label))
            payloads[file.path] = bytes
            picker = false
          }
        }.dynamicTypeSize(textSize)
      }
      .sheet(item: $preview) { value in
        NavigationStack { ObjectPackagePreviewView(context: context, preview: value) }
          .dynamicTypeSize(textSize)
      }
  }
  private func refresh() {
    operation.run {
      let root = "/ext/apps_data/device_library/exports"
      let files = try await context.evidence.reader.list(root)
      guard files.count <= 4096 else {
        throw FieldWorkflowError.invalid("export directory too large")
      }
      exports = files.filter {
        !$0.isDirectory && $0.path == root + "/" + $0.name && !$0.name.contains("/")
          && !$0.name.contains("\\") && $0.name.utf8.count <= 128 && $0.name.hasSuffix(".tobj")
          && $0.size >= PortableObjectDocument.headerSize
          && $0.size <= PortableObjectDocument.maximumBytes
      }.sorted { $0.name > $1.name }.prefix(128).map { $0 }
      return exports.isEmpty
        ? "No portable exports found. Export a card in Field Tools first." : nil
    }
  }
  private func open(_ file: FlipperFile) {
    operation.run {
      let snapshot = try await context.writes.snapshot(
        file.path, maximumBytes: PortableObjectDocument.maximumBytes)
      let document = try PortableObjectDocument.decode(snapshot.data)
      card = document.card
      payloads = document.files
      return "Opened a checked copy. The original package and installed card remain unchanged."
    }
  }
}

struct CapturePickerView: View {
  @Environment(\.dismiss) private var dismiss
  let context: FieldWorkflowContext
  let directory: String
  let depth: Int
  let selected: (FlipperFile, Data) throws -> Void
  @State private var files: [FlipperFile] = []
  @State private var operation = FieldOperation()
  private let roots: Set<String> = ["subghz", "infrared", "nfc", "lfrfid", "ibutton"]
  var body: some View {
    List {
      FieldOperationSection(operation: operation)
      ForEach(files) { file in
        if file.isDirectory {
          NavigationLink(file.name) {
            CapturePickerView(
              context: context, directory: file.path, depth: depth + 1, selected: selected)
          }
        } else {
          Button {
            operation.run {
              let snapshot = try await context.writes.snapshot(
                file.path, maximumBytes: 16 * 1024 * 1024)
              try selected(file, snapshot.data)
              return nil
            }
          } label: {
            Label(file.name, systemImage: "waveform").lineLimit(2).truncationMode(.middle)
          }
          .disabled(operation.busy)
        }
      }
      if files.isEmpty && !operation.busy && operation.error == nil {
        Text("No supported recordings here.").foregroundStyle(.secondary)
      }
    }.navigationTitle(depth == 0 ? "Choose recording" : (directory as NSString).lastPathComponent)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if depth == 0 {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
      }
      .task {
        operation.run {
          let entries = try await context.evidence.reader.list(directory)
          guard entries.count <= 4096 else {
            throw FieldWorkflowError.invalid("directory too large")
          }
          files = entries.filter { file in
            guard file.path == directory + "/" + file.name, !file.name.isEmpty,
              !file.name.contains("/"),
              !file.name.contains("\\"), file.name != ".", file.name != "..",
              FieldWire.printable(file.name)
            else { return false }
            if directory == "/ext" { return file.isDirectory && roots.contains(file.name) }
            return file.isDirectory
              ? depth < 6 && file.path.utf8.count < 224
              : FieldWire.capturePath(file.path) && file.size <= 16 * 1024 * 1024
          }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
          return nil
        }
      }.onDisappear { operation.cancel() }
  }
}

private struct ObjectPreview: Identifiable {
  let id = UUID()
  let document: PortableObjectDocument
  let data: Data
}
private struct ObjectDevicePreview: Identifiable {
  let id = UUID()
  let deviceID: String
}

private struct ObjectPackagePreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let context: FieldWorkflowContext
  let preview: ObjectPreview
  @State private var operation = FieldOperation()
  @State private var exporting = false
  @State private var device: ObjectDevicePreview?
  @State private var copied = false
  var body: some View {
    Form {
      Section(preview.document.card.name) {
        LabeledContent("Recording actions", value: String(preview.document.card.links.count))
        LabeledContent(
          "Package size",
          value: ByteCountFormatter.string(
            fromByteCount: Int64(preview.data.count), countStyle: .file))
        FieldDigestView(title: "Package SHA256", digest: FieldWire.sha256(preview.data))
        Text(
          "A new .tobj is created. To use it, open Field Tools → Import object on Flipper and choose a new card name. Existing cards and signals are not replaced."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        Button("Export package to Files") { exporting = true }.disabled(operation.busy)
        Button("Prepare copy to Flipper") {
          operation.run {
            device = .init(deviceID: try await context.access.deviceID())
            return nil
          }
        }.disabled(operation.busy || copied)
      }
      FieldOperationSection(operation: operation)
    }.navigationTitle("Review object package").navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(operation.busy)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(operation.busy)
        }
      }
      .fileExporter(
        isPresented: $exporting, document: FieldBinaryExport(data: preview.data),
        contentType: .data, defaultFilename: preview.document.card.name + ".tobj"
      ) { result in
        if case .failure(let error) = result { operation.run { throw error } }
      }
      .alert(
        "Copy a new package to this Flipper?",
        isPresented: Binding(get: { device != nil }, set: { if !$0 { device = nil } })
      ) {
        Button("Confirm new copy") {
          guard let selected = device else { return }
          device = nil
          operation.run {
            let path = try await context.writes.uploadObject(
              preview.document, deviceID: selected.deviceID)
            copied = true
            return "Verified new copy: \(path). Import it explicitly in Field Tools."
          }
        }
        Button("Cancel", role: .cancel) { device = nil }
      } message: {
        Text(
          "A unique phone-UUID.tobj is written under device_library/exports. No existing card, payload or package is overwritten."
        )
      }
      .onDisappear { operation.cancel() }
  }
}
