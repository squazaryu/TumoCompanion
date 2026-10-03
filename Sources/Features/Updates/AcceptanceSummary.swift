import Foundation

struct AcceptanceSummary {
    let passed: Int
    let failed: Int
    let manual: Int
    let text: String

    static func parse(_ data: Data, version: String, commit: String) throws -> AcceptanceSummary {
        guard data.count <= 128 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("Tumoflip Hardware Acceptance Suite\n") else {
            throw SignalAnalysisError.invalid("Invalid Acceptance Suite report.")
        }
        let lines = text.components(separatedBy: .newlines)
        func field(_ name: String) throws -> String {
            let prefix = "\(name): "
            let values = lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            guard values.count == 1 else { throw SignalAnalysisError.invalid("Missing/duplicate report identity.") }
            return values[0]
        }
        let schema = try field("Schema"), target = try field("Target")
        let reportedVersion = try field("Version"), reportedCommit = try field("Commit")
        guard schema == "1", target == "7",
              reportedVersion == version, reportedCommit == commit,
              commit.count >= 8, commit.allSatisfy(\.isHexDigit) else {
            throw SignalAnalysisError.invalid("Report is not from the currently connected firmware.")
        }
        let passed = lines.filter { $0.hasPrefix("[PASS] ") }.count
        let failed = lines.filter { $0.hasPrefix("[FAIL] ") }.count
        let manual = lines.filter { $0.hasPrefix("[SKIP] ") || $0.hasPrefix("[PENDING] ") || $0.hasPrefix("[MANUAL] ") }.count
        guard passed + failed + manual > 0 else { throw SignalAnalysisError.invalid("Report has no check results.") }
        return .init(passed: passed, failed: failed, manual: manual, text: text)
    }
}
