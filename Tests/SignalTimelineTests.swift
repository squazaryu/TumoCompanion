import XCTest
@testable import UnleashedCompanion

final class SignalTimelineTests: XCTestCase {
    func testRawRowsPreserveLevelsAndTimeline() throws {
        let waveform = try SignalWaveform.parse(Data("Filetype: Flipper SubGhz RAW File\nVersion: 1\nFrequency: 433920000\nPreset: FuriHalSubGhzPresetOok650Async\nRAW_Data: 100 -200\nRAW_Data: 300 -400\n".utf8))
        XCTAssertEqual(waveform.pulses.map(\.high), [true, false, true, false])
        XCTAssertEqual(waveform.pulses.map(\.startUs), [0, 100, 300, 600])
        XCTAssertEqual(waveform.durationUs, 1000)
        XCTAssertEqual(waveform.frequencyHz, 433920000)
        XCTAssertEqual(waveform.statistics(in: 100..<600).count, 2)
        XCTAssertEqual(waveform.visible(in: 300..<600).count, 1)
        XCTAssertEqual(waveform.sha256.count, 64)
    }

    func testMalformedAndUnsupportedFilesFailClosed() {
        for text in ["RAW_Data: 1 0", "RAW_Data: -9223372036854775808", "RAW_Data: 1 nope", "Protocol: RAW\nKey: 12", "Filetype: Flipper SubGhz Key File\nRAW_Data: 1 -2"] {
            XCTAssertThrowsError(try SignalWaveform.parse(Data(text.utf8)))
        }
        XCTAssertThrowsError(try SignalWaveform.parse(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)))
    }

    func testAnnotationBindsSourceHashesAndRange() throws {
        let waveform = try SignalWaveform.parse(Data("Filetype: Flipper SubGhz RAW File\nRAW_Data: 100 -200".utf8))
        let note = try SignalAnnotation.create(source: "/ext/subghz/own.sub", waveform: waveform,
                                                range: 0..<100, text: "first pulse")
        XCTAssertEqual(note.sourceSHA256, waveform.sha256)
        XCTAssertEqual(note.startUs, 0)
        XCTAssertThrowsError(try SignalAnnotation.create(source: "../outside", waveform: waveform,
                                                         range: 0..<100, text: ""))
        XCTAssertThrowsError(try SignalAnnotation.create(source: "/ext/subghz/own.sub", waveform: waveform,
                                                         range: 0..<301, text: ""))
    }
}
