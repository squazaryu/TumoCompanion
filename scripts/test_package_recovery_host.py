"""Run production recovery code on macOS; no device access or Simulator.

Optional local forensic replay: --snapshot <state-slot> --observations <MD5 JSON>.
Private device snapshots are never copied into the repository or CI fixtures.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'Sources/Features/Updates/TumoflipUpdater.swift').read_text()


def declaration(signature):
    start = SOURCE.index(signature)
    brace = SOURCE.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
        end += 1
    return SOURCE[start:end]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--snapshot', type=Path)
parser.add_argument('--observations', type=Path)
parser.add_argument('--emit-state', type=Path)
args = parser.parse_args()
if bool(args.snapshot) != bool(args.observations):
    parser.error('snapshot and observations must be supplied together')
if args.emit_state and not args.snapshot:
    parser.error('state emission requires a forensic snapshot')

models = '\n'.join(declaration(signature) for signature in (
    'protocol TumoflipDeviceFS {', 'extension TumoflipDeviceFS {',
    'protocol TumoflipPackageSource {', 'enum TumoflipInstallError:',
    'enum TumoflipHash {', 'struct TumoflipState:', 'struct TumoflipJournal:',
    'private struct TumoflipStateEnvelope:',
))
prefix = SOURCE[SOURCE.index('struct TumoflipInstaller {'):SOURCE.index('    private func txnDir(')]
methods = '\n'.join(declaration(signature) for signature in (
    '    private func txnDir(', '    private func stageDir(', '    private func rollbackDir(',
    '    private static func encoder(', '    static func encodeStateSlot(',
    '    static func decodeStateSlot(', '    private func loadState(',
    '    private func saveState(', '    func recover(', '    private func checkedDeviceMD5(',
    '    private func transactionDeviceMD5(', '    private func rollback(',
    '    private func restore(', '    private func copyRemoveVerified(',
))
for signature in ('    private func finalizeVerifiedRecovery(',):
    if signature in SOURCE:
        methods += '\n' + declaration(signature)
policy_path = ROOT / 'Sources/Features/Updates/TumoflipRecoveryFinalization.swift'
policy = policy_path.read_text() if policy_path.exists() else ''
program = 'import Foundation\nimport CryptoKit\n' + models + '\n' + policy + '\n' + prefix + methods + '\n}\n' + r'''
final class MemoryFS: TumoflipDeviceFS, @unchecked Sendable {
    enum Failure: Error { case injected, missing }
    var slots: [String: Data] = [:]
    var hashes: [String: String] = [:]
    var writes: [String] = []
    var fileMutations: [String] = []
    var failedHashes = Set<String>()
    func read(_ path: String) async -> Data? { slots[path] }
    func deviceMD5(_ path: String) async -> String? {
        slots[path].map(TumoflipHash.md5) ?? hashes[path]
    }
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        if failedHashes.contains(path) { throw Failure.injected }
        return await deviceMD5(path)
    }
    func fileSize(_ path: String) async -> Int? { slots[path]?.count }
    func write(_ data: Data, to path: String) async throws {
        writes.append(path)
        slots[path] = data
    }
    func move(_ from: String, to: String) async throws {
        guard let hash = hashes.removeValue(forKey: from) else { throw Failure.missing }
        fileMutations.append("move:" + from + ":" + to)
        hashes[to] = hash
    }
    func delete(_ path: String) async throws {
        fileMutations.append("delete:" + path)
        hashes.removeValue(forKey: path)
    }
    func deleteTree(_ path: String) async throws {
        fileMutations.append("tree:" + path)
        hashes = hashes.filter { !$0.key.hasPrefix(path + "/") }
    }
    func makeDirectory(_ path: String) async throws {}
    func exists(_ path: String) async -> Bool { hashes[path] != nil || slots[path] != nil }
    func state() -> TumoflipState? {
        slots.values.compactMap(TumoflipInstaller.decodeStateSlot).max { $0.generation < $1.generation }
    }
}
struct NoSource: TumoflipPackageSource {
    func bytes(for source: String) async throws -> Data { throw MemoryFS.Failure.missing }
}
func fixture() throws -> (MemoryFS, TumoflipJournal.FileOp) {
    let fs = MemoryFS()
    let path = "/ext/apps/Tools/example.fap"
    let old = TumoflipHash.md5(Data("old".utf8))
    let new = TumoflipHash.md5(Data("new".utf8))
    let sha = TumoflipHash.sha256(Data("new".utf8))
    let fingerprint = String(repeating: "f", count: 64)
    let op = TumoflipJournal.FileOp(target: path, stage: path + ".ucnew",
        backup: "/ext/.tumoflip/rollback/" + fingerprint.prefix(16) + "/" + TumoflipHash.sha256(Data(path.utf8)),
        sha256: sha, md5: new, originalMD5: old, hadOriginal: true, state: .activated)
    let journal = TumoflipJournal(releaseId: String(repeating: "a", count: 64),
        fingerprint: fingerprint, groups: ["base"], phase: .activating, ops: [op], cleanups: [])
    let state = TumoflipState(generation: 10, ledger: [path: .init(sha256: sha,
        md5: new, releaseId: journal.releaseId)], txn: journal)
    fs.slots[TumoflipInstaller.stateSlotA] = try TumoflipInstaller.encodeStateSlot(state)
    fs.hashes[path] = new
    return (fs, op)
}
@main struct Main {
    static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        do {
            let (fs, op) = try fixture()
            let before = fs.hashes
            do { try await TumoflipInstaller(fs: fs, source: NoSource()).recover() }
            catch { print("Completion recovery threw:", error) }
            check(fs.state()?.txn == nil, "verified installed ledger/new files with no rollback copy can finish")
            check(fs.hashes == before && fs.fileMutations.isEmpty,
                  "finishing does not rewrite or delete any application file")
            check(fs.state()?.ledger[op.target]?.md5 == op.md5, "installed ledger is retained")
        }
        do {
            let (fs, op) = try fixture()
            fs.hashes[op.backup] = op.originalMD5
            try await TumoflipInstaller(fs: fs, source: NoSource()).recover()
            check(fs.hashes[op.target] == op.originalMD5 && fs.state()?.txn == nil,
                  "a real rollback copy preserves the original rollback behavior")
        }
        do {
            let (fs, op) = try fixture()
            fs.hashes[op.target] = String(repeating: "0", count: 32)
            let before = fs.hashes
            do { try await TumoflipInstaller(fs: fs, source: NoSource()).recover() }
            catch {}
            check(fs.state()?.txn != nil && fs.hashes == before,
                  "changed app bytes never authorize completion or deletion")
        }
        do {
            let (fs, op) = try fixture()
            var oldState = fs.state()!
            oldState.ledger[op.target] = .init(sha256: String(repeating: "b", count: 64),
                md5: op.originalMD5!, releaseId: String(repeating: "c", count: 64))
            fs.slots[TumoflipInstaller.stateSlotA] = try TumoflipInstaller.encodeStateSlot(oldState)
            do { try await TumoflipInstaller(fs: fs, source: NoSource()).recover() }
            catch {}
            check(fs.state()?.txn != nil, "new file presence alone does not authorize completion")
        }
        do {
            let (fs, op) = try fixture()
            fs.failedHashes.insert(op.target)
            do { try await TumoflipInstaller(fs: fs, source: NoSource()).recover() }
            catch {}
            check(fs.state()?.txn != nil && fs.fileMutations.isEmpty,
                  "a transport error preserves the journal and all app files")
        }
        if CommandLine.arguments.count >= 3 {
            struct Observation: Decodable {
                let target: String
                let targetMD5: String?
                let backupMD5: String?
                let stageMD5: String?
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let state = TumoflipInstaller.decodeStateSlot(data), let journal = state.txn else {
                throw MemoryFS.Failure.injected
            }
            let rows = try JSONDecoder().decode([Observation].self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            guard rows.count == journal.ops.count else { throw MemoryFS.Failure.injected }
            let fs = MemoryFS()
            fs.slots[TumoflipInstaller.stateSlotA] = data
            for op in journal.ops {
                guard let row = rows.first(where: { $0.target == op.target }) else { throw MemoryFS.Failure.injected }
                fs.hashes[op.target] = row.targetMD5
                fs.hashes[op.backup] = row.backupMD5
                fs.hashes[op.stage] = row.stageMD5
            }
            let before = fs.hashes
            do { try await TumoflipInstaller(fs: fs, source: NoSource()).recover() }
            catch { print("Forensic replay recovery threw:", error) }
            check(fs.state()?.txn == nil, "exact saved device snapshot completes without rollback")
            check(fs.hashes == before && fs.fileMutations.isEmpty, "exact snapshot recovery changes metadata only")
            if failures == 0, CommandLine.arguments.count == 4 {
                let writes = fs.writes.map { path -> [String: String] in
                    ["path": path, "base64": fs.slots[path]!.base64EncodedString()]
                }
                let encoded = try JSONSerialization.data(withJSONObject: writes, options: [.sortedKeys])
                try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .withoutOverwriting)
            }
        }
        print("Production recovery host failures:", failures)
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tumo-recovery-host-') as directory:
    work = Path(directory)
    swift = work / 'main.swift'
    binary = work / 'recovery-tests'
    swift.write_text(program)
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, cwd=ROOT, timeout=90)
    command = [str(binary)]
    if args.snapshot:
        command += [str(args.snapshot.resolve()), str(args.observations.resolve())]
        if args.emit_state:
            command += [str(args.emit_state.resolve())]
    raise SystemExit(subprocess.run(command, cwd=ROOT, timeout=30).returncode)
