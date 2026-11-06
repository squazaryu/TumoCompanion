import Foundation

/// Narrow recovery for a completed installation whose old journal survived.
/// This is not permission to adopt files, skip rollback, or trust mere presence.
/// Every recorded install identity and every explicit device observation must agree.
enum TumoflipRecoveryFinalization {
    enum Observation: Equatable {
        case missing
        case md5(String)
    }

    static func isCandidate(_ state: TumoflipState) -> Bool {
        guard state.generation < UInt64.max,
              let journal = state.txn, journal.phase == .activating,
              !journal.ops.isEmpty, journal.cleanups.isEmpty,
              !journal.groups.isEmpty,
              validHash(journal.releaseId, count: 64),
              validHash(journal.fingerprint, count: 64) else { return false }
        var targets = Set<String>()
        for op in journal.ops {
            let path = op.target
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard op.state == .activated || op.state == .unchanged,
                  path.hasPrefix("/ext/apps/") || path.hasPrefix("/ext/apps_data/"),
                  path.hasSuffix(".fap") || path.hasSuffix(".fal"),
                  !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }),
                  targets.insert(path.lowercased()).inserted,
                  validHash(op.md5, count: 32), validHash(op.sha256, count: 64),
                  op.stage == path + ".ucnew",
                  op.backup == "/ext/.tumoflip/rollback/" + journal.fingerprint.prefix(16)
                    + "/" + TumoflipHash.sha256(Data(path.utf8)),
                  let installed = state.ledger[path],
                  installed.md5 == op.md5, installed.sha256 == op.sha256,
                  installed.releaseId == journal.releaseId else { return false }
        }
        return true
    }

    static func canFinalize(
        _ state: TumoflipState,
        observations: [String: Observation]
    ) -> Bool {
        guard isCandidate(state), let journal = state.txn else { return false }
        return journal.ops.allSatisfy { op in
            observations[op.target] == .md5(op.md5)
                && observations[op.backup] == .missing
                && observations[op.stage] == .missing
        }
    }

    private static func validHash(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
