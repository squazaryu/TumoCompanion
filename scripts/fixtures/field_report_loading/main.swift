import Foundation
import CryptoKit

actor Reader: FieldReportReading {
    var reads = 0
    var mode = 0
    let data = Data("source,id,clock,known_prefix,config_present,config_match,marker_present,marker_match\nlive,123456789A,32,1,0,0,0,0\n".utf8)
    func set(_ value: Int) { mode = value; reads = 0 }
    func list(_ path: String) async throws -> [FlipperFile] {
        if mode == 5 {
            return (0..<32).map { i in
                let name = "varta_123_\(i).csv"
                return FlipperFile(name: name, path: path + "/" + name, isDirectory: false, size: UInt32(data.count))
            }
        }
        return [FlipperFile(name: "varta_123_0.csv", path: path + "/varta_123_0.csv", isDirectory: false, size: UInt32(data.count)),
         FlipperFile(name: "varta_124_0.csv", path: "/ext/subghz/own.sub", isDirectory: false, size: 4)]
    }
    func read(_ path: String, maximumBytes: Int) async throws -> Data {
        precondition(maximumBytes == 65536); reads += 1
        if mode == 3 { throw CancellationError() }
        return mode == 1 ? data + Data([10]) : data
    }
    func checksum(_ path: String) async throws -> String? {
        if mode == 2 { return nil }
        return mode == 4 && reads > 0 ? String(repeating: "0", count: 32) : Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@main struct Run {
    static func main() async throws {
        let reader = Reader(), repo = FieldReportRepository(reader: Reader())
        let files = try await repo.index()
        precondition(files.count == 1 && files[0].name == "varta_123_0.csv")
        let subject = FieldReportRepository(reader: reader)
        let snapshot = try await subject.load(files[0])
        precondition(snapshot.document.kind == .varta && snapshot.sha256.count == 64 && snapshot.data.count == Int(files[0].size))
        for mode in 1...4 {
            await reader.set(mode)
            do { _ = try await subject.load(files[0]); fatalError("Accepted a changing/unverifiable report") } catch {}
        }
        await reader.set(0)
        do {
            _ = try await subject.load(FlipperFile(name: "varta_123_0.csv", path: "/ext/subghz/own.sub", isDirectory: false, size: files[0].size))
            fatalError("Read an unapproved path")
        } catch {}
        let readCount = await reader.reads
        precondition(readCount == 0)
        await reader.set(5)
        let ordered = try await subject.index()
        precondition(ordered.count == 32 && ordered.first?.name == "varta_123_31.csv" && ordered.last?.name == "varta_123_0.csv")
        print("Field report repository: bounded reads, path confinement, checksums and cancellation verified")
    }
}
