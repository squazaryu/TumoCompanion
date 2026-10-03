import Foundation

@MainActor
protocol UpdateAssistantSource {
    func deviceInfo() async throws -> [(String, String)]
    func sdSpace() async throws -> (free: UInt64, total: UInt64)
    func catalog(_ identity: TumoflipDeviceIdentity) async throws -> String
    func list(_ path: String) async throws -> [FlipperFile]
    func checkedMD5(_ path: String) async throws -> String?
    func read(_ path: String) async throws -> Data
}

@MainActor
struct LiveUpdateAssistantSource: UpdateAssistantSource {
    private let storage = FlipperStorage()
    func deviceInfo() async throws -> [(String, String)] { try await FlipperSystem().deviceInfo() }
    func list(_ path: String) async throws -> [FlipperFile] { try await storage.list(path) }
    func checkedMD5(_ path: String) async throws -> String? { try await storage.checkedMD5(path, timeout: 300) }
    func read(_ path: String) async throws -> Data { try await storage.read(path) }

    func sdSpace() async throws -> (free: UInt64, total: UInt64) {
        let replies = try await storage.rpc.command { main in
            var request = PBStorage_InfoRequest(); request.path = "/ext"
            main.content = .storageInfoRequest(request)
        }
        for packet in replies {
            if case .storageInfoResponse(let info) = packet.content,
               info.totalSpace > 0, info.freeSpace <= info.totalSpace {
                return (info.freeSpace, info.totalSpace)
            }
        }
        throw SignalAnalysisError.invalid("SD capacity is unavailable")
    }

    func catalog(_ identity: TumoflipDeviceIdentity) async throws -> String {
        guard let version = identity.firmwareVersion,
              let channel = TumoflipFirmwareChannel.infer(version: version) else {
            throw SignalAnalysisError.invalid("Firmware channel not identified")
        }
        let selection = try await TumoflipPackageCatalogClient.live().latest(
            for: channel, installedVersion: version, installedAPI: identity.firmwareAPI,
            installedTarget: identity.hardwareTarget, installedCommit: identity.firmwareCommit,
            installedCommitDirty: identity.firmwareCommitDirty, forceRemote: true)
        return "\(selection.release.tag) · API \(selection.manifest.firmware.api). Catalog verified; installed bytes/private plugin contracts still require device verification."
    }
}
