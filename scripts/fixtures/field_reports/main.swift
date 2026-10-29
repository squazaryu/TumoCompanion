import Foundation

func document(_ kind: FieldReportKind, _ rows: String) throws -> FieldReportDocument {
    try FieldReportDocument.parse(Data((kind.header.joined(separator: ",") + "\n" + rows).utf8), kind: kind)
}
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("Accepted invalid field report") } catch {}
}
let power = try document(.power, "123,85,4070,-32,251,90000,0,0,98\n124,84,4060,-41,255,89000,0,0,98\n")
precondition(power.rows.count == 2 && power.series(column: "soc").first?.value == 85)
precondition(power.series(column: "temp_tenths").first?.value == 25.1)
let sensor = try document(.sensors, "object:Garage,Nexus-TH,123,1,433920000,123,-198,56,0,4\nobject:Garage,Nexus-TH,123,1,433920000,124,,57,,5\n")
precondition(sensor.objects == ["Garage"] && sensor.series(column: "temp_tenths").count == 1)
precondition(sensor.series(column: "temp_tenths").first?.value == -19.8)
let uhf = try document(.uhf, "E2000017221101441890ABCD,12288,1,4,123,128,98,45\n")
precondition(uhf.rows.count == 1)
precondition(FieldReportKind.uhf.header.joined(separator: ",") == "epc,pc,antenna,hits,first,last,signal_raw,frequency_raw")
let varta = try document(.varta, "live,123456789A,32,1,0,0,0,0\n")
precondition(varta.rows.count == 1 && varta.objects.isEmpty)
for kind in FieldReportKind.allCases {
    precondition(kind.accepts(name: "\(kind.rawValue)_123_0.csv"))
    precondition(!kind.accepts(name: "../\(kind.rawValue)_123_0.csv"))
    precondition(!kind.accepts(name: "\(kind.rawValue)_123_32.csv"))
    precondition(!kind.accepts(name: "\(kind.rawValue)_999999999999999_0.csv"))
    rejects { _ = try document(kind, "") }
    rejects { _ = try FieldReportDocument.parse(Data(repeating: 65, count: 65537), kind: kind) }
    rejects { _ = try FieldReportDocument.parse(Data([0xff]), kind: kind) }
}
rejects { _ = try document(.power, "123,101,4000,20,250,90000,0,0,99\n") }
rejects { _ = try document(.power, "123,50,NaN,20,250,90000,0,0,99\n") }
rejects { _ = try document(.power, "123,50,4000,20,250,90000,2,0,99\n") }
rejects { _ = try document(.power, "123,50,4000,20,250,90000,0,0,99,extra\n") }
rejects { _ = try document(.sensors, "object:../x,Nexus-TH,1,1,433920000,123,200,50,0,1\n") }
rejects { _ = try document(.sensors, "object:Home,=FORMULA(),1,1,433920000,123,200,50,0,1\n") }
rejects { _ = try document(.uhf, "E200,12288,1,1,10,20,98,45\n") }
rejects { _ = try document(.uhf, "ZZZZ,2048,1,1,10,20,98,45\n") }
rejects { _ = try document(.varta, "live,123456789A,32,1,0,1,0,0\n") }
rejects { _ = try FieldReportDocument.parse(Data("wrong\n1\n".utf8), kind: .power) }
let crlf = try document(.power, "123,50,4000,20,250,90000,0,0,99\r\n")
precondition(crlf.rows.count == 1)
print("Field reports: schema, paths, bounds, missing values and unit conversion verified")
