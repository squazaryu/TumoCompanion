import Foundation
import CryptoKit
import ZIPFoundation

// Host stub only: the production backup implementation is compiled unchanged.
@MainActor final class FlipperStorage {
    var files: [String: Data] = ["/ext/subghz/one.sub": Data("own signal".utf8),
                               "/ext/nfc/card.nfc": Data("own card".utf8)]
    func list(_ path: String) async throws -> [FlipperFile] {
        files.sorted(by: { $0.key < $1.key }).compactMap { pathAndData in
            let (key, data) = pathAndData
            guard key.hasPrefix(path+"/"), !key.dropFirst(path.count+1).contains("/") else { return nil }
            return .init(name: (key as NSString).lastPathComponent, path: key, isDirectory: false, size: UInt32(data.count))
        }
    }
    func read(_ path: String) async throws -> Data { files[path]! }
    func checkedMD5(_ path: String, timeout: TimeInterval) async throws -> String? { files[path].map(FieldWire.md5) }
    func makeDirectory(_ path: String) async throws { }
    func write(_ path: String, data: Data, progress: (@Sendable (Int) -> Void)?) async throws { files[path] = data }
}

func rejected(_ body: () throws -> Void) {
    do { try body(); fatalError("invalid archive accepted") } catch { }
}
@MainActor func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("field-backup-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = FlipperStorage()
    let backup = FlipperBackup(storage: storage, directory: directory)
    let receipt = try await backup.backup(folders: ["subghz", "nfc"], stamp: "own-test")
    let index = try FlipperBackup.captureIndex(at: receipt.url)
    precondition(index.files.count == 2)
    let capture = try FlipperBackup.captureData(from: index, path: "subghz/one.sub")
    precondition(capture == Data("own signal".utf8))
    rejected { _ = try FlipperBackup.captureData(from: index, path: "../one.sub") }
    precondition(storage.files.count == 2, "Browsing/extracting cannot write to the SD")
    try Data("corrupt".utf8).write(to: receipt.url)
    rejected { _ = try FlipperBackup.captureData(from: index, path: "subghz/one.sub") }
    let legacy = directory.appendingPathComponent("legacy.zip")
    let zip = try Archive(url: legacy, accessMode: .create)
    let data = Data("old".utf8)
    try zip.addEntry(with: "subghz/old.sub", type: .file, uncompressedSize: Int64(data.count)) { offset, count in
        data.subdata(in: Int(offset)..<Int(offset)+count)
    }
    rejected { _ = try FlipperBackup.captureIndex(at: legacy) }
    print("Manifest-backed selective recovery verifies archive identity and makes no device writes")
}
try await run()
