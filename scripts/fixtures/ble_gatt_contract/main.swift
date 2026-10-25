import Foundation
import CoreBluetooth

// F7 serial service at tumoflip source4be8c28f981a9f1299b4164675872aaf21dec144:
// targets/f7/ble_glue/services/serial_service.c
// TX: CHAR_PROP_READ | CHAR_PROP_INDICATE
// Flow: CHAR_PROP_READ | CHAR_PROP_NOTIFY
// These are SDK property bits, not hand-set readiness booleans.
struct Characteristic { let properties: CBCharacteristicProperties }

func discoverTX(_ properties: CBCharacteristicProperties) -> Bool {
    let c = Characteristic(properties: properties)
    var readiness = BLESessionReadiness()
    // TX_DISCOVERY
    return readiness.hasSerialTX
}

func discoverFlow(_ properties: CBCharacteristicProperties) -> Bool {
    let c = Characteristic(properties: properties)
    var readiness = BLESessionReadiness()
    // FLOW_DISCOVERY
    return readiness.hasSerialFlow
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

check(discoverTX([.read, .indicate]), "Stock Flipper serial TX is INDICATE, not NOTIFY")
check(discoverFlow([.read, .notify]), "Stock Flipper flow control is NOTIFY")
for mask in 0..<256 {
    let properties = CBCharacteristicProperties(rawValue: UInt(mask))
    let expected = !properties.intersection([.notify, .indicate]).isEmpty
    check(discoverTX(properties) == expected, "TX update delivery property mask must support notify or indicate")
    check(discoverFlow(properties) == expected, "Flow update delivery property mask must support notify or indicate")
}
check(discoverTX([.read, .indicate, .indicateEncryptionRequired]), "Authenticated indications remain supported")
check(!discoverTX([.read, .writeWithoutResponse]), "A read/write-only characteristic cannot deliver updates")

var session = BLESessionReadiness()
session.hasSerialRX = true
session.hasSerialTX = discoverTX([.read, .indicate])
session.hasSerialFlow = discoverFlow([.read, .notify])
check(!session.takeSerialReady(), "Discovery still must not bypass subscription acknowledgement")
session.serialTXNotifying = true
check(!session.takeSerialReady(), "Flow acknowledgement is also required")
session.serialFlowNotifying = true
check(session.takeSerialReady(), "Real Flipper GATT contract must reach ready after acknowledgements")
print("Production GATT discovery contract: \(checks) checks passed")
