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
let emptyComparison = try FieldComparisonDocument.parse(Data())
precondition(emptyComparison.rows.isEmpty)
expectFailure("untrusted compare path") { _ = try FieldComparisonDocument.parse(Data("MISSING\t/ext/apps/data.fap\n".utf8)) }
print("Field round, inventory integrity/diff and incomplete-comparison evidence passed")

let card = PortableObjectCard(name:"Gate",notes:"Owned receiver",tags:"home",checkedAt:"",links:[.init(path:"/ext/subghz/one.sub",label:"Open")])
let bundle = try PortableObjectDocument(card:card,files:["/ext/subghz/one.sub":Data("one".utf8)])
let encodedBundle = try bundle.encoded()
precondition(encodedBundle.count == 2891 && encodedBundle.prefix(4) == u32(0x31424F54))
let decodedBundle = try PortableObjectDocument.decode(encodedBundle)
precondition(decodedBundle.card == card && decodedBundle.files[card.links[0].path] == Data("one".utf8))
var badBundle = encodedBundle; badBundle[badBundle.count-1] ^= 1
expectFailure("payload digest") { _ = try PortableObjectDocument.decode(badBundle) }
expectFailure("bundle trailing data") { _ = try PortableObjectDocument.decode(encodedBundle+Data([0])) }
expectFailure("unknown capture type") { _ = try PortableObjectDocument(card:.init(name:"Gate",notes:"",tags:"",checkedAt:"",links:[.init(path:"/ext/apps/bad.fap",label:"")]),files:["/ext/apps/bad.fap":Data([0])]).encoded() }
expectFailure("object name overflow") { _ = try PortableObjectDocument(card:.init(name:String(repeating:"A",count:25),notes:"",tags:"",checkedAt:"",links:[]),files:[:]).encoded() }

let profileData = Data("# original\nFiletype: Flipper SubGhz Setting File\nVersion: 1\nAdd_standard_frequencies: true\nFrequency: 433920000\nHopper_frequency: 433920000\nDefault_frequency: 433920000\nHopping_Preset: AM650\nCustom_preset_name: Owned\nCustom_preset_module: CC1101\nCustom_preset_data: 00 00 C0\nFuture_field: preserved\n".utf8)
var profile = try SubGhzProfile.parse(profileData)
profile.frequencies.append(868350000);profile.hopperFrequencies=[433920000,868350000]
profile.defaultFrequency=868350000;profile.hoppingPresets=["AM650","FM476"]
let renderedProfile = try profile.encoded()
let profileText = String(decoding:renderedProfile,as:UTF8.self)
precondition(profileText.contains("Future_field: preserved") && profileText.contains("Custom_preset_data: 00 00 C0"))
let reloadedProfile = try SubGhzProfile.parse(renderedProfile)
precondition(reloadedProfile.defaultFrequency == 868350000)
profile.hoppingPresets=["TumoHonda"]
expectFailure("explicit RX profile in ordinary hopping") { _ = try profile.encoded() }
expectFailure("unsupported profile version") { _ = try SubGhzProfile.parse(Data("Filetype: Flipper SubGhz Setting File\nVersion: 2\n".utf8)) }
expectFailure("frequency outside radio ranges") { _ = try SubGhzProfile.parse(Data(String(decoding:profileData,as:UTF8.self).replacingOccurrences(of:"433920000",with:"100000000").utf8)) }
print("Portable object wire format and guarded Sub-GHz profile editing passed")

@MainActor final class MemoryUserFiles: UserFileAccess {
    var device = "owned-device-A"
    var files: [String:Data] = [:]
    var writes = 0
    var failWrite = false
    func deviceID() async throws -> String { device }
    func read(_ path: String, maximumBytes: Int) async throws -> Data {
        guard let data = files[path], data.count <= maximumBytes else { throw FieldWorkflowError.invalid("read") }
        return data
    }
    func checksum(_ path: String) async throws -> String? { files[path].map(FieldWire.md5) }
    func write(_ path: String, data: Data) async throws {
        writes += 1
        if failWrite { files[path] = data.prefix(data.count/2);throw FieldWorkflowError.invalid("injected write failure") }
        files[path] = data
    }
    func makeDirectory(_ path: String) async throws { }
}
@MainActor func userFileTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let fs = MemoryUserFiles()
    fs.files[VerifiedUserFiles.profilePath] = profileData
    fs.files["/ext/subghz/original.sub"] = Data("keep".utf8)
    let service = VerifiedUserFiles(access:fs,backupDirectory:directory)
    let snapshot = try await service.readProfile()
    var edited = try SubGhzProfile.parse(profileData);edited.frequencies.append(868350000)
    let receipt = try await service.applyProfile(edited, expected:snapshot)
    precondition(receipt.phase == .committed && receipt.original == profileData)
    let initialRecords = try service.records()
    precondition(initialRecords.count == 1)
    let count = fs.writes
    do { _ = try await service.applyProfile(edited,expected:snapshot);fatalError("stale write accepted") } catch { }
    precondition(fs.writes == count)
    fs.device = "other"
    do { _ = try await service.applyProfile(edited,expected:snapshot);fatalError("other device accepted") } catch { }
    precondition(fs.writes == count);fs.device = snapshot.deviceID
    let fresh = try await service.readProfile()
    fs.failWrite = true
    do { _ = try await service.applyProfile(try SubGhzProfile.parse(profileData),expected:fresh);fatalError("write failure hidden") } catch { }
    fs.failWrite = false
    let records = try service.records()
    guard let pending = records.first(where:{$0.phase == .needsRecovery || $0.phase == .writing}) else { fatalError("no durable recovery intent") }
    let current = try await fs.checksum(VerifiedUserFiles.profilePath)
    try await service.restoreProfileBackup(pending,expectedCurrentMD5:current)
    precondition(fs.files[VerifiedUserFiles.profilePath] == fresh.data)
    let copy = try await service.copyCapture(Data("copy".utf8), originalPath:"/ext/subghz/original.sub",deviceID:fs.device)
    precondition(copy != "/ext/subghz/original.sub" && fs.files[copy] == Data("copy".utf8))
    precondition(fs.files["/ext/subghz/original.sub"] == Data("keep".utf8))
    do { _ = try await service.copyCapture(Data([1]),originalPath:"/ext/apps/not-a-signal.fap",deviceID:fs.device);fatalError("unsafe restore accepted") } catch { }
}
try await userFileTests()
print("Bound device, durable backup, conflict/recovery and copy-only restore passed")

try await DeviceFileMutationGate.withLease {
    try await DeviceFileMutationGate.withMutation { }
    let foreignWrite = await Task.detached { () -> Bool in
        do { try await DeviceFileMutationGate.withMutation { };return false }
        catch { return true }
    }.value
    precondition(foreignWrite)
    do { try await DeviceFileMutationGate.withLease { };fatalError("second lease accepted") } catch { }
}
try await DeviceFileMutationGate.withMutation { }
print("Exclusive user-write lease rejects foreign writers and releases correctly")

@MainActor final class EvidenceMemoryReader: FieldEvidenceReading {
    let root = FieldEvidenceRepository.root
    var bytes = Data("Field round\nStarted UTC epoch: 100\nExplicit user results; opening a file is not a test.\nObject\tResult\tUTC epoch\tNote\nGate\tPASS\t101\tOwned\n".utf8)
    var corrupt = false
    func list(_ path: String) async throws -> [FlipperFile] {
        guard path == root+"/reports" else { return [] }
        let name = "round-100-0123456789abcdef.txt"
        return [.init(name:name,path:path+"/"+name,isDirectory:false,size:UInt32(bytes.count))]
    }
    func read(_ path: String, maximumBytes: Int) async throws -> Data { corrupt ? bytes+Data([0]) : bytes }
    func checksum(_ path: String) async throws -> String? { FieldWire.md5(bytes) }
}
@MainActor func repositoryTests() async throws {
    let reader = EvidenceMemoryReader();let repository = FieldEvidenceRepository(reader:reader)
    let files = try await repository.index();precondition(files.count == 1)
    let snapshot = try await repository.load(files[0])
    guard case .round(let report) = snapshot.document else { fatalError("wrong evidence kind") }
    precondition(report.rows.count == 1)
    reader.corrupt = true
    do { _ = try await repository.load(files[0]);fatalError("changed bytes accepted") } catch { }
}
try await repositoryTests()
print("Read-only evidence repository validates paths, sizes and device checksums")
