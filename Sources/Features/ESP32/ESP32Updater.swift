import Foundation
import CryptoKit
import os

private let elog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "esp32")

// The v1.14.x installer workflow rebuilt the ESP32-C5 bootloader, but that image does
// not boot reliably when flashed through Flipper ESP Flasher. Keep the last
// hardware-accepted upstream bootloader pinned by digest until a newer one passes the
// same physical-device gate. The URL is version-pinned and the downloaded bytes are
// still checked against this SHA-256 before they can reach the SD card.
private let c5CompatibilityBootloaderName = "c5_adapter_v1_13_0_bootloader.bin"
private let c5CompatibilityBootloaderURL =
    "https://raw.githubusercontent.com/justcallmekoko/ESP32Marauder/v1.13.0/C5_Py_Flasher_for_adapter/bins/bootloader.bin"
private let c5CompatibilityBootloaderSize = 20_464
private let c5CompatibilityBootloaderSHA256 =
    "3e2b92a74cf406745dddc88ecb5193fd446f4b269b96d2b9991d84f41c810611"

struct ESP32InstallerManifest: Decodable, Equatable {
    struct Target: Decodable, Equatable {
        struct Flash: Decodable, Equatable {
            struct Factory: Decodable, Equatable {
                let segments: [Segment]
            }

            struct Segment: Decodable, Equatable {
                let role: String
                let offset: Int
                let size: Int
                let sha256: String
                let fileName: String
            }

            let factory: Factory
        }

        let id: String
        let assetSuffix: String
        let flash: Flash
    }

    let schemaVersion: Int
    let channel: String
    let kind: String
    let metadataStatus: String
    let sourceRepository: String
    let version: String
    let targets: [Target]
}

enum ESP32ManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case wrongChannel(String)
    case wrongKind(String)
    case nonAuthoritative(String)
    case wrongRepository(String)
    case versionMismatch(expected: String, actual: String)
    case missingBoard(String)
    case invalidSegments(String)
    case missingAsset(String)
    case assetMetadataMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported installer manifest schema \(version)."
        case .wrongChannel(let channel): return "Installer manifest channel is \(channel), not stable."
        case .wrongKind(let kind): return "Unexpected installer manifest kind: \(kind)."
        case .nonAuthoritative(let status): return "Installer manifest metadata is \(status), not authoritative."
        case .wrongRepository(let repository): return "Unexpected installer source: \(repository)."
        case .versionMismatch(let expected, let actual):
            return "Installer manifest is for \(actual), expected \(expected)."
        case .missingBoard(let key): return "No verified installer package for board \(key)."
        case .invalidSegments(let key): return "Installer package for \(key) is incomplete or invalid."
        case .missingAsset(let name): return "Installer asset is missing: \(name)."
        case .assetMetadataMismatch(let name): return "Installer metadata doesn't match release asset \(name)."
        }
    }
}

/// Checks the ESP32Marauder GitHub repo for new firmware and, on demand, writes a
/// NEW manual flash folder onto the Flipper SD under `/ext/apps_data/esp_flasher/`
/// so the user can flash it from the Flipper's esp_flasher app.
///
/// Stable releases with `firmware-manifest.json` are staged as complete, per-board
/// factory packages and every selected segment is checked against its manifest SHA-256 or
/// GitHub release digest before an atomic folder replacement. ESP32-C5 packages use the
/// hardware-accepted compatibility bootloader, the release partition table, and the normal
/// release application. This deliberately avoids upgrading low-level C5 boot code as a side
/// effect of an application update. Older releases retain the guarded app-only fallback.
@MainActor
final class ESP32Updater: ObservableObject {
    struct Board: Identifiable, Equatable {
        let id = UUID()
        let folder: String        // existing manual folder path on SD
        let base: String          // folder name minus "_manual", e.g. "module_one_v6_1"
        let display: String       // clean board name (firmware-version suffix stripped)
        let key: String           // release board key, e.g. "v6_1" / "flipper" / "marauder_v7"
        let currentVersion: String // "v1.12.1"
        let appName: String        // existing app .bin name
        let bootFiles: [String]    // non-app .bin names to copy forward
    }

    struct BoardVersionGroup: Identifiable, Equatable {
        let key: String
        let display: String
        let current: Board?
        let activeOlder: [Board]
        let archived: [Board]

        var id: String { key }
        var versions: [Board] { ([current].compactMap { $0 } + activeOlder + archived) }
    }

    @Published private(set) var boards: [Board] = []
    @Published private(set) var archivedBoards: [Board] = []
    @Published private(set) var latestTag: String?     // e.g. "v1.12.2"
    @Published var status: String?
    @Published var busy = false
    @Published var progress: Double?
    /// Live "N% · done / total" caption shown directly under the progress bar,
    /// driven by both the WiFi download and the on-device write phases.
    @Published var progressText: String?
    @Published private(set) var transferChannel: TransferChannel = .ble

    /// True only while the GitHub download is streaming. Gates the download
    /// progress callback so a late `didWriteData` Task (queued during the
    /// download but drained after it) can't re-fill the bar or overwrite the
    /// status once the on-device write phase has taken over. Main-actor isolated.
    private var downloadPhase = false

    private var storage: any DeviceFileStore { TransferChannelStore.shared.activeStore }
    static let repo = "justcallmekoko/ESP32Marauder"
    static let flasherDir = "/ext/apps_data/esp_flasher"
    static let archiveDir = "\(flasherDir)/_archive"

    private(set) var latestManifest: ESP32InstallerManifest?
    private(set) var manifestError: String?
    private var releaseHasManifest = false

#if DEBUG
    static func archivedRedownloadQA() -> ESP32Updater {
        let updater = ESP32Updater()
        updater.latestTag = "v1.14.1"
        updater.archivedBoards = [Board(
            folder: "\(archiveDir)/module_one_v6_1_v1_14_1_manual",
            base: "module_one_v6_1_v1_14_1",
            display: "Module One v6.1",
            key: "v6_1",
            currentVersion: "v1.14.1",
            appName: "esp32_marauder_v1_14_1_v6_1_0x10000.bin",
            bootFiles: ["bootloader_0x1000.bin", "partitions_0x8000.bin"])]
        updater.status = "Up to date (v1.14.1)"
        return updater
    }
#endif

    var verifiedPackageAvailable: Bool {
        releaseHasManifest && latestManifest != nil && manifestError == nil
    }

    var canStageLatest: Bool {
        latestTag != nil && (!releaseHasManifest || verifiedPackageAvailable)
    }

    nonisolated static func norm(_ v: String) -> String {
        v.lowercased().replacingOccurrences(of: "v", with: "")
            .replacingOccurrences(of: "_", with: ".")
    }

    nonisolated static func versionParts(_ v: String) -> [Int] { norm(v).split(separator: ".").compactMap { Int($0) } }

    nonisolated static func decodeManifest(_ data: Data, expectedVersion: String) throws -> ESP32InstallerManifest {
        let manifest = try JSONDecoder().decode(ESP32InstallerManifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw ESP32ManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.channel == "stable" else {
            throw ESP32ManifestError.wrongChannel(manifest.channel)
        }
        guard manifest.kind == "esp32-marauder-installer-release" else {
            throw ESP32ManifestError.wrongKind(manifest.kind)
        }
        guard manifest.metadataStatus == "authoritative" else {
            throw ESP32ManifestError.nonAuthoritative(manifest.metadataStatus)
        }
        guard manifest.sourceRepository == "justcallmekoko/ESP32Marauder" else {
            throw ESP32ManifestError.wrongRepository(manifest.sourceRepository)
        }
        guard norm(manifest.version) == norm(expectedVersion) else {
            throw ESP32ManifestError.versionMismatch(expected: expectedVersion, actual: manifest.version)
        }
        return manifest
    }

    nonisolated static func factorySegments(
        for boardKey: String,
        manifest: ESP32InstallerManifest,
        assetSizes: [String: Int],
        assetSHA256: [String: String]
    ) throws -> [ESP32InstallerManifest.Target.Flash.Segment] {
        guard let target = manifest.targets.first(where: { $0.assetSuffix == boardKey }) else {
            throw ESP32ManifestError.missingBoard(boardKey)
        }
        // The installer workflow is an independent rebuild. Its generic factory plan is
        // not the hardware-accepted C5 update recipe. For C5, pin the last known-good
        // upstream adapter bootloader, keep the release partition table, omit OTA data,
        // and replace the installer application with the normal release application asset.
        let isC5 = boardKey == "esp32c5devkitc1"
        let expectedRoles = isC5
            ? Set(["bootloader", "partition-table", "application"])
            : Set(["bootloader", "partition-table", "ota-data", "application"])
        let allowedRoles = isC5 ? expectedRoles.union(["ota-data"]) : expectedRoles
        let declaredSegments = target.flash.factory.segments
        let declaredRoles = Set(declaredSegments.map(\.role))
        guard declaredSegments.count == declaredRoles.count,
              declaredRoles.isSubset(of: allowedRoles) else {
            throw ESP32ManifestError.invalidSegments(boardKey)
        }
        let selectedSegments: [ESP32InstallerManifest.Target.Flash.Segment]
        if isC5 {
            let applicationAssets = assetSizes.keys.filter { name in
                guard let parsed = parseImageName(name) else { return false }
                return parsed.key == boardKey && norm(parsed.version) == norm(manifest.version)
            }
            guard applicationAssets.count == 1,
                  let applicationName = applicationAssets.first,
                  let applicationSize = assetSizes[applicationName], applicationSize > 0,
                  let applicationSHA = assetSHA256[applicationName],
                  applicationSHA.count == 64,
                  applicationSHA.unicodeScalars.allSatisfy(
                    CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains)
            else {
                throw ESP32ManifestError.missingAsset(
                    "normal \(manifest.version) application for \(boardKey)")
            }
            selectedSegments = [
                ESP32InstallerManifest.Target.Flash.Segment(
                    role: "bootloader",
                    offset: 0x2000,
                    size: c5CompatibilityBootloaderSize,
                    sha256: c5CompatibilityBootloaderSHA256,
                    fileName: c5CompatibilityBootloaderName),
            ] + declaredSegments.filter {
                $0.role == "partition-table"
            } + [ESP32InstallerManifest.Target.Flash.Segment(
                role: "application",
                offset: 0x10000,
                size: applicationSize,
                sha256: applicationSHA,
                fileName: applicationName)]
        } else {
            selectedSegments = declaredSegments
        }
        let segments = selectedSegments
        let roles = Set(segments.map(\.role))
        let offsets = Set(segments.map(\.offset))
        let validSHA = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard segments.count == expectedRoles.count,
              roles == expectedRoles,
              offsets.count == segments.count,
              segments.allSatisfy({
                  $0.offset >= 0 && $0.size > 0 && $0.sha256.count == 64 &&
                      $0.sha256.unicodeScalars.allSatisfy(validSHA.contains)
              }) else {
            throw ESP32ManifestError.invalidSegments(boardKey)
        }
        if isC5 {
            let expectedOffsets = [
                "bootloader": 0x2000,
                "partition-table": 0x8000,
                "application": 0x10000,
            ]
            guard segments.allSatisfy({ expectedOffsets[$0.role] == $0.offset }) else {
                throw ESP32ManifestError.invalidSegments(boardKey)
            }
        }
        for segment in segments {
            if isC5 && segment.fileName == c5CompatibilityBootloaderName {
                continue
            }
            guard let releaseSize = assetSizes[segment.fileName] else {
                throw ESP32ManifestError.missingAsset(segment.fileName)
            }
            guard releaseSize == segment.size else {
                throw ESP32ManifestError.assetMetadataMismatch(segment.fileName)
            }
            if let releaseSHA = assetSHA256[segment.fileName],
               releaseSHA.lowercased() != segment.sha256.lowercased() {
                throw ESP32ManifestError.assetMetadataMismatch(segment.fileName)
            }
        }
        return segments.sorted { $0.offset < $1.offset }
    }

    nonisolated static func stagedFileName(
        for segment: ESP32InstallerManifest.Target.Flash.Segment,
        version: String,
        boardKey: String
    ) -> String {
        let offset = String(segment.offset, radix: 16)
        switch segment.role {
        case "bootloader": return "bootloader_0x\(offset).bin"
        case "partition-table": return "partitions_0x\(offset).bin"
        case "ota-data": return "boot_app0_0x\(offset).bin"
        case "application":
            let underscored = version.replacingOccurrences(of: ".", with: "_")
            return "esp32_marauder_\(underscored)_\(boardKey)_0x\(offset).bin"
        default:
            return "segment_0x\(offset).bin"
        }
    }

    /// Numeric, component-wise newer test (so 1.12.10 > 1.12.2, not lexical).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    /// Strip a trailing firmware-version suffix (`_v1_12_2`) from a folder base, leaving
    /// the stable board name (`module_one_v6_1`). Board keys like `v6_1` (two parts) stay.
    nonisolated static func cleanBase(_ base: String) -> String {
        base.replacingOccurrences(of: "_v[0-9]+_[0-9]+_[0-9]+$", with: "", options: .regularExpression)
    }

    /// Newest staged folder per board key — the cards shown up top.
    var currentBoards: [Board] {
        Dictionary(grouping: boards, by: \.key).values.compactMap { group in
            group.sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }.first
        }.sorted { $0.display < $1.display }
    }

    /// One usable download source per board key. Prefer the active package because
    /// legacy releases may need to copy its boot files forward; when every package
    /// was archived, fall back to the newest archived copy. Downloading from that
    /// fallback always stages a new active folder and leaves the archive untouched.
    var stagingBoards: [Board] {
        Self.selectStagingBoards(active: boards, archived: archivedBoards)
    }

    nonisolated static func selectStagingBoards(active: [Board], archived: [Board]) -> [Board] {
        let activeByKey = Dictionary(grouping: active, by: \.key)
        let archivedByKey = Dictionary(grouping: archived, by: \.key)
        let keys = Set(activeByKey.keys).union(archivedByKey.keys)

        return keys.compactMap { key in
            let activeSource = activeByKey[key]?.sorted {
                isNewer($0.currentVersion, than: $1.currentVersion)
            }.first
            if let activeSource { return activeSource }
            return archivedByKey[key]?.sorted {
                isNewer($0.currentVersion, than: $1.currentVersion)
            }.first
        }
        .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
    }

    func isArchived(_ board: Board) -> Bool {
        archivedBoards.contains(board)
    }

    /// Older staged folders (every folder except the newest of each board) — the archive.
    var olderBoards: [Board] {
        let keep = Set(currentBoards.map(\.id))
        return boards.filter { !keep.contains($0.id) }.sorted {
            $0.display == $1.display ? Self.isNewer($0.currentVersion, than: $1.currentVersion)
                                     : $0.display < $1.display
        }
    }

    /// True when any detected board's installed version differs from the latest release.
    var updateAvailable: Bool {
        guard let latest = latestTag else { return false }
        return stagingBoards.contains { Self.norm($0.currentVersion) != Self.norm(latest) }
    }

    func newVersion(for board: Board) -> Bool {
        guard let latest = latestTag else { return false }
        return Self.norm(board.currentVersion) != Self.norm(latest)
    }

    var versionGroups: [BoardVersionGroup] {
        let activeCurrent = currentBoards
        let activeOlder = olderBoards
        let keys = Set((boards + archivedBoards).map(\.key))
        return keys.map { key in
            let current = activeCurrent.first { $0.key == key }
            let older = activeOlder
                .filter { $0.key == key }
                .sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }
            let archived = archivedBoards
                .filter { $0.key == key }
                .sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }
            let display = current?.display ?? older.first?.display ?? archived.first?.display ?? key
            return BoardVersionGroup(
                key: key,
                display: display,
                current: current,
                activeOlder: older,
                archived: archived)
        }
        .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
    }

    /// Remove one staged flash folder from the SD (the flashed ESP32 is untouched).
    func delete(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.delete(board.folder, recursive: true)
            await scanBoards()
            status = "Removed \(board.display) \(board.currentVersion)."
        } catch { status = "Couldn't remove: \(error.localizedDescription)" }
    }

    /// Remove all older (non-newest) staged folders in one go.
    func deleteOlder() async {
        let targets = olderBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        var removed = 0
        for b in targets where (try? await storage.delete(b.folder, recursive: true)) != nil { removed += 1 }
        await scanBoards()
        status = "Cleaned up \(removed) old folder\(removed == 1 ? "" : "s")."
    }

    /// Move one staged flash folder into the ESP32 updater archive.
    func archive(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.makeDirectory(Self.archiveDir)
            let destination = await uniqueArchivePath(for: board)
            try await storage.move(board.folder, to: destination)
            await scanBoards()
            status = "Archived \(board.display) \(board.currentVersion)."
        } catch {
            status = "Couldn't archive: \(error.localizedDescription)"
        }
    }

    /// Move every older active folder out of the flasher root, keeping only newest boards visible.
    func archiveOlder() async {
        let targets = olderBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.makeDirectory(Self.archiveDir)
            var moved = 0
            for board in targets {
                let destination = await uniqueArchivePath(for: board)
                do {
                    try await storage.move(board.folder, to: destination)
                    moved += 1
                } catch {
                    elog.error("archive \(board.folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            await scanBoards()
            status = "Archived \(moved) old folder\(moved == 1 ? "" : "s")."
        } catch {
            status = "Couldn't prepare archive: \(error.localizedDescription)"
        }
    }

    /// Restore an archived folder back into the esp_flasher root.
    func restore(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            let destination = await uniqueActivePath(for: board)
            try await storage.move(board.folder, to: destination)
            await scanBoards()
            status = "Restored \(board.display) \(board.currentVersion)."
        } catch {
            status = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    func deleteArchived() async {
        let targets = archivedBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        var removed = 0
        for board in targets where (try? await storage.delete(board.folder, recursive: true)) != nil {
            removed += 1
        }
        await scanBoards()
        status = "Deleted \(removed) archived folder\(removed == 1 ? "" : "s")."
    }

    /// Extract `(version, boardKey)` from a Marauder image filename, robust to every
    /// release/local naming variant we've seen:
    ///   esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin   (release: version + date + board)
    ///   esp32_marauder_v1_12_1_v6_1_0x10000.bin               (local: version + board + offset)
    ///   esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin    (local: version + offset + board)
    /// Strips the prefix, the `vN_NN_NN` version, an optional 8-digit build date, and any
    /// `0x…` flash-offset token; whatever remains is the board key (e.g. `esp32c5devkitc1`,
    /// `v6_1`, `marauder_v7`, `cyd_2432S028`).
    nonisolated static func parseImageName(_ name: String) -> (version: String, key: String)? {
        guard name.hasPrefix("esp32_marauder_"), name.hasSuffix(".bin") else { return nil }
        var parts = name.dropFirst("esp32_marauder_".count)
                        .dropLast(".bin".count)
                        .split(separator: "_").map(String.init)
        // Version = first `v<digits>` followed by two all-numeric tokens.
        var version: String?
        for i in parts.indices where i + 2 < parts.count {
            let v = parts[i]
            guard v.hasPrefix("v"), v.count > 1, v.dropFirst().allSatisfy(\.isNumber),
                  parts[i + 1].allSatisfy(\.isNumber), parts[i + 2].allSatisfy(\.isNumber) else { continue }
            version = "\(v).\(parts[i + 1]).\(parts[i + 2])"
            parts.removeSubrange(i...(i + 2))
            break
        }
        guard let version else { return nil }
        // Drop a build date (8 digits) and the flash-offset token(s); keep the board key.
        parts.removeAll { ($0.count == 8 && $0.allSatisfy(\.isNumber)) || $0.hasPrefix("0x") }
        let key = parts.joined(separator: "_")
        guard !key.isEmpty else { return nil }
        return (version, key)
    }

    // MARK: - Scan + check

    func refresh() async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        status = "Checking via \(transferChannel.label)…"
        await scanBoards()
        await checkLatest()
        if let manifestError {
            status = "Release manifest rejected: \(manifestError)"
        } else if let t = latestTag {
            status = updateAvailable ? "Update available: \(t)" : "Up to date (\(t))"
        } else {
            status = "Couldn't reach GitHub."
        }
    }

    private func scanBoards() async {
        guard let dirs = try? await storage.list(Self.flasherDir) else {
            boards = []
            archivedBoards = []
            return
        }
        var found: [Board] = []
        for d in dirs where Self.isManualFolder(d.name) {
            if let board = await board(from: d) {
                found.append(board)
            }
        }
        boards = found

        let archiveDirs = (try? await storage.list(Self.archiveDir)) ?? []
        var archived: [Board] = []
        for d in archiveDirs where Self.isManualFolder(d.name) {
            if let board = await board(from: d) {
                archived.append(board)
            }
        }
        archivedBoards = archived.sorted {
            $0.display == $1.display ? Self.isNewer($0.currentVersion, than: $1.currentVersion)
                                     : $0.display < $1.display
        }
    }

    nonisolated static func isManualFolder(_ name: String) -> Bool {
        name.hasSuffix("_manual")
    }

    nonisolated static func folderName(from path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func board(from directory: FlipperFile) async -> Board? {
        guard directory.isDirectory, Self.isManualFolder(directory.name),
              let files = try? await storage.list(directory.path) else { return nil }
        // The app image is the `esp32_marauder_*` .bin (boot files are named
        // bootloader_*/partitions_*/boot_app0_*). Prefer the one at offset 0x10000.
        let marauder = files.filter { $0.name.hasPrefix("esp32_marauder_") && $0.name.hasSuffix(".bin") }
        guard let app = marauder.first(where: { $0.name.contains("0x10000") }) ?? marauder.first,
              let parsed = Self.parseImageName(app.name) else { return nil }
        let boot = files.filter { $0.name.hasSuffix(".bin") && $0.name != app.name }.map(\.name)
        let base = String(directory.name.dropLast("_manual".count))
        return Board(folder: directory.path, base: base, display: Self.cleanBase(base),
                     key: parsed.key, currentVersion: parsed.version,
                     appName: app.name, bootFiles: boot)
    }

    private func uniqueArchivePath(for board: Board) async -> String {
        await uniquePath(directory: Self.archiveDir, folderName: Self.folderName(from: board.folder))
    }

    private func uniqueActivePath(for board: Board) async -> String {
        await uniquePath(directory: Self.flasherDir, folderName: Self.folderName(from: board.folder))
    }

    private func uniquePath(directory: String, folderName: String) async -> String {
        let manualSuffix = "_manual"
        let stem = Self.isManualFolder(folderName)
            ? String(folderName.dropLast(manualSuffix.count))
            : folderName

        var candidate = "\(directory)/\(folderName)"
        var index = 2
        while await storage.exists(candidate) {
            candidate = "\(directory)/\(stem)_arch\(index)\(manualSuffix)"
            index += 1
        }
        return candidate
    }

    private func checkLatest() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                latestTag = tag
                latestAssets = [:]; latestAssetSizes = [:]; latestAssetSHA256 = [:]
                for a in (obj["assets"] as? [[String: Any]]) ?? [] {
                    guard let n = a["name"] as? String,
                          let u = a["browser_download_url"] as? String,
                          let url = URL(string: u) else { continue }
                    latestAssets[n] = url
                    latestAssetSizes[n] = (a["size"] as? Int) ?? 0
                    if let digest = a["digest"] as? String,
                       digest.lowercased().hasPrefix("sha256:") {
                        latestAssetSHA256[n] = String(digest.dropFirst("sha256:".count))
                    }
                }
                await loadInstallerManifest(for: tag)
            }
        } catch {
            latestManifest = nil
            manifestError = nil
            releaseHasManifest = false
            elog.error("github check: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var latestAssets: [String: URL] = [:]
    private var latestAssetSizes: [String: Int] = [:]
    private var latestAssetSHA256: [String: String] = [:]

    private func loadInstallerManifest(for tag: String) async {
        latestManifest = nil
        manifestError = nil
        guard let manifestURL = latestAssets["firmware-manifest.json"] else {
            releaseHasManifest = false
            return
        }
        releaseHasManifest = true
        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let expectedSize = latestAssetSizes["firmware-manifest.json"] ?? 0
            guard expectedSize <= 0 || data.count == expectedSize else {
                throw ESP32ManifestError.assetMetadataMismatch("firmware-manifest.json")
            }
            if let expectedSHA = latestAssetSHA256["firmware-manifest.json"],
               Self.sha256Hex(data).lowercased() != expectedSHA.lowercased() {
                throw ESP32ManifestError.assetMetadataMismatch("firmware-manifest.json")
            }
            latestManifest = try Self.decodeManifest(data, expectedVersion: tag)
        } catch {
            manifestError = error.localizedDescription
            elog.error("installer manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download + atomically stage a manual folder

    private struct DownloadPlan {
        let sourceName: String
        let sourceURL: URL
        let expectedSize: Int
        let expectedSHA256: String?
        let outputName: String
    }

    private struct DownloadedFile {
        let plan: DownloadPlan
        let data: Data
    }

    func install(_ board: Board) async {
        guard let tag = latestTag else { return }
        guard canStageLatest else {
            status = manifestError.map { "Release manifest rejected: \($0)" }
                ?? "No verified installer package is available."
            return
        }

        let storage = self.storage
        let channel = storage.channel
        transferChannel = channel
        busy = true; progress = 0; downloadPhase = true; progressText = nil
        defer { busy = false; progress = nil; downloadPhase = false; progressText = nil }

        let plans: [DownloadPlan]
        do {
            plans = try downloadPlans(for: board, tag: tag)
        } catch {
            status = error.localizedDescription
            return
        }

        let files: [DownloadedFile]
        do {
            files = try await download(plans)
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            return
        }

        downloadPhase = false
        progress = nil
        progressText = nil
        status = "Preparing verified package…"

        let versionName = tag.replacingOccurrences(of: ".", with: "_")
        let target = "\(Self.flasherDir)/\(Self.cleanBase(board.base))_\(versionName)_manual"
        let staging = "\(target).partial-\(UUID().uuidString.lowercased())"
        let isManifestPackage = latestManifest != nil

        let transferReporter = TransferActivityReporter(channel: channel)
        _ = await transferReporter.prepare()
        transferReporter.begin("ESP32 \(board.key)")
        defer { transferReporter.end() }

        do {
            try await storage.makeDirectory(staging)

            // Stable releases with an installer manifest provide a complete factory
            // package. Legacy releases have only an app image, so retain their known
            // boot files while still staging into a separate transaction directory.
            if !isManifestPackage {
                for name in board.bootFiles {
                    let data = try await storage.read("\(board.folder)/\(name)")
                    let path = "\(staging)/\(name)"
                    try await storage.write(path, data: data)
                    guard await storage.md5(path) == md5Hex(data) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [
                            NSLocalizedDescriptionKey: "Couldn't verify reused file \(name)."
                        ])
                    }
                }
            }

            try await writeAndVerify(files, to: staging, reporter: transferReporter, channel: channel)
            try await replaceAtomically(target: target, with: staging)
            status = "Done ✓ \(files.count)-file package verified. Flash \(board.display) \(tag) from esp_flasher."
        } catch {
            if await storage.exists(staging) {
                try? await storage.delete(staging, recursive: true)
            }
            status = "Staging failed: \(error.localizedDescription)"
        }
        await scanBoards()
    }

    private func downloadPlans(for board: Board, tag: String) throws -> [DownloadPlan] {
        if releaseHasManifest {
            guard let manifest = latestManifest else {
                throw ESP32ManifestError.invalidSegments(board.key)
            }
            let segments = try Self.factorySegments(
                for: board.key,
                manifest: manifest,
                assetSizes: latestAssetSizes,
                assetSHA256: latestAssetSHA256)
            return try segments.map { segment in
                let url: URL
                if board.key == "esp32c5devkitc1",
                   segment.fileName == c5CompatibilityBootloaderName {
                    guard let compatibilityURL = URL(string: c5CompatibilityBootloaderURL) else {
                        throw ESP32ManifestError.missingAsset(segment.fileName)
                    }
                    url = compatibilityURL
                } else {
                    guard let releaseURL = latestAssets[segment.fileName] else {
                        throw ESP32ManifestError.missingAsset(segment.fileName)
                    }
                    url = releaseURL
                }
                return DownloadPlan(
                    sourceName: segment.fileName,
                    sourceURL: url,
                    expectedSize: segment.size,
                    expectedSHA256: segment.sha256,
                    outputName: Self.stagedFileName(for: segment, version: tag, boardKey: board.key))
            }
        }

        guard let (assetName, assetURL) = latestAssets.first(where: {
            Self.parseImageName($0.key)?.key == board.key
        }) else {
            throw ESP32ManifestError.missingBoard(board.key)
        }
        let versionName = tag.replacingOccurrences(of: ".", with: "_")
        return [DownloadPlan(
            sourceName: assetName,
            sourceURL: assetURL,
            expectedSize: latestAssetSizes[assetName] ?? 0,
            expectedSHA256: latestAssetSHA256[assetName],
            outputName: "esp32_marauder_\(versionName)_\(board.key)_0x10000.bin")]
    }

    private func download(_ plans: [DownloadPlan]) async throws -> [DownloadedFile] {
        let expectedTotal = Int64(plans.reduce(0) { $0 + max(0, $1.expectedSize) })
        var completed: Int64 = 0
        var result: [DownloadedFile] = []
        result.reserveCapacity(plans.count)

        for (index, plan) in plans.enumerated() {
            status = "Downloading \(index + 1)/\(plans.count): \(plan.sourceName)…"
            let completedBefore = completed
            let progressGate = PercentProgressGate()
            let delegate = DownloadProgressDelegate { [weak self] written, _ in
                let current = completedBefore + written
                guard expectedTotal > 0 else { return }
                let fraction = min(1, Double(current) / Double(expectedTotal))
                let pct = Int(fraction * 100)
                guard progressGate.accept(pct) else { return }
                Task { @MainActor in
                    guard let self, self.downloadPhase else { return }
                    self.progress = fraction
                    self.progressText = "\(pct)% · \(Self.fileSize(current)) / \(Self.fileSize(expectedTotal))"
                }
            }
            let (temporaryURL, response) = try await URLSession.shared.download(
                from: plan.sourceURL,
                delegate: delegate)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let data = try Data(contentsOf: temporaryURL)
            guard plan.expectedSize <= 0 || data.count == plan.expectedSize else {
                throw ESP32ManifestError.assetMetadataMismatch(plan.sourceName)
            }
            if let expectedSHA = plan.expectedSHA256,
               Self.sha256Hex(data).lowercased() != expectedSHA.lowercased() {
                throw ESP32ManifestError.assetMetadataMismatch(plan.sourceName)
            }
            completed += Int64(data.count)
            result.append(DownloadedFile(plan: plan, data: data))
        }
        return result
    }

    private func writeAndVerify(
        _ files: [DownloadedFile],
        to directory: String,
        reporter: TransferActivityReporter,
        channel: TransferChannel
    ) async throws {
        let totalBytes = Int64(files.reduce(0) { $0 + $1.data.count })
        var completed: Int64 = 0

        for (index, file) in files.enumerated() {
            let path = "\(directory)/\(file.plan.outputName)"
            let expectedMD5 = md5Hex(file.data)
            let completedBefore = completed
            let note = channel == .usb ? "keep USB SD Mode active" : "keep this app open"
            status = "Writing \(index + 1)/\(files.count) via \(channel.label)… \(note)"
            var verified = false
            for attempt in 0..<2 {
                if attempt > 0 { status = "Verification failed — retrying \(file.plan.outputName)…" }
                let progressGate = PercentProgressGate()
                try await storage.write(path, data: file.data) { [weak self] sent in
                    let current = completedBefore + Int64(sent)
                    let pct = Int((Double(current) / Double(max(1, totalBytes))) * 100)
                    guard progressGate.accept(pct) else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        self.progress = min(1, Double(current) / Double(max(1, totalBytes)))
                        self.progressText = "\(pct)% · \(Self.fileSize(current)) / \(Self.fileSize(totalBytes))"
                        reporter.progress(file.plan.outputName)
                    }
                }
                if await storage.md5(path) == expectedMD5 {
                    verified = true
                    break
                }
            }
            guard verified else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't verify \(file.plan.outputName) after two writes."
                ])
            }
            completed += Int64(file.data.count)
        }
    }

    private func replaceAtomically(target: String, with staging: String) async throws {
        let hadTarget = await storage.exists(target)
        let targetName = Self.folderName(from: target)
        let backup = "\(Self.archiveDir)/.\(targetName).replacement-\(UUID().uuidString.lowercased())"

        if hadTarget {
            try await storage.makeDirectory(Self.archiveDir)
            try await storage.move(target, to: backup)
        }
        do {
            try await storage.move(staging, to: target)
        } catch {
            if hadTarget {
                do {
                    try await storage.move(backup, to: target)
                } catch let rollbackError {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Package replacement failed and rollback failed: \(rollbackError.localizedDescription)"
                    ])
                }
            }
            throw error
        }
        if hadTarget {
            do {
                try await storage.delete(backup, recursive: true)
            } catch {
                elog.error("replacement backup cleanup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Coalesces progress callbacks without capturing mutable state in a Sendable
/// closure. URLSession and device writes may invoke their callbacks off-main.
private final class PercentProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func accept(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent != lastPercent else { return false }
        lastPercent = percent
        return true
    }
}

/// Bridges `URLSessionDownloadTask` byte-progress callbacks into a closure so the
/// async `download(from:delegate:)` call can drive a live progress bar. The async
/// method still owns completion (the returned temp URL); this delegate only
/// forwards the informational `didWriteData` ticks. Callbacks arrive on the
/// session's delegate queue, so the handler is responsible for hopping to the
/// main actor before touching UI state.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (_ written: Int64, _ expected: Int64) -> Void

    init(_ onProgress: @escaping (_ written: Int64, _ expected: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // Required by the protocol; the async download(from:delegate:) call consumes
    // completion itself and hands back the temp URL, so nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
