import Foundation

@MainActor protocol UserFileAccess {
    func deviceID() async throws -> String
    func read(_ path: String, maximumBytes: Int) async throws -> Data
    func checksum(_ path: String) async throws -> String?
    func write(_ path: String, data: Data) async throws
    func makeDirectory(_ path: String) async throws
}

struct UserFileSnapshot: Equatable {
    let deviceID: String
    let path: String
    let data: Data
    let sha256: String
}

struct UserProfileWriteRecord: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case prepared, writing, committed, unchanged, needsRecovery, restoring, restored }
    let id: UUID
    let deviceID: String
    let original: Data
    let originalSHA256: String
    let expectedSHA256: String
    var phase: Phase
}

/// Local checked backups/intent records, separate from package ownership/ledgers.
/// This is NOT a power-loss-atomic remote filesystem transaction or global SD lock.
@MainActor final class VerifiedUserFiles {
    static let profilePath = "/ext/subghz/assets/setting_user"
    let access: any UserFileAccess
    let backupDirectory: URL
    private let otherTransferBusy: () -> Bool
    private var running = false

    init(access: any UserFileAccess, backupDirectory: URL, otherTransferBusy: @escaping () -> Bool = { false }) {
        self.access = access; self.backupDirectory = backupDirectory; self.otherTransferBusy = otherTransferBusy
    }
    func snapshot(_ path: String, maximumBytes: Int) async throws -> UserFileSnapshot {
        try Task.checkCancellation()
        let device = try await access.deviceID()
        guard !device.isEmpty, let before = try await access.checksum(path) else { throw FieldWorkflowError.invalid("device identity or missing file") }
        let data = try await access.read(path,maximumBytes:maximumBytes)
        try Task.checkCancellation()
        guard data.count <= maximumBytes, try await access.deviceID() == device,
              try await access.checksum(path) == before, FieldWire.md5(data) == before else { throw FieldWorkflowError.conflict }
        return UserFileSnapshot(deviceID:device,path:path,data:data,sha256:FieldWire.sha256(data))
    }
    func readProfile() async throws -> UserFileSnapshot { try await snapshot(Self.profilePath,maximumBytes:SubGhzProfile.maximumBytes) }

    private func recordURL(_ id: UUID) -> URL { backupDirectory.appendingPathComponent(id.uuidString+".json") }
    private func persist(_ record: UserProfileWriteRecord) throws {
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:backupDirectory.path)
        #endif
        let data = try JSONEncoder().encode(record)
        let url = recordURL(record.id)
        if !FileManager.default.fileExists(atPath:url.path) {
            guard try records().count < 256 else { throw FieldWorkflowError.invalid("recovery storage is full; export records first") }
        }
        try data.write(to:url,options:.atomic)
        let handle = try FileHandle(forWritingTo:url)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        guard try Data(contentsOf:url) == data else { throw FieldWorkflowError.invalid("backup readback") }
    }
    func records() throws -> [UserProfileWriteRecord] {
        guard FileManager.default.fileExists(atPath:backupDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at:backupDirectory,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
        guard files.count <= 256 else { throw FieldWorkflowError.invalid("too many recovery records; export old records first") }
        return try files.map { url in
            let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 128*1024 else { throw FieldWorkflowError.invalid("recovery record size/type") }
            let record = try JSONDecoder().decode(UserProfileWriteRecord.self,from:Data(contentsOf:url))
            guard url.lastPathComponent == record.id.uuidString+".json", record.original.count <= SubGhzProfile.maximumBytes,
                  record.originalSHA256 == FieldWire.sha256(record.original), record.expectedSHA256.count == 64,
                  record.expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !record.deviceID.isEmpty, record.deviceID.utf8.count <= 256 else { throw FieldWorkflowError.invalid("recovery record integrity") }
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func bound(_ device: String) async throws {
        try Task.checkCancellation()
        guard try await access.deviceID() == device else { throw FieldWorkflowError.deviceChanged }
    }
    private func begin() throws {
        guard !running, !otherTransferBusy() else { throw FieldWorkflowError.invalid("another transfer is active") }
        running = true
    }
    func applyProfile(_ profile: SubGhzProfile, expected: UserFileSnapshot) async throws -> UserProfileWriteRecord {
        try await DeviceFileMutationGate.withLease { try await self.applyProfileUnlocked(profile,expected:expected) }
    }
    private func applyProfileUnlocked(_ profile: SubGhzProfile, expected: UserFileSnapshot) async throws -> UserProfileWriteRecord {
        let data = try profile.encoded()
        guard expected.path == Self.profilePath, expected.data.count <= SubGhzProfile.maximumBytes,
              expected.sha256 == FieldWire.sha256(expected.data) else { throw FieldWorkflowError.invalid("profile preview identity") }
        try begin(); defer { running = false }
        try await bound(expected.deviceID)
        guard try !records().contains(where: {
            $0.deviceID == expected.deviceID && [.prepared, .writing, .needsRecovery, .restoring].contains($0.phase)
        }) else { throw FieldWorkflowError.recoveryRequired }
        guard try await access.checksum(Self.profilePath) == FieldWire.md5(expected.data) else { throw FieldWorkflowError.conflict }
        var record = UserProfileWriteRecord(id:UUID(),deviceID:expected.deviceID,original:expected.data,
                                          originalSHA256:expected.sha256,expectedSHA256:FieldWire.sha256(data),phase:.prepared)
        try persist(record) // Verified durable original before any remote mutation.
        var touched = false
        do {
            try await bound(expected.deviceID)
            guard try await access.checksum(Self.profilePath) == FieldWire.md5(expected.data) else { throw FieldWorkflowError.conflict }
            try Task.checkCancellation()
            record.phase = .writing; try persist(record)
            touched = true
            try await access.write(Self.profilePath,data:data)
            try await bound(expected.deviceID)
            guard try await access.checksum(Self.profilePath) == FieldWire.md5(data) else { throw FieldWorkflowError.recoveryRequired }
            record.phase = .committed; try persist(record)
            return record
        } catch {
            record.phase = touched ? .needsRecovery : .unchanged
            try? persist(record)
            throw error
        }
    }
    func restoreProfileBackup(_ selected: UserProfileWriteRecord, expectedCurrentMD5: String?) async throws {
        try await DeviceFileMutationGate.withLease { try await self.restoreProfileBackupUnlocked(selected,expectedCurrentMD5:expectedCurrentMD5) }
    }
    private func restoreProfileBackupUnlocked(_ selected: UserProfileWriteRecord, expectedCurrentMD5: String?) async throws {
        guard let stored = try records().first(where:{$0.id == selected.id}), stored == selected else { throw FieldWorkflowError.conflict }
        try begin(); defer { running = false }
        try await bound(stored.deviceID)
        guard try await access.checksum(Self.profilePath) == expectedCurrentMD5 else { throw FieldWorkflowError.conflict }
        var record = stored
        record.phase = .restoring; try persist(record)
        do {
            try await bound(stored.deviceID)
            guard try await access.checksum(Self.profilePath) == expectedCurrentMD5 else { throw FieldWorkflowError.conflict }
            try Task.checkCancellation()
            try await access.write(Self.profilePath,data:stored.original)
            try await bound(stored.deviceID)
            guard try await access.checksum(Self.profilePath) == FieldWire.md5(stored.original) else { throw FieldWorkflowError.recoveryRequired }
            record.phase = .restored; try persist(record)
        } catch {
            record.phase = .needsRecovery; try? persist(record); throw error
        }
    }
    func copyCapture(_ data: Data, originalPath: String, deviceID: String) async throws -> String {
        guard FieldWire.capturePath(originalPath), data.count <= 16*1024*1024 else { throw FieldWorkflowError.invalid("recording path or size") }
        let parts = originalPath.split(separator:"/")
        let folder = "/ext/\(parts[1])/Restored"
        let target = folder+"/"+UUID().uuidString+"."+(originalPath as NSString).pathExtension.lowercased()
        return try await DeviceFileMutationGate.withLease { try await self.createCopy(data,target:target,deviceID:deviceID) }
    }
    func uploadObject(_ document: PortableObjectDocument, deviceID: String) async throws -> String {
        try await DeviceFileMutationGate.withLease {
            try await self.createCopy(document.encoded(),target:"/ext/apps_data/device_library/exports/phone-\(UUID().uuidString).tobj",deviceID:deviceID)
        }
    }
    private func createCopy(_ data: Data, target: String, deviceID: String) async throws -> String {
        try begin(); defer { running = false }
        try await bound(deviceID)
        var path = ""
        for component in target.split(separator:"/").dropLast() {
            path += "/"+component; try await access.makeDirectory(path)
        }
        try await bound(deviceID)
        guard try await access.checksum(target) == nil else { throw FieldWorkflowError.conflict }
        try Task.checkCancellation()
        try await access.write(target,data:data)
        try await bound(deviceID)
        guard try await access.checksum(target) == FieldWire.md5(data) else { throw FieldWorkflowError.recoveryRequired }
        return target // A failed new copy may remain; no existing file is deleted.
    }
}
