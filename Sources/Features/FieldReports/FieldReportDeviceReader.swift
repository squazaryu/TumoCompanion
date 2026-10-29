import Foundation

struct FieldReportDeviceReader: FieldReportReading {
    private let storage = FlipperStorage()
    func list(_ path: String) async throws -> [FlipperFile] {
        do { return try await storage.list(path) }
        catch FlipperRPCError.status(let status) where status == .errorStorageNotExist { return [] }
    }
    func read(_ path: String, maximumBytes: Int) async throws -> Data {
        try await storage.read(path, maximumBytes: maximumBytes)
    }
    func checksum(_ path: String) async throws -> String? { try await storage.checkedMD5(path) }
}
