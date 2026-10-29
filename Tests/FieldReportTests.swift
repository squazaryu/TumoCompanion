import XCTest
@testable import UnleashedCompanion

final class FieldReportTests: XCTestCase {
    func testProductionHeadersAndMissingSensorValues() throws {
        let data = Data("object,protocol,id,channel,frequency_hz,timestamp,temp_tenths,humidity,battery_low,frames\nobject:Garage,Nexus-TH,123,1,433920000,123,,56,,4\n".utf8)
        let doc = try FieldReportDocument.parse(data, kind: .sensors)
        XCTAssertEqual(doc.objects, ["Garage"])
        XCTAssertTrue(doc.series(column: "temp_tenths").isEmpty)
        XCTAssertEqual(doc.series(column: "humidity").first?.value, 56)
    }
    func testTraversalAndOversizedReportsAreRejected() {
        XCTAssertFalse(FieldReportKind.power.accepts(name: "../power_123_0.csv"))
        XCTAssertThrowsError(try FieldReportDocument.parse(Data(repeating: 65, count: 65537), kind: .power))
    }
    func testNoFakeUhfUnitsOrUnobservedMarkerMatches() {
        XCTAssertThrowsError(try FieldReportDocument.parse(Data((FieldReportKind.varta.header.joined(separator: ",") + "\nlive,123456789A,32,1,0,1,0,0\n").utf8), kind: .varta))
        XCTAssertEqual(FieldReportKind.uhf.header[4], "first")
        XCTAssertEqual(FieldReportKind.uhf.header[6], "signal_raw")
    }
}
