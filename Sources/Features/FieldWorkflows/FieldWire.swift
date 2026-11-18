import Foundation
import CryptoKit

enum FieldWorkflowError: LocalizedError, Equatable {
    case invalid(String)
    case conflict
    case deviceChanged
    case recoveryRequired
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Field data rejected: \(reason)."
        case .conflict: return "The file changed since preview. Read it again before applying."
        case .deviceChanged: return "The connected device changed. Read and confirm again."
        case .recoveryRequired: return "The write could not be verified. Keep the backup and inspect recovery before retrying."
        }
    }
}

enum FieldWire {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
    }
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count, data.count-offset >= 4 else {
            throw FieldWorkflowError.invalid("truncated integer")
        }
        return (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex+offset+$1]) << ($1*8) }
    }
    static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded:value >> ($0*8)) })
    }
    static func text(_ data: Data, _ offset: Int, _ length: Int) throws -> String {
        guard offset >= 0, length > 0, offset <= data.count, length <= data.count-offset else {
            throw FieldWorkflowError.invalid("truncated string")
        }
        let bytes = data.subdata(in:offset..<offset+length)
        guard let end = bytes.firstIndex(of:0),
              let value = String(data:bytes.prefix(upTo:end),encoding:.utf8),
              printable(value) else { throw FieldWorkflowError.invalid("unterminated or invalid text") }
        return value
    }
    static func printable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    static func objectName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 24 && name.first != " " && name.last != " " &&
        name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || [32,45,95].contains($0) }
    }
    static func capturePath(_ path: String) -> Bool {
        guard path.utf8.count < 256, printable(path), !path.contains("\\") else { return false }
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count >= 4, parts.count <= 10, parts[0].isEmpty, parts[1] == "ext",
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        let extensions = ["subghz":"sub","infrared":"ir","nfc":"nfc","lfrfid":"rfid","ibutton":"ibtn"]
        return extensions[String(parts[2])] == (path as NSString).pathExtension.lowercased()
    }
    static func linkPath(_ path: String) -> Bool {
        guard path.hasPrefix("/ext/"), path.utf8.count < 256, printable(path), !path.contains("\\"),
              path.split(separator:"/",omittingEmptySubsequences:false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return ["sub","ir","nfc","rfid","ibtn"].contains((path as NSString).pathExtension.lowercased())
    }
    static func cString(_ text: String, capacity: Int) throws -> Data {
        guard printable(text), text.utf8.count < capacity else { throw FieldWorkflowError.invalid("text is too long or has controls") }
        var result = Data(text.utf8)
        result.append(Data(repeating:0,count:capacity-result.count))
        return result
    }
}
