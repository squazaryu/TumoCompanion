import SwiftUI

struct SubGhzProfileEditorView: View {
  let context: FieldWorkflowContext
  @State private var loaded: LoadedProfile?
  @State private var operation = FieldOperation()
  private struct LoadedProfile {
    let snapshot: UserFileSnapshot
    let profile: SubGhzProfile
  }
  var body: some View {
    Group {
      if let loaded {
        ProfileFormView(
          context: context, snapshot: loaded.snapshot, original: loaded.profile, reload: load
        )
        .id(loaded.snapshot.sha256)
      } else {
        Form {
          Section {
            Text(
              "Read setting_user from the connected Tumoflip before editing. No default file is silently created or overwritten."
            )
          }
          FieldOperationSection(operation: operation)
          Button("Read profile") { load() }.disabled(operation.busy)
          NavigationLink("Local backups & recovery") {
            ProfileRecoveryView(service: context.writes)
          }
        }
      }
    }.navigationTitle("Sub-GHz profile").navigationBarTitleDisplayMode(.inline)
      .task { if loaded == nil { load() } }.onDisappear { operation.cancel() }
  }
  private func load() {
    loaded = nil
    operation.run {
      let snapshot = try await context.writes.readProfile()
      loaded = LoadedProfile(snapshot: snapshot, profile: try SubGhzProfile.parse(snapshot.data))
      return nil
    }
  }
}

private struct ProfileFrequency: Identifiable {
  let id = UUID()
  var text: String
}
private struct ProfilePreview: Identifiable {
  let id = UUID()
  let profile: SubGhzProfile
  let data: Data
}

private struct ProfileFormView: View {
  @Environment(\.dynamicTypeSize) private var textSize
  let context: FieldWorkflowContext
  let snapshot: UserFileSnapshot
  let original: SubGhzProfile
  let reload: () -> Void
  @State private var standard: Bool
  @State private var frequencies: [ProfileFrequency]
  @State private var hopper: [ProfileFrequency]
  @State private var defaultMHz: String
  @State private var presets: Set<String>
  @State private var preview: ProfilePreview?
  @State private var error: String?
  @State private var applied = false

  init(
    context: FieldWorkflowContext, snapshot: UserFileSnapshot, original: SubGhzProfile,
    reload: @escaping () -> Void
  ) {
    self.context = context
    self.snapshot = snapshot
    self.original = original
    self.reload = reload
    _standard = State(initialValue: original.includeStandard)
    _frequencies = State(
      initialValue: original.frequencies.map { ProfileFrequency(text: SubGhzProfile.mhz($0)) })
    _hopper = State(
      initialValue: original.hopperFrequencies.map { ProfileFrequency(text: SubGhzProfile.mhz($0)) }
    )
    _defaultMHz = State(initialValue: SubGhzProfile.mhz(original.defaultFrequency))
    _presets = State(
      initialValue: Set(original.hoppingPresets.filter(SubGhzProfile.canonicalPresets.contains)))
  }
  var body: some View {
    Form {
      Section("Frequency lists · MHz") {
        Toggle("Include firmware standard frequencies", isOn: $standard)
        TextField("Default frequency", text: $defaultMHz).keyboardType(.numbersAndPunctuation)
          .accessibilityIdentifier("field-profile-default")
        Text(
          "Use a dot and up to six decimals. Supported hardware ranges are checked; transmission remains subject to device and regional rules."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      frequencySection("Additional frequencies", values: $frequencies)
      frequencySection("Hopping frequencies", values: $hopper)
      Section("Ordinary hopping presets") {
        ForEach(SubGhzProfile.canonicalPresets, id: \.self) { value in
          Toggle(
            value,
            isOn: Binding(
              get: { presets.contains(value) },
              set: { enabled in
                if enabled { presets.insert(value) } else { presets.remove(value) }
              }))
        }
        if original.hoppingPresets.contains(where: { !SubGhzProfile.canonicalPresets.contains($0) })
        {
          Label(
            "Explicit RX-only or unknown hopping entries will be excluded when applying. Their custom preset definitions remain untouched.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption).foregroundStyle(Theme.accent)
        }
      }
      Section {
        FieldDigestView(title: "Original SHA256", digest: snapshot.sha256)
        Text(
          "Custom register blocks, comments and unknown settings are preserved. This editor does not modify CC1101 register data."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(Theme.danger) }
        Button("Review changes") { review() }.accessibilityIdentifier("field-profile-review")
        NavigationLink("Local backups & recovery") { ProfileRecoveryView(service: context.writes) }
        Button("Discard draft & read again", role: .destructive) { reload() }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .sheet(item: $preview, onDismiss: { if applied { reload() } }) { value in
      NavigationStack {
        ProfileApplyView(service: context.writes, snapshot: snapshot, preview: value) {
          applied = true
        }.dynamicTypeSize(textSize)
      }
    }
  }
  private func frequencySection(_ title: String, values: Binding<[ProfileFrequency]>) -> some View {
    Section(title) {
      ForEach(values) { row in
        HStack {
          TextField("MHz", text: row.text).keyboardType(.numbersAndPunctuation).monospacedDigit()
          Button(role: .destructive) {
            values.wrappedValue.removeAll { $0.id == row.wrappedValue.id }
          } label: {
            Image(systemName: "minus.circle")
          }.accessibilityLabel("Remove frequency")
        }
      }
      Button("Add frequency") { values.wrappedValue.append(ProfileFrequency(text: "433.920000")) }
        .disabled(values.wrappedValue.count >= 128)
    }
  }
  private func review() {
    do {
      var profile = original
      profile.includeStandard = standard
      profile.frequencies = try frequencies.map { try SubGhzProfile.hz(fromMHz: $0.text) }
      profile.hopperFrequencies = try hopper.map { try SubGhzProfile.hz(fromMHz: $0.text) }
      profile.defaultFrequency = try SubGhzProfile.hz(fromMHz: defaultMHz)
      profile.hoppingPresets = SubGhzProfile.canonicalPresets.filter(presets.contains)
      preview = ProfilePreview(profile: profile, data: try profile.encoded())
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

private struct ProfileApplyView: View {
  @Environment(\.dismiss) private var dismiss
  let service: VerifiedUserFiles
  let snapshot: UserFileSnapshot
  let preview: ProfilePreview
  let onApplied: () -> Void
  @State private var operation = FieldOperation()
  @State private var committed = false
  var body: some View {
    Form {
      Section("Confirm profile replacement") {
        Text(VerifiedUserFiles.profilePath).font(.system(.caption, design: .monospaced))
        FieldDigestView(title: "Before · SHA256", digest: snapshot.sha256)
        FieldDigestView(title: "After · SHA256", digest: FieldWire.sha256(preview.data))
        Text(
          "A verified original and write intent are saved to this iPhone before changing the SD file. Keep Flipper connected and close Sub-GHz first. Changes take effect after reopening Sub-GHz."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        Button("Confirm & apply") {
          operation.run {
            _ = try await service.applyProfile(preview.profile, expected: snapshot)
            committed = true
            onApplied()
            return "Profile readback verified. The original backup is retained on this iPhone."
          }
        }.disabled(operation.busy || committed).accessibilityIdentifier("field-profile-confirm")
      }
      FieldOperationSection(operation: operation)
      Section("New file preview") {
        Text(String(decoding: preview.data, as: UTF8.self))
          .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
      }
    }.navigationTitle("Review profile").navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(operation.busy)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(committed ? "Done" : "Cancel") { dismiss() }.disabled(operation.busy)
        }
      }
      .onDisappear { operation.cancel() }
  }
}

private struct ProfileRecoveryPreview: Identifiable {
  var id: UUID { record.id }
  let record: UserProfileWriteRecord
  let currentMD5: String?
}

struct ProfileRecoveryView: View {
  @Environment(\.dynamicTypeSize) private var textSize
  let service: VerifiedUserFiles
  @State private var records: [UserProfileWriteRecord] = []
  @State private var preview: ProfileRecoveryPreview?
  @State private var operation = FieldOperation()
  @State private var exportData = Data()
  @State private var exporting = false
  var body: some View {
    Form {
      Section {
        Text(
          "Backups are local to this iPhone and bound to a device and firmware. Ambiguous writes must be reviewed here before a new profile change. Export completed records before managing them in Files → TumoCompanion → ProfileBackups; keep unresolved records."
        )
        Button("Refresh recovery records") { refresh() }.disabled(operation.busy)
      }
      FieldOperationSection(operation: operation)
      ForEach(records) { record in
        Section("Record \(record.id.uuidString.prefix(8)) · \(record.phase.rawValue)") {
          FieldDigestView(title: "Original SHA256", digest: record.originalSHA256)
          Button("Inspect current file & review restore") {
            operation.run {
              guard try await service.access.deviceID() == record.deviceID else {
                throw FieldWorkflowError.deviceChanged
              }
              let md5 = try await service.access.checksum(VerifiedUserFiles.profilePath)
              preview = ProfileRecoveryPreview(record: record, currentMD5: md5)
              return nil
            }
          }.disabled(operation.busy)
          Button("Export backup record") {
            operation.run {
              exportData = try JSONEncoder().encode(record)
              exporting = true
              return nil
            }
          }
        }
      }
      if records.isEmpty && !operation.busy && operation.error == nil {
        Text("No local profile backups.").foregroundStyle(.secondary)
      }
    }.navigationTitle("Profile recovery").navigationBarTitleDisplayMode(.inline)
      .task { refresh() }.onDisappear { operation.cancel() }
      .fileExporter(
        isPresented: $exporting, document: FieldBinaryExport(data: exportData), contentType: .json,
        defaultFilename: "profile-backup.json"
      ) { result in
        if case .failure(let error) = result { operation.run { throw error } }
      }
      .sheet(item: $preview, onDismiss: refresh) { value in
        NavigationStack { ProfileRestoreView(service: service, preview: value) }.dynamicTypeSize(
          textSize)
      }
  }
  private func refresh() {
    operation.run {
      records = try service.records()
      return nil
    }
  }
}

private struct ProfileRestoreView: View {
  @Environment(\.dismiss) private var dismiss
  let service: VerifiedUserFiles
  let preview: ProfileRecoveryPreview
  @State private var operation = FieldOperation()
  @State private var restored = false
  var body: some View {
    Form {
      Section("Explicit restore") {
        Text(
          "This replaces setting_user with the stored original. It is not an automatic rollback. Device identity and the current checksum are checked again before writing."
        )
        FieldDigestView(
          title: "Current MD5", digest: preview.currentMD5 ?? "File currently missing")
        FieldDigestView(title: "Restore SHA256", digest: preview.record.originalSHA256)
        Button("Confirm restore original", role: .destructive) {
          operation.run {
            try await service.restoreProfileBackup(
              preview.record, expectedCurrentMD5: preview.currentMD5)
            restored = true
            return "Original restored and verified. Reopen Sub-GHz to reload it."
          }
        }.disabled(operation.busy || restored)
      }
      FieldOperationSection(operation: operation)
    }.navigationTitle("Restore profile").navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(operation.busy)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(restored ? "Done" : "Cancel") { dismiss() }.disabled(operation.busy)
        }
      }
      .onDisappear { operation.cancel() }
  }
}
