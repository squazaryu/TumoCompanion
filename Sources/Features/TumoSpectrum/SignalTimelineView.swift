import SwiftUI

struct SignalTimelineView: View {
    @State private var sourceA: String?
    @State private var sourceB: String?
    @State private var waveformA: SignalWaveform?
    @State private var waveformB: SignalWaveform?
    @State private var zoom = 1.0
    @State private var offset = 0.0
    @State private var selected: Range<Int64>?
    @State private var note = ""
    @State private var message: String?
    @State private var loading = false
    @State private var picker: CaptureSlot?
    private let fixture: SignalWaveform?

    private enum CaptureSlot: String, Identifiable { case a, b; var id: String { rawValue } }

    init(sourceA: String? = nil, sourceB: String? = nil, fixture: SignalWaveform? = nil,
         fixtureB: SignalWaveform? = nil) {
        _sourceA = State(initialValue: sourceA); _sourceB = State(initialValue: sourceB)
        _waveformA = State(initialValue: fixture)
        _waveformB = State(initialValue: fixtureB)
        self.fixture = fixture
    }

    private var duration: Int64 { max(waveformA?.durationUs ?? 1, waveformB?.durationUs ?? 1) }
    private var window: Range<Int64> {
        let span = max(1, Int64(Double(duration) / zoom))
        let start = Int64(Double(max(0, duration - span)) * offset)
        return start..<min(duration, start + span)
    }

    var body: some View {
        CardScroll {
            SectionCard(title: "Recordings", systemImage: "waveform") {
                sourceButton("A", path: sourceA, color: Theme.accent) { picker = .a }
                sourceButton("B", path: sourceB, color: .blue) { picker = .b }
                Text("Passive analysis. Originals are never changed or transmitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Reading capture…") }
            if let waveformA {
                SectionCard(title: "Pulse timeline", systemImage: "waveform.path") {
                    SignalTimelineCanvas(a: waveformA, b: waveformB, range: window, selection: $selected)
                        .frame(height: 180)
                        .accessibilityIdentifier("signal-timeline-canvas")
                    Text("\(window.lowerBound)–\(window.upperBound) µs · start-aligned A/B")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    LabeledContent("Zoom", value: "\(Int(zoom))×")
                    Slider(value: $zoom, in: 1...1000).accessibilityLabel("Timeline zoom")
                    LabeledContent("Position") { Slider(value: $offset, in: 0...1) }
                    Text("Drag to select. At wide zoom the drawing is sampled; statistics use every pulse.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                statisticsCard(waveformA, name: "A", color: Theme.accent)
                if let waveformB { statisticsCard(waveformB, name: "B", color: .blue) }
                SectionCard(title: "Annotation", systemImage: "square.and.pencil") {
                    TextField("What did you observe?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Save selected interval") { saveAnnotation(waveformA) }
                        .disabled(selected == nil || sourceA == nil)
                    Text("Saved locally with the source SHA256 and interval; no inferred protocol meaning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message {
                SectionCard(title: "Status", systemImage: "info.circle") {
                    Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("RAW Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(sourceA ?? "")|\(sourceB ?? "")") {
            guard fixture == nil else { return }
            await load()
        }
        .sheet(item: $picker) { slot in
            SignalCapturePicker(selection: slot == .a ? $sourceA : $sourceB)
        }
    }

    private func sourceButton(_ name: String, path: String?, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(name).font(.headline).foregroundStyle(color)
                Text(path.map { ($0 as NSString).lastPathComponent } ?? "Choose RAW recording")
                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "folder").foregroundStyle(color)
            }
        }.disabled(loading || fixture != nil)
    }

    private func statisticsCard(_ waveform: SignalWaveform, name: String, color: Color) -> some View {
        let range = selected ?? window
        let stats = waveform.statistics(in: range)
        return SectionCard(title: "\(name) · selected interval", systemImage: "chart.bar") {
            LabeledContent("Pulses", value: "\(stats.count)")
            LabeledContent("Minimum / maximum", value: "\(stats.minUs) / \(stats.maxUs) µs")
            LabeledContent("Mean", value: String(format: "%.1f µs", stats.meanUs))
            Text(waveform.frequencyHz.map { String(format: "%.3f MHz", Double($0) / 1e6) } ?? "Frequency not recorded")
                .font(.caption).foregroundStyle(color)
        }
    }

    @MainActor private func load() async {
        loading = true; message = nil; selected = nil
        defer { loading = false }
        do {
            let a = try await read(sourceA), b = try await read(sourceB)
            try Task.checkCancellation()
            waveformA = a; waveformB = b; zoom = 1; offset = 0
        } catch is CancellationError { }
        catch { waveformA = nil; waveformB = nil; message = error.localizedDescription }
    }

    private func read(_ path: String?) async throws -> SignalWaveform? {
        guard let path else { return nil }
        guard path.hasPrefix("/ext/subghz/"), path.hasSuffix(".sub"),
              CaptureInventory.safePath(String(path.dropFirst(5))) else {
            throw SignalAnalysisError.invalid("Invalid capture path.")
        }
        let storage = FlipperStorage()
        let parent = (path as NSString).deletingLastPathComponent
        guard let file = try await storage.list(parent).first(where: { $0.path == path }),
              !file.isDirectory, file.size <= SignalWaveform.maxBytes else {
            throw SignalAnalysisError.invalid("Capture is missing or larger than 4 MiB.")
        }
        let bytes = try await storage.read(path)
        guard bytes.count == Int(file.size) else { throw SignalAnalysisError.invalid("Capture changed during read.") }
        return try await Task.detached(priority: .userInitiated) { try SignalWaveform.parse(bytes) }.value
    }

    private func saveAnnotation(_ waveform: SignalWaveform) {
        do {
            guard let selected, let sourceA else { return }
            let annotation = try SignalAnnotation.create(source: sourceA, waveform: waveform, range: selected, text: note)
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SignalNotes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(UUID().uuidString).json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(annotation).write(to: url, options: [.atomic, .completeFileProtection])
            message = "Annotation saved: \(url.lastPathComponent)"
        } catch { message = error.localizedDescription }
    }
}

struct SignalTimelineCanvas: View {
    let a: SignalWaveform
    let b: SignalWaveform?
    let range: Range<Int64>
    @Binding var selection: Range<Int64>?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(a, color: Theme.accent, baseline: 60, context: context, size: size)
                if let b { draw(b, color: .blue, baseline: 140, context: context, size: size) }
                if let selection {
                    let x = Double(max(selection.lowerBound, range.lowerBound) - range.lowerBound) / Double(range.count) * size.width
                    let end = Double(min(selection.upperBound, range.upperBound) - range.lowerBound) / Double(range.count) * size.width
                    if end > x { context.fill(Path(CGRect(x: x, y: 0, width: end-x, height: size.height)), with: .color(Theme.accent.opacity(0.15))) }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                let width = max(1, proxy.size.width)
                let start = Int64(max(0, min(1, value.startLocation.x / width)) * Double(range.count)) + range.lowerBound
                let end = Int64(max(0, min(1, value.location.x / width)) * Double(range.count)) + range.lowerBound
                selection = min(start, end)..<min(range.upperBound, max(start, end))
            })
            .accessibilityLabel("RAW pulse timeline, A orange, B blue. No RF transmission.")
        }
    }

    private func draw(_ waveform: SignalWaveform, color: Color, baseline: Double,
                      context: GraphicsContext, size: CGSize) {
        var path = Path()
        for pulse in waveform.visible(in: range) {
            let x1 = Double(max(pulse.startUs, range.lowerBound) - range.lowerBound) / Double(range.count) * Double(size.width)
            let x2 = Double(min(pulse.endUs, range.upperBound) - range.lowerBound) / Double(range.count) * Double(size.width)
            let y = pulse.high ? baseline - 30 : baseline
            path.move(to: CGPoint(x: x1, y: baseline))
            path.addLine(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x2, y: y))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

private struct SignalCapturePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    @State private var path = "/ext/subghz"
    @State private var files: [FlipperFile] = []
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            List {
                if path != "/ext/subghz" {
                    Button("Parent folder") { path = (path as NSString).deletingLastPathComponent }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.danger) }
                ForEach(files) { file in
                    Button { if file.isDirectory { path = file.path } else { selection = file.path; dismiss() } } label: {
                        Label(file.name, systemImage: file.isDirectory ? "folder" : "waveform")
                    }
                }
            }
            .navigationTitle("Choose RAW file")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: path) {
                files = []; errorMessage = nil
                do {
                    let entries = try await FlipperStorage().list(path)
                    try Task.checkCancellation()
                    files = entries.filter { $0.isDirectory || $0.name.hasSuffix(".sub") }
                } catch is CancellationError { }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
}
