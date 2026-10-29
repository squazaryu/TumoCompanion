import SwiftUI
import Charts
import UniformTypeIdentifiers

struct FieldReportsView: View {
    private let repository: FieldReportRepository
    @State private var files: [FlipperFile] = []
    @State private var loading = true
    @State private var error: String?

    init(repository: FieldReportRepository = .init(reader: FieldReportDeviceReader())) {
        self.repository = repository
    }

    var body: some View {
        CardScroll {
            SectionCard(title: "Field reports", systemImage: "chart.xyaxis.line") {
                Text("Saved sessions from your Flipper")
                    .font(.headline)
                Text("Export CSV in Sensor Watch, Power Journal, UHF Inventory or Varta Inspector first. Only reports are read; SD originals are never changed.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading { ProgressView("Reading report list…") }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
                Button("Refresh reports") { Task { await refresh() } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(loading)
                    .accessibilityIdentifier("field-reports-refresh")
            }
            if !loading && files.isEmpty && error == nil {
                ContentUnavailableView("No exported sessions", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Create an export on Flipper, then refresh here."))
            }
            ForEach(FieldReportKind.allCases) { kind in
                let matches = files.filter { FieldReportRepository.kind(for: $0) == kind }
                if !matches.isEmpty {
                    SectionCard(title: kind.title, systemImage: kind.icon) {
                        ForEach(matches) { file in
                            NavigationLink {
                                FieldReportDetailView(file: file, repository: repository)
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).font(.subheadline).foregroundStyle(.primary)
                                            .lineLimit(2).truncationMode(.middle)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("field-report-open-\(file.name)")
                        }
                    }
                }
            }
            if files.count == 256 {
                Text("Showing the latest 256 exports. Older files remain on the SD card.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Field Reports").navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !loading || files.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do { files = try await repository.index() }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}

struct FieldReportDetailView: View {
    let file: FlipperFile
    let repository: FieldReportRepository
    @State private var snapshot: FieldReportSnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var exporting = false
    @State private var metric = ""
    @State private var object = ""
    @State private var sensor = ""

    init(file: FlipperFile, repository: FieldReportRepository, fixture: FieldReportSnapshot? = nil) {
        self.file = file; self.repository = repository
        _snapshot = State(initialValue: fixture)
    }

    var body: some View {
        CardScroll {
            if loading { ProgressView("Reading and verifying CSV…").padding() }
            if let error {
                SectionCard(title: "Report unavailable", systemImage: "exclamationmark.triangle") {
                    Text(error).font(.subheadline).foregroundStyle(Theme.danger)
                    Button("Try again") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            }
            if let snapshot {
                overview(snapshot)
                if snapshot.document.kind == .power || snapshot.document.kind == .sensors {
                    graph(snapshot.document)
                }
                observations(snapshot.document)
                SectionCard(title: "Verified copy", systemImage: "checkmark.shield") {
                    Label("Size and device MD5 match", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success).font(.subheadline)
                    Text("SHA256 · \(snapshot.sha256)")
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Text("Transfer integrity is not proof of tag authenticity. This copy is read-only; exports never modify the source on Flipper.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { exporting = true } label: {
                        Label("Export CSV to Files", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        .accessibilityIdentifier("field-report-export")
                }
            }
        }
        .navigationTitle("Session report").navigationBarTitleDisplayMode(.inline)
        .task { if snapshot == nil { await load() } }
        .fileExporter(isPresented: $exporting, document: FieldCSVExport(data: snapshot?.data ?? Data()),
                      contentType: .commaSeparatedText, defaultFilename: file.name) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }

    private func overview(_ snapshot: FieldReportSnapshot) -> some View {
        SectionCard(title: snapshot.document.kind.title, systemImage: snapshot.document.kind.icon) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.document.rows.count)").font(.largeTitle.bold()).monospacedDigit()
                Text(snapshot.document.kind == .uhf ? "observed EPCs" : "observations").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Label(snapshot.file.name, systemImage: "doc.text")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .accessibilityIdentifier("field-report-source-file")
            if !snapshot.document.objects.isEmpty {
                Text("Objects · " + snapshot.document.objects.joined(separator: ", ")).font(.subheadline)
            } else {
                Text("Device session · no object association recorded").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func graph(_ report: FieldReportDocument) -> some View {
        let options = report.kind == .power ? [("soc", "Battery %"), ("voltage_mv", "Volts"), ("current_ma", "mA"), ("temp_tenths", "°C")] : [("temp_tenths", "°C"), ("humidity", "Humidity %")]
        let selected = metric.isEmpty ? options[0].0 : metric
        let filtered = FieldReportDocument(kind: report.kind, rows: report.rows.filter { object.isEmpty || $0.object == object })
        let groups = Array(Set(filtered.rows.map(\.sensor))).sorted()
        let selectedSensor = groups.contains(sensor) ? sensor : (groups.first ?? "")
        let points = filtered.series(column: selected).filter { report.kind != .sensors || $0.group == selectedSensor }
        return SectionCard(title: "Session history", systemImage: "chart.xyaxis.line") {
            Picker("Measurement", selection: Binding(get: { selected }, set: { metric = $0 })) {
                ForEach(options, id: \.0) { key, title in Text(title).tag(key) }
            }.pickerStyle(.menu)
            if report.objects.count > 1 {
                Picker("Object", selection: $object) {
                    Text("All objects").tag("")
                    ForEach(report.objects, id: \.self) { Text($0).tag($0) }
                }
            }
            if report.kind == .sensors && groups.count > 1 {
                Picker("Sensor", selection: Binding(get: { selectedSensor }, set: { sensor = $0 })) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            }
            if points.isEmpty {
                Text("This measurement was not reported.").foregroundStyle(.secondary).padding(.vertical)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Sample", point.id + 1), y: .value("Value", point.value), series: .value("Sensor", point.group))
                        .foregroundStyle(Theme.accent)
                    PointMark(x: .value("Sample", point.id + 1), y: .value("Value", point.value))
                        .foregroundStyle(Theme.accent)
                }.frame(height: 190).chartLegend(.hidden)
                    .accessibilityLabel("Session measurement history")
            }
            Text("X = sample order, not elapsed time. Sampling runs only while the Flipper app is open; gaps are not continuous monitoring.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func observations(_ report: FieldReportDocument) -> some View {
        SectionCard(title: report.kind == .uhf ? "Observed tags" : "Recent observations", systemImage: "list.bullet.rectangle") {
            ForEach(report.rows.suffix(report.kind == .uhf ? 32 : 12)) { row in
                VStack(alignment: .leading, spacing: 6) {
                    if report.kind == .uhf {
                        Text(row["epc"]).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        Text("Antenna \(row["antenna"]) · \(row["hits"]) observations").font(.caption)
                        Text("Signal raw \(row["signal_raw"]) · frequency raw \(row["frequency_raw"])")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if report.kind == .varta {
                        Text(row["id"]).font(.title2.monospaced()).textSelection(.enabled)
                        LabeledContent("Source", value: row["source"])
                        LabeledContent("Known prefix", value: row["known_prefix"] == "1" ? "Pattern matches" : "Not matched")
                        Text("Prefix and marker matches are not proof of authenticity or access rights.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if report.kind == .sensors {
                        Text(row.sensor).font(.caption).lineLimit(3)
                        Text("\(row["temp_tenths"].isEmpty ? "—" : String(format: "%.1f °C", (Double(row["temp_tenths"]) ?? 0) / 10)) · \(row["humidity"].isEmpty ? "—" : row["humidity"] + "%")")
                            .font(.headline).monospacedDigit()
                    } else {
                        LabeledContent("Sample \(row.id + 1)", value: "\(row["soc"])% · \(row["current_ma"]) mA")
                        Text("Device clock \(row["timestamp"]) · heap \(row["heap_free"]) B").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
                if row.id != report.rows.last?.id { Divider().opacity(0.3) }
            }
        }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { snapshot = try await repository.load(file) }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}

private struct FieldCSVExport: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
