import CryptoKit
import Foundation
import XCTest
@testable import UnleashedCompanion

@MainActor
final class FlipperBackupTests: XCTestCase {
    private enum FakeError: Error { case readFailed }

    private final class FakeStorage: FlipperBackupStorage {
        var files: [String: Data] = [:]
        var unreadable = Set<String>()
        var wrongSize = Set<String>()
        var directories = Set<String>()
        var readCount = 0
        var afterRead: (() -> Void)?

        func list(_ path: String) async throws -> [FlipperFile] {
            let prefix = path + "/"
            return files.keys.sorted().compactMap { filePath in
                guard filePath.hasPrefix(prefix) else { return nil }
                let name = String(filePath.dropFirst(prefix.count))
                guard !name.contains("/") else { return nil }
                let size = files[filePath]!.count + (wrongSize.contains(filePath) ? 1 : 0)
                return FlipperFile(
                    name: name, path: filePath, isDirectory: false, size: UInt32(size))
            }
        }

        func read(_ path: String) async throws -> Data {
            readCount += 1
            if unreadable.contains(path) { throw FakeError.readFailed }
            let data = files[path]!
            afterRead?()
            return data
        }

        func checkedMD5(_ path: String, timeout: TimeInterval) async throws -> String? {
            guard let data = files[path] else { return nil }
            return Insecure.MD5.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
        }

        func makeDirectory(_ path: String) async throws { directories.insert(path) }

        func write(
            _ path: String,
            data: Data,
            progress: (@Sendable (Int) -> Void)?
        ) async throws {
            files[path] = data
        }
    }

    func testSecondBackupReusesVerifiedUnchangedBytesButRemainsStandalone() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        storage.files = ["/ext/subghz/one.sub": Data("one".utf8),
                         "/ext/subghz/two.sub": Data("two".utf8)]
        let backup = FlipperBackup(storage: storage, directory: directory)
        let first = try await backup.backup(folders: ["subghz"], stamp: "first")
        XCTAssertEqual(storage.readCount, 2)
        storage.files["/ext/subghz/two.sub"] = Data("new".utf8)
        let second = try await backup.backup(folders: ["subghz"], stamp: "second")
        XCTAssertEqual(storage.readCount, 3, "Only changed data should cross BLE again")
        try FileManager.default.removeItem(at: first.url)
        storage.files.removeAll()
        try await backup.restore(second.url)
        XCTAssertEqual(storage.files["/ext/subghz/one.sub"], Data("one".utf8))
        XCTAssertEqual(storage.files["/ext/subghz/two.sub"], Data("new".utf8))
    }

    func testChangedInventoryCannotPublishBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        storage.files["/ext/subghz/one.sub"] = Data("one".utf8)
        storage.afterRead = { storage.files["/ext/subghz/new.sub"] = Data("new".utf8) }
        let backup = FlipperBackup(storage: storage, directory: directory)
        do {
            _ = try await backup.backup(folders: ["subghz"], stamp: "changing")
            XCTFail("An incomplete inventory must not become a successful snapshot")
        } catch { }
        XCTAssertTrue(backup.backups.isEmpty)
    }

    func testCorruptedPreviousArchiveFallsBackToDeviceRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        storage.files["/ext/subghz/one.sub"] = Data("one".utf8)
        let backup = FlipperBackup(storage: storage, directory: directory)
        let first = try await backup.backup(folders: ["subghz"], stamp: "first")
        try Data("corrupt".utf8).write(to: first.url)
        let second = try await backup.backup(folders: ["subghz"], stamp: "second")
        XCTAssertEqual(storage.readCount, 2)
        storage.files.removeAll()
        try await backup.restore(second.url)
        XCTAssertEqual(storage.files["/ext/subghz/one.sub"], Data("one".utf8))
    }

    func testFailedReadDoesNotPublishPartialBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        storage.files = [
            "/ext/subghz/one.sub": Data("one".utf8),
            "/ext/subghz/two.sub": Data("two".utf8),
        ]
        storage.unreadable.insert("/ext/subghz/two.sub")
        let backup = FlipperBackup(storage: storage, directory: directory)

        do {
            _ = try await backup.backup(folders: ["subghz"], stamp: "20260929-1200")
            XCTFail("An unreadable file must fail the whole backup")
        } catch { }

        XCTAssertTrue(backup.backups.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSizeMismatchDoesNotPublishBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        let path = "/ext/subghz/key.sub"
        storage.files[path] = Data("capture".utf8)
        storage.wrongSize.insert(path)
        let backup = FlipperBackup(storage: storage, directory: directory)

        do {
            _ = try await backup.backup(folders: ["subghz"], stamp: "20260929-1200")
            XCTFail("A short read must fail the whole backup")
        } catch { }

        XCTAssertTrue(backup.backups.isEmpty)
    }

    func testBackupCanBeVerifiedAndRestored() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        let path = "/ext/subghz/own-key.sub"
        let original = Data("saved capture".utf8)
        storage.files[path] = original
        let backup = FlipperBackup(storage: storage, directory: directory)

        let receipt = try await backup.backup(folders: ["subghz"], stamp: "20260929-1200")
        XCTAssertEqual(receipt.files, 1)
        XCTAssertEqual(receipt.bytes, Int64(original.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.url.path))

        storage.files.removeAll()
        try await backup.restore(receipt.url)
        XCTAssertEqual(storage.files[path], original)
    }

    func testSameMinuteCreatesDistinctBackups() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FakeStorage()
        storage.files["/ext/subghz/own-key.sub"] = Data("first".utf8)
        let backup = FlipperBackup(storage: storage, directory: directory)

        let first = try await backup.backup(folders: ["subghz"], stamp: "20260929-1200")
        storage.files["/ext/subghz/own-key.sub"] = Data("second".utf8)
        let second = try await backup.backup(folders: ["subghz"], stamp: "20260929-1200")

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(backup.backups.count, 2)
    }

    func testRestorePathRejectsTraversalAndAbsolutePaths() {
        XCTAssertThrowsError(try FlipperBackup.safeDestination(for: "../secret"))
        XCTAssertThrowsError(try FlipperBackup.safeDestination(for: "subghz/../secret"))
        XCTAssertThrowsError(try FlipperBackup.safeDestination(for: "/int/settings"))
        XCTAssertThrowsError(try FlipperBackup.safeDestination(for: "subghz\\key.sub"))
        XCTAssertEqual(
            try FlipperBackup.safeDestination(for: "subghz/own-key.sub"),
            "/ext/subghz/own-key.sub")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipper-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
