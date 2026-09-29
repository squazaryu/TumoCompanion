import Foundation

struct ESP32FlashObservation: Codable, Equatable {
    enum Disposition: String, Codable {
        case manual
        case unverified
        case invalid
        case eligible
        case reviewRequired
    }

    let inventory: String
    let disposition: Disposition
    let planFingerprint: String?
}

enum ESP32FlashTransition {
    struct Decision: Equatable {
        let state: ESP32FlashObservation
        let notify: Bool
    }

    /// A new release is a silent baseline. Only a newly verified plan for a
    /// previously manual or invalid release can produce a notification.
    static func evaluate(
        previous: ESP32FlashObservation?,
        inventory: String,
        verifiedPlan: String?
    ) -> Decision {
        guard let previous else {
            return Decision(
                state: .init(
                    inventory: inventory,
                    disposition: inventory == "none" ? .manual : .unverified,
                    planFingerprint: nil),
                notify: false)
        }
        if previous.inventory == inventory {
            return Decision(state: previous, notify: false)
        }
        if previous.disposition == .eligible || previous.disposition == .unverified ||
            previous.disposition == .reviewRequired {
            return Decision(
                state: .init(inventory: inventory, disposition: .reviewRequired,
                             planFingerprint: previous.planFingerprint),
                notify: false)
        }
        guard inventory != "none" else {
            return Decision(
                state: .init(inventory: inventory, disposition: .manual, planFingerprint: nil),
                notify: false)
        }
        guard let verifiedPlan else {
            return Decision(
                state: .init(inventory: inventory, disposition: .invalid, planFingerprint: nil),
                notify: false)
        }
        return Decision(
            state: .init(inventory: inventory, disposition: .eligible,
                         planFingerprint: verifiedPlan),
            notify: previous.disposition == .manual || previous.disposition == .invalid)
    }
}
