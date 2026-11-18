import SwiftUI

struct FieldEvidenceListView: View {
  let context: FieldWorkflowContext
  @State private var files: [FlipperFile] = []
  @State private var older = ""
  @State private var newer = ""
  @State private var comparison: InventoryComparison?
  @State private var operation = FieldOperation()
  private var inventories: [FlipperFile] {
    files.filter { FieldEvidenceRepository.kind($0) == .inventory }
  }

  var body: some View {
    Form {
      Section {
        Text(
          "Export rounds or create an inventory in Field Tools on Flipper first. Only those exported files are read here."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        Button("Refresh exports") { refresh() }.disabled(operation.busy)
      }
      FieldOperationSection(operation: operation)
      if inventories.count > 1 {
        Section("Compare saved inventories") {
          Picker("Earlier snapshot", selection: $older) { inventoryOptions }
          Picker("Later snapshot", selection: $newer) { inventoryOptions }
          Button("Compare snapshots") { compare() }
            .disabled(operation.busy || older.isEmpty || newer.isEmpty || older == newer)
            .accessibilityIdentifier("field-inventory-compare")
          Text(
            "This compares two saved snapshots, not the current SD. A missing row does not identify who removed a file."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Exports (\(files.count))") {
        if files.isEmpty && !operation.busy {
          Text("No matching exports on this Flipper.").foregroundStyle(.secondary)
        }
        ForEach(files) { file in
          NavigationLink {
            FieldEvidenceDetailView(file: file, repository: context.evidence)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(file.name).lineLimit(2).truncationMode(.middle)
              Text(kindTitle(file)).font(.caption).foregroundStyle(.secondary)
            }
          }.accessibilityIdentifier("field-evidence-\(file.name)")
        }
        if files.count == 256 {
          Text("Latest 256 exports shown; older originals remain on the SD.").font(.caption)
        }
      }
    }
    .navigationTitle("Rounds & inventories").navigationBarTitleDisplayMode(.inline)
    .task { if files.isEmpty { refresh() } }
    .onDisappear { operation.cancel() }
    .sheet(item: $comparison) { value in
      NavigationStack { InventoryComparisonView(comparison: value) }
    }
  }
  @ViewBuilder private var inventoryOptions: some View {
    Text("Choose snapshot").tag("")
    ForEach(inventories) { Text($0.name).tag($0.path) }
  }
  private func kindTitle(_ file: FlipperFile) -> String {
    switch FieldEvidenceRepository.kind(file) {
    case .round: return "Manual object round"
    case .inventory: return "Verified inventory snapshot"
    case .comparison: return "Difference log · completeness unknown"
    case nil: return "Unsupported"
    }
  }
  private func refresh() {
    operation.run {
      files = try await context.evidence.index()
      return nil
    }
  }
  private func compare() {
    guard let a = inventories.first(where: { $0.path == older }),
      let b = inventories.first(where: { $0.path == newer })
    else { return }
    operation.run {
      let first = try await context.evidence.load(a)
      let second = try await context.evidence.load(b)
      guard case .inventory(let old) = first.document, case .inventory(let new) = second.document
      else {
        throw FieldWorkflowError.invalid("inventory kind")
      }
      comparison = InventoryComparison(older: first, newer: second, rows: old.compare(to: new))
      return nil
    }
  }
}

private struct InventoryComparison: Identifiable {
  let id = UUID()
  let older: FieldEvidenceSnapshot
  let newer: FieldEvidenceSnapshot
  let rows: [CaptureDifference]
}

private struct InventoryComparisonView: View {
  @Environment(\.dismiss) private var dismiss
  let comparison: InventoryComparison
  var body: some View {
    List {
      Section("Saved snapshots only") {
        LabeledContent("Earlier", value: comparison.older.file.name)
        LabeledContent("Later", value: comparison.newer.file.name)
        Text(
          "No live SD scan or deletion is performed. Unreadable files are not part of a saved inventory."
        ).font(.caption).foregroundStyle(.secondary)
      }
      ForEach(CaptureDifference.State.allCases, id: \.self) { state in
        let rows = comparison.rows.filter { $0.state == state }
        if !rows.isEmpty {
          Section("\(state.rawValue.capitalized) · \(rows.count)") {
            ForEach(rows) {
              Text($0.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
          }
        }
      }
    }.navigationTitle("Inventory changes").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
  }
}

struct FieldEvidenceDetailView: View {
  let file: FlipperFile
  let repository: FieldEvidenceRepository
  @State private var snapshot: FieldEvidenceSnapshot?
  @State private var operation = FieldOperation()
  @State private var exporting = false
  var body: some View {
    List {
      FieldOperationSection(operation: operation)
      if let snapshot {
        Section("Verified transfer") {
          Text(file.name).font(.headline).textSelection(.enabled)
          FieldDigestView(title: "SHA256 · size and device MD5 checked", digest: snapshot.sha256)
          Button("Export verified copy") { exporting = true }
        }
        switch snapshot.document {
        case .round(let round):
          Section {
            LabeledContent(
              "Started", value: Date(timeIntervalSince1970: TimeInterval(round.started)).formatted()
            )
            LabeledContent("Still pending", value: String(round.pending))
            Text(
              "Results were explicitly entered by a user. Opening or transmitting a recording is not proof that a device worked."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Section("Objects") {
            ForEach(round.rows) { row in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                  Text(row.object).font(.headline)
                  Spacer(minLength: 8)
                  Text(row.result.rawValue).font(.caption.bold())
                }
                if !row.note.isEmpty { Text(row.note).font(.subheadline) }
                if row.timestamp > 0 {
                  Text(Date(timeIntervalSince1970: TimeInterval(row.timestamp)).formatted()).font(
                    .caption
                  ).foregroundStyle(.secondary)
                }
              }.padding(.vertical, 4)
            }
          }
        case .inventory(let inventory):
          Section("\(inventory.entries.count) saved recordings") {
            ForEach(inventory.entries) { entry in
              VStack(alignment: .leading, spacing: 6) {
                Text(entry.path).font(.system(.subheadline, design: .monospaced)).textSelection(
                  .enabled)
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                  .font(.caption).foregroundStyle(.secondary)
                FieldDigestView(title: "Saved SHA256", digest: entry.sha256)
              }.padding(.vertical, 4)
            }
          }
        case .comparison(let document):
          Section {
            Label("Completeness unknown", systemImage: "exclamationmark.triangle")
            Text(
              "This native difference log has no completion footer. An empty log can mean unchanged files or an interrupted scan; it is not proof of a clean scan."
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }
          Section("Reported differences") {
            ForEach(document.rows) { row in
              VStack(alignment: .leading, spacing: 4) {
                Text(row.state.rawValue.capitalized).font(.caption.bold())
                Text(row.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
            }
          }
        }
      } else if !operation.busy {
        Button("Read again") { load() }
      }
    }
    .navigationTitle("Field evidence").navigationBarTitleDisplayMode(.inline)
    .task { if snapshot == nil { load() } }.onDisappear { operation.cancel() }
    .fileExporter(
      isPresented: $exporting, document: FieldBinaryExport(data: snapshot?.data ?? Data()),
      contentType: .data, defaultFilename: file.name
    ) { result in
      if case .failure(let error) = result { operation.run { throw error } }
    }
  }
  private func load() {
    operation.run {
      snapshot = try await repository.load(file)
      return nil
    }
  }
}
