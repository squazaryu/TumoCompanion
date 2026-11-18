#if DEBUG
  import Foundation
  import CryptoKit
  import SwiftUI
  import ZIPFoundation

  /// Local synthetic fixtures only. This context never constructs a BLE reader.
  @MainActor final class FieldWorkflowFixtureDevice: UserFileAccess, FieldEvidenceReading {
    var files: [String: Data] = [:]
    let fails: Bool
    init(fails: Bool = false) {
      self.fails = fails
      files[VerifiedUserFiles.profilePath] = Data(
        "# Owned test\nFiletype: Flipper SubGhz Setting File\nVersion: 1\nAdd_standard_frequencies: true\nFrequency: 433920000\nHopper_frequency: 433920000\nDefault_frequency: 433920000\nHopping_Preset: AM650\n"
          .utf8)
      files["/ext/subghz/Owned_gate.sub"] = Data(
        "Filetype: Flipper SubGhz Key File\nProtocol: RAW\nRAW_Data: 100 -100\n".utf8)
      let root = FieldEvidenceRepository.root
      files[root + "/reports/round-100-0123456789abcdef.txt"] = Data(
        "Field round\nStarted UTC epoch: 100\nExplicit user results; opening a file is not a test.\nObject\tResult\tUTC epoch\tNote\nFront gate\tPASS\t102\tOwn receiver confirmed\nWorkshop sensor\tPROBLEM\t103\tBattery needs checking\nOffice\tPENDING\t0\t\n"
          .utf8)
      files[root + "/reports/102-00.txt"] = Data("MISSING\t/ext/subghz/Old_gate.sub\n".utf8)
      files[root + "/inventories/100-00.tinv"] = inventory([
        ("/ext/subghz/Owned_gate.sub", Data([1]))
      ])
      files[root + "/inventories/102-00.tinv"] = inventory([
        ("/ext/subghz/Owned_gate.sub", Data([2])), ("/ext/nfc/Office.nfc", Data([3])),
      ])
    }
    private func inventory(_ entries: [(String, Data)]) -> Data {
      var bytes =
        FieldWire.littleEndian(0x3156_4954) + FieldWire.littleEndian(1)
        + FieldWire.littleEndian(292) + FieldWire.littleEndian(0)
      for (path, payload) in entries {
        bytes += try! FieldWire.cString(path, capacity: 256)
        bytes += FieldWire.littleEndian(UInt32(payload.count)) + Data(SHA256.hash(data: payload))
      }
      return bytes + FieldWire.littleEndian(0x444E_4554)
        + FieldWire.littleEndian(UInt32(entries.count)) + Data(SHA256.hash(data: bytes))
    }
    func deviceID() async throws -> String { "fixture-only-device" }
    func list(_ path: String) async throws -> [FlipperFile] {
      if fails { throw FieldWorkflowError.invalid("synthetic unavailable device") }
      let prefix = path + "/"
      var found: [String: FlipperFile] = [:]
      for (key, data) in files where key.hasPrefix(prefix) {
        let rest = key.dropFirst(prefix.count)
        let name = String(rest.split(separator: "/")[0])
        let directory = rest.contains("/")
        found[name] = .init(
          name: name, path: prefix + name, isDirectory: directory,
          size: directory ? 0 : UInt32(data.count))
      }
      return Array(found.values)
    }
    func read(_ path: String, maximumBytes: Int) async throws -> Data {
      if fails { throw FieldWorkflowError.invalid("synthetic unavailable device") }
      guard let data = files[path], data.count <= maximumBytes else {
        throw FieldWorkflowError.invalid("fixture missing/oversize")
      }
      return data
    }
    func checksum(_ path: String) async throws -> String? {
      if fails { throw FieldWorkflowError.invalid("synthetic unavailable device") }
      return files[path].map(FieldWire.md5)
    }
    func makeDirectory(_ path: String) async throws {}
    func write(_ path: String, data: Data) async throws { files[path] = data }
  }

  extension FieldWorkflowContext {
    static func fixture(fails: Bool = false) -> Self {
      let device = FieldWorkflowFixtureDevice(fails: fails)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "field-fixture-" + UUID().uuidString)
      return Self(
        access: device, evidence: .init(reader: device),
        writes: .init(access: device, backupDirectory: directory))
    }
  }

  struct FieldWorkflowsQAView: View {
    @State private var context = FieldWorkflowContext.fixture(
      fails: ProcessInfo.processInfo.arguments.contains("-field-workflows-fail-qa"))
    @State private var archive: URL?
    @State private var failure: String?
    var body: some View {
      NavigationStack {
        if ProcessInfo.processInfo.arguments.contains("-field-restore-qa") {
          if let archive {
            BackupCaptureListView(url: archive, context: context)
          } else if let failure {
            Text(failure)
          } else {
            ProgressView().task { prepareBackup() }
          }
        } else {
          FieldWorkflowsView(context: context)
        }
      }
    }
    private func prepareBackup() {
      do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "field-backup-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Own-captures.zip")
        let zip = try Archive(url: url, accessMode: .create)
        let bytes = Data("Owned recording".utf8)
        let manifest: [String: Any] = [
          "schema": 1,
          "files": [
            [
              "path": "subghz/Owned_gate.sub", "size": bytes.count,
              "sha256": FieldWire.sha256(bytes),
            ]
          ],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        for (path, data) in [
          ("subghz/Owned_gate.sub", bytes), (".tumoflip-backup.json", manifestData),
        ] {
          try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            offset, count in
            data.subdata(in: Int(offset)..<Int(offset) + count)
          }
        }
        archive = url
      } catch { failure = error.localizedDescription }
    }
  }

  #Preview("Field Kit") {
    NavigationStack { FieldWorkflowsView(context: .fixture()) }
  }
  #Preview("Round exports") {
    NavigationStack { FieldEvidenceListView(context: .fixture()) }
  }
  #Preview("Unavailable evidence") {
    NavigationStack { FieldEvidenceListView(context: .fixture(fails: true)) }
  }
  #Preview("Profile") {
    NavigationStack { SubGhzProfileEditorView(context: .fixture()) }
  }
  #Preview("Portable object") {
    NavigationStack { PortableObjectEditorView(context: .fixture()) }
  }
#endif
