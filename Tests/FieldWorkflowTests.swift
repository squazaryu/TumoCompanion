import CryptoKit
import Foundation
import XCTest

@testable import UnleashedCompanion

@MainActor final class FieldWorkflowTests: XCTestCase {
  func testRoundPreservesManualResultsAndPendingState() throws {
    let text =
      "Field round\nStarted UTC epoch: 100\nExplicit user results; opening a file is not a test.\nObject\tResult\tUTC epoch\tNote\nGate\tPROBLEM\t101\tNo response\nSensor\tPENDING\t0\t\n"
    let report = try FieldRoundDocument.parse(Data(text.utf8))
    XCTAssertEqual(report.pending, 1)
    XCTAssertEqual(report.rows.first?.result, .problem)
    XCTAssertThrowsError(
      try FieldRoundDocument.parse(
        Data(text.replacingOccurrences(of: "PROBLEM", with: "OPENED").utf8)))
  }
  func testComparisonTextDoesNotProveCompletedOrCleanScan() throws {
    let report = try FieldComparisonDocument.parse(Data())
    XCTAssertFalse(report.provesCompleteScan)
    XCTAssertTrue(report.rows.isEmpty)
    XCTAssertThrowsError(
      try FieldComparisonDocument.parse(Data("MISSING\t/ext/subghz/../file.sub\n".utf8)))
  }

  private let profileData = Data(
    "# retained\nFiletype: Flipper SubGhz Setting File\nVersion: 1\nAdd_standard_frequencies: true\nFrequency: 433920000\nHopper_frequency: 433920000\nDefault_frequency: 433920000\nHopping_Preset: AM650\nCustom_preset_data: 00 00 C0\nFuture_field: keep\n"
      .utf8)

  func testInventoryDigestLimitsCaseFoldingAndDataSlices() throws {
    let bytes = inventory([("/ext/subghz/own.sub", Data([1, 2]))])
    let parsed = try FieldCaptureInventory.parse(bytes)
    let slice = (Data([9, 8, 7]) + bytes).dropFirst(3)
    XCTAssertEqual(try FieldCaptureInventory.parse(slice), parsed)
    let same = try FieldCaptureInventory.parse(inventory([("/ext/subghz/OWN.SUB", Data([1, 2]))]))
    XCTAssertEqual(parsed.compare(to: same).map(\.state), [.unchanged])
    let changed = try FieldCaptureInventory.parse(inventory([("/ext/subghz/own.sub", Data([3]))]))
    XCTAssertEqual(parsed.compare(to: changed).map(\.state), [.changed])
    let empty = try FieldCaptureInventory.parse(inventory([]))
    XCTAssertEqual(parsed.compare(to: empty).map(\.state), [.missing])
    XCTAssertEqual(empty.compare(to: parsed).map(\.state), [.added])
    var corrupt = bytes
    corrupt[20] ^= 1
    XCTAssertThrowsError(try FieldCaptureInventory.parse(corrupt))
    XCTAssertThrowsError(try FieldCaptureInventory.parse(bytes.dropLast()))
    XCTAssertThrowsError(
      try FieldCaptureInventory.parse(
        inventory([("/ext/subghz/a.sub", Data()), ("/ext/subghz/A.sub", Data())])))
    XCTAssertThrowsError(
      try FieldCaptureInventory.parse(inventory([("/ext/apps/bad.fap", Data())])))
    XCTAssertThrowsError(
      try FieldCaptureInventory.parse(
        Data(repeating: 0, count: FieldCaptureInventory.maximumBytes + 1)))
  }

  func testPathsAndIntegerTextParsingAreBounded() throws {
    for path in [
      "/ext/subghz/../key.sub", "/ext/subghz//key.sub", "/ext/apps/key.sub", "/int/nfc/key.nfc",
      "/ext/subghz/key.sub\n", "/ext/subghz\\key.sub",
    ] {
      XCTAssertFalse(FieldWire.capturePath(path), path)
    }
    XCTAssertTrue(FieldWire.capturePath("/ext/nfc/own card.nfc"))
    XCTAssertTrue(FieldWire.linkPath("/ext/apps_data/device_library/imports/Office/own.sub"))
    XCTAssertFalse(FieldWire.linkPath("/ext/subghz/task.fap"))
    XCTAssertThrowsError(try FieldWire.u32(Data([1]), 0))
    XCTAssertThrowsError(try FieldWire.u32(Data(), Int.max))
    XCTAssertThrowsError(try FieldWire.text(Data([65]), 0, 1))
    XCTAssertThrowsError(try FieldWire.cString("A\nB", capacity: 32))
    XCTAssertFalse(FieldWire.objectName(" trailing "))
    XCTAssertFalse(FieldWire.objectName("Кириллица"), "Native card names are ASCII")
  }

  func testPortableObjectRoundtripAndCorruptionCannotEscapeAsInstructions() throws {
    let path = "/ext/subghz/own.sub"
    let card = PortableObjectCard(
      name: "Office", notes: "Owned test", tags: "work", checkedAt: "manual",
      links: [.init(path: path, label: "Gate")])
    let document = try PortableObjectDocument(card: card, files: [path: Data([1, 2])])
    let bytes = try document.encoded()
    XCTAssertEqual(bytes.count, PortableObjectDocument.headerSize + 2)
    XCTAssertEqual(try PortableObjectDocument.decode((Data([0]) + bytes).dropFirst()), document)
    var header = bytes
    header[44] ^= 1
    XCTAssertThrowsError(try PortableObjectDocument.decode(header))
    var payload = bytes
    payload[payload.count - 1] ^= 1
    XCTAssertThrowsError(try PortableObjectDocument.decode(payload))
    XCTAssertThrowsError(try PortableObjectDocument.decode(bytes + Data([0])))
    XCTAssertThrowsError(try PortableObjectDocument(card: card, files: [:]))
    var invalid = card
    invalid.links[0].path = "/ext/apps/bad.fap"
    XCTAssertThrowsError(try invalid.validate())
    invalid = card
    invalid.notes = String(repeating: "я", count: 64)
    XCTAssertThrowsError(try invalid.validate())
    invalid = card
    invalid.links.append(.init(path: path.uppercased(), label: "duplicate"))
    XCTAssertThrowsError(try invalid.validate())
  }

  func testProfilePreservesOpaqueDataAndUsesExactMHz() throws {
    var profile = try SubGhzProfile.parse(profileData)
    XCTAssertEqual(try SubGhzProfile.hz(fromMHz: "433.657070"), 433_657_070)
    XCTAssertEqual(SubGhzProfile.mhz(433_657_070), "433.657070")
    for invalid in [
      "", "433,92", "433.", ".433", "433.9200001", "-433", "100", "361.000001", "1e9",
    ] {
      XCTAssertThrowsError(try SubGhzProfile.hz(fromMHz: invalid), invalid)
    }
    profile.defaultFrequency = 431_000_000
    let bytes = try profile.encoded()
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Future_field: keep"))
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Custom_preset_data: 00 00 C0"))
    XCTAssertEqual(try SubGhzProfile.parse(bytes).defaultFrequency, 431_000_000)
    profile.hoppingPresets = ["TumoHonda"]
    XCTAssertThrowsError(try profile.encoded())
    profile.hoppingPresets = ["AM650"]
    profile.includeStandard = false
    profile.frequencies = []
    XCTAssertThrowsError(try profile.encoded())
    for suffix in [
      "Version: 1\n", "Frequency: 433920000\n", "Add_standard_frequencies: true\n",
      "Default_frequency: 433920000\n",
    ] {
      XCTAssertThrowsError(try SubGhzProfile.parse(profileData + Data(suffix.utf8)))
    }
  }

  func testCheckedProfileWriteRetainsOriginalAndRejectsStaleAndForeignDevice() async throws {
    let (directory, access, service) = try setup()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try await service.readProfile()
    var profile = try SubGhzProfile.parse(snapshot.data)
    profile.defaultFrequency = 868_350_000
    let record = try await service.applyProfile(profile, expected: snapshot)
    XCTAssertEqual(record.phase, .committed)
    XCTAssertEqual(record.original, profileData)
    XCTAssertEqual(try service.records(), [record])
    let writes = access.writes
    await fails { _ = try await service.applyProfile(profile, expected: snapshot) }
    access.device = "other-device"
    await fails { _ = try await service.applyProfile(profile, expected: snapshot) }
    XCTAssertEqual(access.writes, writes)
  }

  func testUnverifiedWriteLeavesDurableRecoveryAndBlocksFurtherApply() async throws {
    let (directory, access, service) = try setup()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try await service.readProfile()
    let profile = try SubGhzProfile.parse(snapshot.data)
    access.failWrite = true
    await fails { _ = try await service.applyProfile(profile, expected: snapshot) }
    let record = try XCTUnwrap(try service.records().first)
    XCTAssertEqual(record.phase, .needsRecovery)
    XCTAssertEqual(record.originalSHA256, snapshot.sha256)
    access.failWrite = false
    access.files[VerifiedUserFiles.profilePath] = snapshot.data
    await fails { _ = try await service.applyProfile(profile, expected: snapshot) }
    let md5 = try await access.checksum(VerifiedUserFiles.profilePath)
    await fails { try await service.restoreProfileBackup(record, expectedCurrentMD5: "stale") }
    let freshRecord = try XCTUnwrap(try service.records().first)
    try await service.restoreProfileBackup(freshRecord, expectedCurrentMD5: md5)
    XCTAssertEqual(try service.records().first?.phase, .restored)
    XCTAssertEqual(access.files[VerifiedUserFiles.profilePath], snapshot.data)
  }

  func testLocalBackupFailureAndTransferBusyCauseNoRemoteMutation() async throws {
    let (directory, access, _) = try setup()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = directory.appendingPathComponent("not-a-directory")
    try Data([1]).write(to: blocked)
    let service = VerifiedUserFiles(access: access, backupDirectory: blocked)
    let snapshot = try await service.readProfile()
    let profile = try SubGhzProfile.parse(snapshot.data)
    await fails { _ = try await service.applyProfile(profile, expected: snapshot) }
    XCTAssertEqual(access.writes, 0)
    let busy = VerifiedUserFiles(
      access: access, backupDirectory: directory, otherTransferBusy: { true })
    await fails { _ = try await busy.applyProfile(profile, expected: snapshot) }
    XCTAssertEqual(access.writes, 0)
  }

  func testSelectiveRecoveryAndObjectStagingNeverTouchOriginalPaths() async throws {
    let (directory, access, service) = try setup()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = "/ext/nfc/own.nfc"
    access.files[path] = Data("original".utf8)
    let copy = try await service.copyCapture(
      Data("restored".utf8), originalPath: path, deviceID: access.device)
    XCTAssertTrue(copy.hasPrefix("/ext/nfc/Restored/"))
    XCTAssertEqual(access.files[path], Data("original".utf8))
    XCTAssertEqual(access.files[copy], Data("restored".utf8))
    let card = PortableObjectCard(name: "Own", notes: "", tags: "", checkedAt: "", links: [])
    let object = try PortableObjectDocument(card: card, files: [:])
    let package = try await service.uploadObject(object, deviceID: access.device)
    XCTAssertTrue(package.hasPrefix("/ext/apps_data/device_library/exports/phone-"))
    XCTAssertEqual(try PortableObjectDocument.decode(XCTUnwrap(access.files[package])), object)
    await fails {
      _ = try await service.copyCapture(
        Data(), originalPath: "/ext/apps/not-signal.fap", deviceID: access.device)
    }
  }

  func testMutationLeaseExcludesForeignWritesAndReleasesAfterError() async throws {
    do {
      try await DeviceFileMutationGate.withLease {
        try await DeviceFileMutationGate.withMutation {}
        let rejected = await Task.detached { () -> Bool in
          do {
            try await DeviceFileMutationGate.withMutation {}
            return false
          } catch { return true }
        }.value
        XCTAssertTrue(rejected)
        throw FieldWorkflowError.conflict
      }
    } catch {}
    try await DeviceFileMutationGate.withMutation {}
    try await DeviceFileMutationGate.withLease {}
  }

  private func inventory(_ files: [(String, Data)]) -> Data {
    var bytes =
      FieldWire.littleEndian(0x3156_4954) + FieldWire.littleEndian(1) + FieldWire.littleEndian(292)
      + FieldWire.littleEndian(0)
    for (path, data) in files {
      bytes += try! FieldWire.cString(path, capacity: 256)
      bytes += FieldWire.littleEndian(UInt32(data.count)) + Data(SHA256.hash(data: data))
    }
    return bytes + FieldWire.littleEndian(0x444E_4554) + FieldWire.littleEndian(UInt32(files.count))
      + Data(SHA256.hash(data: bytes))
  }
  private func setup() throws -> (URL, MemoryAccess, VerifiedUserFiles) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "field-unit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let access = MemoryAccess()
    access.files[VerifiedUserFiles.profilePath] = profileData
    return (directory, access, VerifiedUserFiles(access: access, backupDirectory: directory))
  }
  private func fails(_ action: () async throws -> Void) async {
    do {
      try await action()
      XCTFail("Expected rejection")
    } catch {}
  }
  private final class MemoryAccess: UserFileAccess {
    var device = "device-A"
    var files: [String: Data] = [:]
    var writes = 0
    var failWrite = false
    func deviceID() async throws -> String { device }
    func read(_ path: String, maximumBytes: Int) async throws -> Data { try XCTUnwrap(files[path]) }
    func checksum(_ path: String) async throws -> String? { files[path].map(FieldWire.md5) }
    func makeDirectory(_ path: String) async throws {}
    func write(_ path: String, data: Data) async throws {
      writes += 1
      if failWrite {
        files[path] = data.prefix(3)
        throw FieldWorkflowError.recoveryRequired
      }
      files[path] = data
    }
  }
}
