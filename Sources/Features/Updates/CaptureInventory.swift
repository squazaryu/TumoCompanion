import Foundation

enum UpdateCheck: String, Codable {
    case unknown, passed, failed, manual
    var isPassed: Bool { self == .passed }
}

struct CaptureInventory: Codable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        let size: UInt64
        let md5: String?
    }
    struct Difference: Identifiable {
        enum Kind: String { case added, changed, missing, unverified }
        let path: String
        let kind: Kind
        var id: String { path }
    }
    let files: [File]
    private enum CodingKeys: String, CodingKey { case files }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(files: container.decode([File].self, forKey: .files))
    }

    init(files: [File]) throws {
        guard files.count <= 20_000, Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ Self.safePath($0.path) && ($0.md5 == nil ||
                  ($0.md5!.count == 32 && $0.md5!.allSatisfy { $0.isHexDigit && $0.isASCII })) }) else {
            throw SignalAnalysisError.invalid("Inventory has unsafe paths, duplicate files or invalid hashes.")
        }
        self.files = files.sorted { $0.path < $1.path }
    }

    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 512 && !path.contains("\\") &&
            !path.unicodeScalars.contains { $0.value < 32 } &&
            parts.count > 1 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func compare(to current: CaptureInventory) -> [Difference] {
        let old = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
        return Set(old.keys).union(new.keys).sorted().compactMap { path in
            guard let before = old[path] else { return .init(path: path, kind: .added) }
            guard let after = new[path] else { return .init(path: path, kind: .missing) }
            guard let a = before.md5, let b = after.md5 else {
                return .init(path: path, kind: .unverified)
            }
            return before.size == after.size && a.lowercased() == b.lowercased() ? nil :
                .init(path: path, kind: .changed)
        }
    }
}
