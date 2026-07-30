import XCTest
@testable import UnleashedCompanion

@MainActor
final class TransferActivityReporterTests: XCTestCase {
    func testHeartbeatKeepsTransferActiveUntilEnd() async throws {
        var events: [String] = []
        let reporter = TransferActivityReporter(
            channel: .ble,
            heartbeatInterval: 0.02,
            reasonProvider: { nil },
            commandSender: { command, _ in events.append(command) }
        )

        reporter.begin("firmware packages")
        try await Task.sleep(nanoseconds: 75_000_000)
        reporter.end()

        XCTAssertEqual(events.first, "transfer_begin")
        XCTAssertGreaterThanOrEqual(
            events.filter { $0 == "transfer_progress" }.count,
            2
        )
        XCTAssertEqual(events.last, "transfer_end")

        let countAfterEnd = events.count
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(events.count, countAfterEnd)
    }

    func testUnavailableTransportDoesNotSendEvents() async throws {
        var events: [String] = []
        let reporter = TransferActivityReporter(
            channel: .ble,
            heartbeatInterval: 0.01,
            reasonProvider: { "not ready" },
            commandSender: { command, _ in events.append(command) }
        )

        reporter.begin("firmware packages")
        try await Task.sleep(nanoseconds: 35_000_000)
        reporter.end()

        XCTAssertTrue(events.isEmpty)
    }
}
