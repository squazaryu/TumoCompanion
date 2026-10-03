import Combine
import CryptoKit
import Foundation

@MainActor
final class UpdateAssistantModel: ObservableObject {
    struct Check: Identifiable {
        let id: String
        let title: String
        var state: UpdateCheck = .unknown
        var detail = "Not checked"
    }
    private struct Checkpoint: Codable {
        let schema: Int
        let device: String
        let version: String
        let createdAt: Date
        let inventory: CaptureInventory
    }
    @Published private(set) var checks = [
        Check(id: "firmware", title: "Installed firmware"),
        Check(id: "catalog", title: "FW Packages catalog"),
        Check(id: "space", title: "SD card capacity"),
        Check(id: "inventory", title: "Saved recordings"),
        Check(id: "acceptance", title: "Acceptance Suite")
    ]
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var differences: [CaptureInventory.Difference] = []
    @Published private(set) var report: AcceptanceSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var checkpointSaved = false
    let isFixture: Bool
    private let source: any UpdateAssistantSource
    private let checkpointDirectory: URL?
    private var identity: TumoflipDeviceIdentity?
    private var deviceID: String?
    private var inventory: CaptureInventory?
    private let scope = ["subghz", "infrared", "nfc", "lfrfid", "ibutton"]

    init(fixture: Bool = false, source: (any UpdateAssistantSource)? = nil,
         checkpointDirectory: URL? = nil) {
        isFixture = fixture
        self.source = source ?? LiveUpdateAssistantSource()
        self.checkpointDirectory = checkpointDirectory
        if fixture {
            set("firmware", .passed, "t-dev-009-017 · API 88.14")
            set("catalog", .manual, "Dev 023 catalog verified; installation/device verification is separate")
            set("space", .passed, "1.4 GB free of 7.9 GB")
            set("inventory", .manual, "1 changed, 1 missing; no cause inferred")
            set("acceptance", .manual, "Run the suite on this firmware and export its report")
            differences = [.init(path: "subghz/own_remote_press_A.sub", kind: .changed),
                           .init(path: "subghz/own_sensor_sample.sub", kind: .missing)]
        }
    }

    private func set(_ id: String, _ state: UpdateCheck, _ detail: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = state; checks[i].detail = detail
    }

    func invalidate() {
        guard !isFixture else { return }
        identity = nil; deviceID = nil; inventory = nil; differences = []; report = nil
        checkpointSaved = false
        for i in checks.indices { checks[i].state = .unknown; checks[i].detail = "Not checked" }
    }

    func refresh() async {
        guard !running, !isFixture else { return }
        invalidate(); running = true; errorMessage = nil
        defer { running = false; progress = "" }
        do {
            progress = "Reading firmware identity…"
            let info = try await source.deviceInfo()
            let current = TumoflipDeviceIdentity(deviceInfo: info)
            guard let version = current.firmwareVersion, let api = current.firmwareAPI,
                  let commit = current.firmwareCommit, commit.count >= 8, current.hardwareTarget == 7 else {
                throw SignalAnalysisError.invalid("Incomplete F7 firmware identity; no readiness inferred.")
            }
            let fields = Dictionary(info, uniquingKeysWith: { first, _ in first })
            guard let uid = fields["hardware_uid"], !uid.isEmpty else {
                throw SignalAnalysisError.invalid("Device UID is missing; cannot bind a saved checkpoint.")
            }
            identity = current; deviceID = uid
            set("firmware", .passed, "\(version) · API \(api) · \(commit)")
            do {
                let response = try await source.sdSpace()
                guard response.total > 0, response.free <= response.total else {
                    throw SignalAnalysisError.invalid("SD capacity is unavailable")
                }
                let format = ByteCountFormatter(); format.countStyle = .file
                set("space", .passed, "\(format.string(fromByteCount: Int64(clamping: response.free))) free; required space depends on selected packages")
            } catch { set("space", .unknown, error.localizedDescription) }
            try Task.checkCancellation()
            do {
                set("catalog", .manual, try await source.catalog(current))
            } catch { set("catalog", .unknown, error.localizedDescription) }
            try Task.checkCancellation()
            let top = try await source.list("/ext")
            var records: [CaptureInventory.File] = []
            for folder in scope where top.contains(where: { $0.name == folder && $0.isDirectory }) {
                try await collect("/ext/\(folder)", depth: 0, records: &records)
            }
            let snapshot = try CaptureInventory(files: records)
            inventory = snapshot
            if let before = try loadCheckpoint(), before.device == uid {
                differences = before.inventory.compare(to: snapshot)
                set("inventory", differences.isEmpty ? .passed : .manual,
                    "\(records.count) files checked against \(before.version); \(differences.count) differences. Missing means not found, not proof of deletion.")
            } else {
                set("inventory", .manual, "\(records.count) files checked. Save a checkpoint before updating; no previous baseline exists.")
            }
            do {
                let entries = try await source.list("/ext/apps_data/tumo_acceptance_suite")
                guard let latest = entries.filter({ !$0.isDirectory && $0.name.hasPrefix("acceptance_") &&
                    $0.name.hasSuffix(".txt") && $0.size <= 128 * 1024 }).sorted(by: { $0.name > $1.name }).first else {
                    throw SignalAnalysisError.invalid("Run Tumo Acceptance on Flipper, then export its report")
                }
                let summary = try AcceptanceSummary.parse(try await source.read(latest.path), version: version, commit: commit)
                report = summary
                set("acceptance", summary.failed > 0 ? .failed : .manual,
                    "\(summary.passed) PASS · \(summary.failed) FAIL · \(summary.manual) skipped/pending. Real receiver/card acceptance remains separate.")
            } catch { set("acceptance", .unknown, error.localizedDescription) }
            try Task.checkCancellation()
            let finalInfo = Dictionary(try await source.deviceInfo(),
                                       uniquingKeysWith: { first, _ in first })
            guard finalInfo["hardware_uid"] == uid, finalInfo["firmware_version"] == version,
                  finalInfo["firmware_commit"] == commit else {
                throw SignalAnalysisError.invalid("Device/firmware changed during checks; results discarded")
            }
        } catch is CancellationError { invalidate() }
        catch { errorMessage = error.localizedDescription; invalidate() }
    }

    private func collect(_ path: String, depth: Int, records: inout [CaptureInventory.File]) async throws {
        guard depth <= 16, records.count < 20_000 else { throw SignalAnalysisError.invalid("Inventory limits exceeded") }
        for file in try await source.list(path) {
            try Task.checkCancellation()
            guard file.path.hasPrefix("/ext/"), CaptureInventory.safePath(String(file.path.dropFirst(5))) else {
                throw SignalAnalysisError.invalid("Unsafe device file path")
            }
            if file.isDirectory { try await collect(file.path, depth: depth + 1, records: &records) }
            else {
                progress = "Verifying \(records.count + 1) · \(file.name)"
                guard let hash = try await source.checkedMD5(file.path) else {
                    throw SignalAnalysisError.invalid("File disappeared during verification")
                }
                records.append(.init(path: String(file.path.dropFirst(5)), size: UInt64(file.size), md5: hash))
            }
        }
    }

    func saveCheckpoint() {
        do {
            guard !running, let deviceID, let identity, let version = identity.firmwareVersion,
                  let inventory else { throw SignalAnalysisError.invalid("Verify this device first") }
            let checkpoint = Checkpoint(schema: 1, device: deviceID, version: version,
                                        createdAt: Date(), inventory: inventory)
            let url = try checkpointURL()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(checkpoint).write(to: url, options: [.atomic, .completeFileProtection])
            checkpointSaved = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func checkpointURL() throws -> URL {
        guard let deviceID else { throw SignalAnalysisError.invalid("Unknown device") }
        let folder = checkpointDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UpdateChecks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(id).json")
    }

    private func loadCheckpoint() throws -> Checkpoint? {
        let url = try checkpointURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw SignalAnalysisError.invalid("Checkpoint is oversized") }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: data)
        guard checkpoint.schema == 1, checkpoint.device == deviceID else {
            throw SignalAnalysisError.invalid("Checkpoint belongs to another device/schema")
        }
        return checkpoint
    }
}
