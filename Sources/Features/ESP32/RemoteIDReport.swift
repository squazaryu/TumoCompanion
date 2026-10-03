import CryptoKit
import Foundation

/// UART `RID,` layout from Marauder 9afe7d117. No operator location/identity is retained.
struct RemoteIDReport: Sendable {
    struct Record: Identifiable, Sendable {
        let uasID: String
        let uptimeMs: UInt32
        let transports: UInt8
        let channel: UInt8
        let rssi: Int
        let packets: UInt64
        let rateHz: Double
        let lost: Bool
        let latitude: Double?
        let longitude: Double?
        let altitudeM: Double?
        let speedMps: Double?
        var id: String { uasID }
    }
    let records: [Record]
    let sha256: String
    let observations: Int

    static func parse(_ data: Data) throws -> RemoteIDReport {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw SignalAnalysisError.invalid("Remote ID log exceeds 2 MiB or is not UTF-8.")
        }
        var records: [String: Record] = [:], observations = 0
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("RID,") else { continue }
            let values = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard values.count == 31, observations < 10_000,
                  let uptime = UInt32(values[1]), !values[2].isEmpty, values[2].utf8.count <= 20,
                  values[2].unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
                  let transports = UInt8(values[4]), (1...15).contains(transports),
                  let channel = UInt8(values[5]), let rssi = Int(values[6]), (-127...20).contains(rssi),
                  let packets = UInt64(values[7]), let rate = Double(values[8]), rate.isFinite, rate >= 0,
                  ["active", "lost"].contains(values[9]),
                  let latitude = Double(values[14]), latitude.isFinite, (-90...90).contains(latitude),
                  let longitude = Double(values[15]), longitude.isFinite, (-180...180).contains(longitude),
                  ["0", "1"].contains(values[17]), ["0", "1"].contains(values[21]),
                  let altitude = Double(values[16]), altitude.isFinite, abs(altitude) <= 100_000,
                  let speed = Double(values[20]), speed.isFinite, (0...1000).contains(speed) else {
                throw SignalAnalysisError.invalid("Malformed/unsupported RID row. Stop the scan before reading its log.")
            }
            // This UART schema has no location-valid flag. Zero/zero is ambiguous,
            // so never turn its default coordinates into a real location.
            let hasLocation = latitude != 0 || longitude != 0
            let record = Record(uasID: values[2], uptimeMs: uptime, transports: transports,
                                channel: channel, rssi: rssi, packets: packets, rateHz: rate,
                                lost: values[9] == "lost", latitude: hasLocation ? latitude : nil,
                                longitude: hasLocation ? longitude : nil,
                                altitudeM: values[17] == "1" ? altitude : nil,
                                speedMps: values[21] == "1" ? speed : nil)
            records[record.uasID] = record
            guard records.count <= 64 else { throw SignalAnalysisError.invalid("Log exceeds 64 Remote ID devices.") }
            observations += 1
        }
        guard !records.isEmpty else {
            throw SignalAnalysisError.invalid("No RID telemetry. This needs Marauder with Remote ID support, not 1.17.0.")
        }
        return .init(records: records.values.sorted { $0.uasID < $1.uasID },
                     sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     observations: observations)
    }
}
