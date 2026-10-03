import XCTest
@testable import UnleashedCompanion

final class RemoteIDTests: XCTestCase {
    private let row = "RID,1000,OWN-DRONE,,5,6,-50,10,2.5,active,0,0,0,0,55.7500000,37.6100000,120.0,1,10.0,1,3.0,1,90,1,0,0,0,0,0,0,0"
    func testParsesPublishedMarauderUARTLayout() throws {
        let report = try RemoteIDReport.parse(Data(("Remote ID scan\n" + row + "\n").utf8))
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records[0].uasID, "OWN-DRONE")
        XCTAssertEqual(report.records[0].rssi, -50)
        XCTAssertEqual(report.records[0].altitudeM, 120)
        XCTAssertEqual(report.records[0].latitude, 55.75)
        XCTAssertEqual(report.sha256.count, 64)
    }
    func testMalformedRowCannotBecomeSuccessfulReport() {
        XCTAssertThrowsError(try RemoteIDReport.parse(Data("RID,short\n".utf8)))
        XCTAssertThrowsError(try RemoteIDReport.parse(Data(row.replacingOccurrences(of: "55.7500000", with: "nan").utf8)))
        XCTAssertThrowsError(try RemoteIDReport.parse(Data("Unknown command: remoteid\n".utf8)))
    }
    func testMissingAltitudeFlagIsNotZeroAltitude() throws {
        let text = row.replacingOccurrences(of: "120.0,1", with: "0,0")
        XCTAssertNil(try RemoteIDReport.parse(Data(text.utf8)).records[0].altitudeM)
    }
}
