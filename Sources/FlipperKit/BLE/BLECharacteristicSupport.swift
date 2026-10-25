import CoreBluetooth

enum BLECharacteristicSupport {
    /// CoreBluetooth's setNotifyValue/isNotifying cover both delivery modes.
    /// Flipper serial TX uses INDICATE; flow control uses NOTIFY.
    static func supportsValueUpdates(_ properties: CBCharacteristicProperties) -> Bool {
        !properties.intersection([.notify, .indicate]).isEmpty
    }
}
