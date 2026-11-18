import Foundation

/// Live BLE binding. The pure models have no access to BLE or arbitrary URLs.
@MainActor final class FieldWorkflowDevice: UserFileAccess, FieldEvidenceReading {
  private let storage = FlipperStorage()
  func deviceID() async throws -> String {
    let info = Dictionary(
      try await FlipperSystem().deviceInfo(timeout: 10), uniquingKeysWith: { first, _ in first })
    guard let uid = info["hardware_uid"], !uid.isEmpty,
      info["firmware_origin_fork"]?.lowercased() == "tumoflip", info["hardware_target"] == "7",
      let commit = info["firmware_commit"], !commit.isEmpty,
      let version = info["firmware_version"], !version.isEmpty
    else { throw FieldWorkflowError.deviceChanged }
    return FieldWire.sha256(Data("\(uid)|\(commit)|\(version)".utf8))
  }
  func list(_ path: String) async throws -> [FlipperFile] {
    do { return try await storage.list(path) } catch FlipperRPCError.status(let status)
      where status == .errorStorageNotExist
    { return [] }
  }
  func read(_ path: String, maximumBytes: Int) async throws -> Data {
    try await storage.read(path, maximumBytes: maximumBytes)
  }
  func checksum(_ path: String) async throws -> String? {
    try await storage.checkedMD5(path, timeout: 120)
  }
  func makeDirectory(_ path: String) async throws { try await storage.makeDirectory(path) }
  func write(_ path: String, data: Data) async throws {
    let stop = StopToken()
    let guarder = BackgroundTransferGuard(name: "field-user-file")
    guarder.begin { stop.stop() }
    defer { guarder.end() }
    try await withTaskCancellationHandler {
      try await storage.write(path, data: data, progress: nil, isStopRequested: { stop.isStopped })
    } onCancel: {
      stop.stop()
    }
  }
}

@MainActor struct FieldWorkflowContext {
  let access: any UserFileAccess
  let evidence: FieldEvidenceRepository
  let writes: VerifiedUserFiles
  static func live(otherTransferBusy: @escaping () -> Bool) -> Self {
    let device = FieldWorkflowDevice()
    let backups = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ProfileBackups", isDirectory: true)
    return Self(
      access: device, evidence: .init(reader: device),
      writes: .init(access: device, backupDirectory: backups, otherTransferBusy: otherTransferBusy))
  }
}
