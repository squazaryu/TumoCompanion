#if DEBUG
import Foundation

enum ProductPreviewFixtures {
    static var waveformA: SignalWaveform {
        let pulses = Array(repeating: "320 -640 320 -320 640 -320", count: 8).joined(separator: " ")
        return try! SignalWaveform.parse(Data("Filetype: Flipper SubGhz RAW File\nFrequency: 433920000\nPreset: AM650\nRAW_Data: \(pulses)".utf8))
    }
    static var waveformB: SignalWaveform {
        let pulses = Array(repeating: "330 -630 330 -330 630 -330", count: 8).joined(separator: " ")
        return try! SignalWaveform.parse(Data("Filetype: Flipper SubGhz RAW File\nFrequency: 433920000\nPreset: AM650\nRAW_Data: \(pulses)".utf8))
    }
    static var remoteID: RemoteIDReport {
        try! RemoteIDReport.parse(Data("RID,12000,OWN-DRONE-01,,5,6,-57,48,3.5,active,0,0,0,0,55.7500000,37.6100000,120.0,1,10.0,1,2.4,1,90,1,0,0,0,0,0,0,0\n".utf8))
    }
}
#endif
