import Foundation
import CryptoKit

func expectFailure(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("accepted invalid input: \(label)") } catch { }
}
func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
func fixed(_ value: String, _ size: Int) -> Data {
    var data = Data(value.utf8); precondition(data.count < size)
    data.append(Data(repeating: 0, count: size-data.count)); return data
}
func inventory(_ files: [(String, UInt32, Data)]) -> Data {
    var body = u32(0x31564954)+u32(1)+u32(292)+u32(0)
    for file in files { body += fixed(file.0,256)+u32(file.1)+Data(SHA256.hash(data:file.2)) }
    return body+u32(0x444E4554)+u32(UInt32(files.count))+Data(SHA256.hash(data:body))
}

let roundText = "Field round\nStarted UTC epoch: 100\nExplicit user results; opening a file is not a test.\nObject\tResult\tUTC epoch\tNote\nGate\tPASS\t101\tOwned test\nSensor\tPENDING\t0\t\n"
let round = try FieldRoundDocument.parse(Data(roundText.utf8))
precondition(round.started == 100 && round.rows.count == 2 && round.pending == 1)
expectFailure("unknown result") { _ = try FieldRoundDocument.parse(Data(roundText.replacingOccurrences(of:"PASS",with:"SENT").utf8)) }
expectFailure("pending timestamp") { _ = try FieldRoundDocument.parse(Data(roundText.replacingOccurrences(of:"PENDING\t0",with:"PENDING\t102").utf8)) }
expectFailure("bad note") { _ = try FieldRoundDocument.parse(Data(roundText.replacingOccurrences(of:"Owned test",with:String(repeating:"X",count:64)).utf8)) }
let firstBytes = inventory([("/ext/subghz/one.sub",3,Data("one".utf8))])
let first = try CaptureInventory.parse(firstBytes)
precondition(first.entries.count == 1 && first.entries[0].size == 3)
let second = try CaptureInventory.parse(inventory([("/ext/subghz/one.sub",3,Data("two".utf8)),("/ext/nfc/new.nfc",1,Data([1]))]))
precondition(first.compare(to: second).map(\.state) == [.changed,.added])
precondition(second.compare(to:first).contains { $0.state == .missing })
var changed = firstBytes; changed[20] ^= 1
expectFailure("corrupt digest") { _ = try CaptureInventory.parse(changed) }
expectFailure("truncation") { _ = try CaptureInventory.parse(firstBytes.dropLast()) }
expectFailure("traversal") { _ = try CaptureInventory.parse(inventory([("/ext/subghz/../one.sub",3,Data([1]))])) }
expectFailure("FAT duplicate") { _ = try CaptureInventory.parse(inventory([("/ext/nfc/A.nfc",1,Data([1])),("/ext/nfc/a.nfc",1,Data([1]))])) }
let comparison = try FieldComparisonDocument.parse(Data("MISSING\t/ext/subghz/one.sub\nADDED\t/ext/nfc/new.nfc\n".utf8))
precondition(comparison.rows.count == 2 && !comparison.provesCompleteScan)
precondition(try FieldComparisonDocument.parse(Data()).rows.isEmpty)
expectFailure("untrusted compare path") { _ = try FieldComparisonDocument.parse(Data("MISSING\t/ext/apps/data.fap\n".utf8)) }
print("Field round, inventory integrity/diff and incomplete-comparison evidence passed")
