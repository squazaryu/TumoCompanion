import CryptoKit
import Foundation

enum SignalAnalysisError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

struct SignalWaveform: Sendable {
    struct Pulse: Sendable {
        let startUs: Int64
        let durationUs: Int64
        let high: Bool
        var endUs: Int64 { startUs + durationUs }
    }
    struct Statistics {
        let count: Int
        let minUs: Int64
        let maxUs: Int64
        let meanUs: Double
    }

    let pulses: [Pulse]
    let durationUs: Int64
    let frequencyHz: UInt64?
    let preset: String?
    let sha256: String
    static let maxBytes = 4 * 1024 * 1024
    static let maxPulses = 500_000

    static func parse(_ data: Data) throws -> SignalWaveform {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw SignalAnalysisError.invalid("Capture exceeds 4 MiB or is not UTF-8.")
        }
        var filetype: String?, frequency: UInt64?, preset: String?
        var pulses: [Pulse] = [], end: Int64 = 0
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "Filetype":
                guard filetype == nil else { throw SignalAnalysisError.invalid("Duplicate capture header.") }
                filetype = value
            case "Frequency":
                guard frequency == nil, let f = UInt64(value), f <= 1_000_000_000 else {
                    throw SignalAnalysisError.invalid("Invalid capture frequency.")
                }
                frequency = f
            case "Preset": preset = value
            case "Version":
                guard value == "1" else { throw SignalAnalysisError.invalid("Unsupported RAW version.") }
            case "RAW_Data":
                for token in value.split(whereSeparator: { $0.isWhitespace }) {
                    guard pulses.count < maxPulses, let n = Int64(token), n != 0,
                          n.magnitude <= 1_000_000_000 else {
                        throw SignalAnalysisError.invalid("Invalid pulse or capture exceeds 500,000 pulses.")
                    }
                    let duration = Int64(n.magnitude)
                    guard end <= Int64.max - duration else {
                        throw SignalAnalysisError.invalid("Capture duration overflow.")
                    }
                    pulses.append(.init(startUs: end, durationUs: duration, high: n > 0))
                    end += duration
                }
            default: break
            }
        }
        guard filetype == "Flipper SubGhz RAW File", !pulses.isEmpty else {
            throw SignalAnalysisError.invalid("Choose a Sub-GHz RAW recording, not a decoded key file.")
        }
        return .init(pulses: pulses, durationUs: end, frequencyHz: frequency, preset: preset,
                     sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func indices(in range: Range<Int64>) -> Range<Int> {
        guard !range.isEmpty else { return 0..<0 }
        var low = 0, high = pulses.count
        while low < high {
            let mid = low + (high - low) / 2
            if pulses[mid].endUs <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = pulses.count
        while low < high {
            let mid = low + (high - low) / 2
            if pulses[mid].startUs < range.upperBound { low = mid + 1 } else { high = mid }
        }
        return start..<low
    }

    /// Draw at most 2,000 intervals; statistics always use the original pulses.
    func visible(in range: Range<Int64>, limit: Int = 2000) -> [Pulse] {
        guard limit > 0 else { return [] }
        let indexes = indices(in: range)
        let step = max(1, (indexes.count + limit - 1) / limit)
        return stride(from: indexes.lowerBound, to: indexes.upperBound, by: step).map { pulses[$0] }
    }

    func statistics(in range: Range<Int64>) -> Statistics {
        let indexes = indices(in: range)
        guard !indexes.isEmpty else { return .init(count: 0, minUs: 0, maxUs: 0, meanUs: 0) }
        var minimum = Int64.max, maximum: Int64 = 0, total: Double = 0
        for i in indexes {
            let duration = pulses[i].durationUs
            minimum = min(minimum, duration); maximum = max(maximum, duration)
            total += Double(duration)
        }
        return .init(count: indexes.count, minUs: minimum, maxUs: maximum,
                     meanUs: total / Double(indexes.count))
    }
}

struct SignalAnnotation: Codable {
    let schema: Int
    let source: String
    let sourceSHA256: String
    let startUs: Int64
    let endUs: Int64
    let text: String
    let createdAt: Date

    static func create(source: String, waveform: SignalWaveform, range: Range<Int64>,
                       text: String) throws -> SignalAnnotation {
        guard source.hasPrefix("/ext/subghz/"), source.hasSuffix(".sub"),
              !source.split(separator: "/").contains(".."), !range.isEmpty,
              range.lowerBound >= 0, range.upperBound <= waveform.durationUs,
              text.utf8.count <= 2048 else {
            throw SignalAnalysisError.invalid("Invalid annotation path, range or note.")
        }
        return .init(schema: 1, source: source, sourceSHA256: waveform.sha256,
                     startUs: range.lowerBound, endUs: range.upperBound,
                     text: text, createdAt: Date())
    }
}
