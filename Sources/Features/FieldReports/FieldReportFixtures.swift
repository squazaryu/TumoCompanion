#if DEBUG
import Foundation
import CryptoKit

/// Synthetic, local-only fixtures. Never queries Bluetooth or modifies a device.
struct FieldReportFixtureReader: FieldReportReading {
    func data(_ kind: FieldReportKind) -> Data {
        let rows: String
        switch kind {
        case .sensors:
            rows = (0..<24).map { "object:Garage,Nexus-TH,123,1,433920000,\(123 + $0),\(220 + $0 % 7),\(54 + $0 % 4),0,\($0 + 1)\n" }.joined()
        case .power:
            rows = (0..<24).map { "\(123 + $0),\(90 - $0 / 5),\(4140 - $0 * 3),-32,251,90000,0,0,98\n" }.joined()
        case .uhf:
            rows = "E2000017221101441890ABCD,12288,1,4,123,128,98,45\nE2000017221101441890ABCE,12288,1,2,124,128,91,46\n"
        case .varta:
            rows = "live,123456789A,32,1,0,0,0,0\n"
        }
        return Data((kind.header.joined(separator: ",") + "\n" + rows).utf8)
    }
    func list(_ path: String) async throws -> [FlipperFile] {
        FieldReportKind.allCases.filter { $0.directory == path }.map { kind in
            let name = "\(kind.rawValue)_123_0.csv"
            return FlipperFile(name: name, path: "\(path)/\(name)", isDirectory: false, size: UInt32(data(kind).count))
        }
    }
    func read(_ path: String, maximumBytes: Int) async throws -> Data {
        guard let kind = FieldReportKind.allCases.first(where: { path == "\($0.directory)/\($0.rawValue)_123_0.csv" }) else { throw FieldReportError.invalid("fixture path") }
        return data(kind)
    }
    func checksum(_ path: String) async throws -> String? {
        Insecure.MD5.hash(data: try await read(path, maximumBytes: 65536)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
