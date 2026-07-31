import Combine
import CoreLocation
import Foundation
import Security

enum FieldLocationReason: String, Codable, CaseIterable {
    case explicitRequest = "request"
    case survey
    case sidecar
    case connection
    case disconnection
    case service
    case journal

    var label: String {
        switch self {
        case .explicitRequest: return "Flipper request"
        case .survey: return "TumoSurvey"
        case .sidecar: return "File sidecar"
        case .connection: return "BLE connected"
        case .disconnection: return "BLE disconnected"
        case .service: return "Named service"
        case .journal: return "Field journal"
        }
    }
}

struct FieldLocationSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let accuracy: Double
    let timestamp: Date
    let reason: FieldLocationReason
    let deviceName: String

    init(
        id: UUID = UUID(),
        location: CLLocation,
        reason: FieldLocationReason,
        deviceName: String
    ) {
        self.id = id
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        accuracy = location.horizontalAccuracy
        timestamp = location.timestamp
        self.reason = reason
        self.deviceName = String(deviceName.prefix(48))
    }

    var coordinateText: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

enum FieldJournalDelivery: String, Codable, Equatable {
    case local
    case sent
    case failed

    var label: String {
        switch self {
        case .local: return "Saved locally"
        case .sent: return "Webhook sent"
        case .failed: return "Webhook failed"
        }
    }
}

struct FieldJournalEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: String
    let note: String
    let createdAt: Date
    let location: FieldLocationSnapshot
    var delivery: FieldJournalDelivery
}

struct FieldWebhookConfiguration: Equatable {
    let url: URL
    let bearerToken: String?
}

protocol FieldSecretStoring: AnyObject {
    func read(account: String) -> String?
    func write(_ value: String?, account: String) throws
}

final class KeychainFieldSecretStore: FieldSecretStoring {
    private let service = "com.tumoflip.unleashedcompanion.field-services"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

@MainActor
final class FieldServicesStore: ObservableObject {
    static let shared = FieldServicesStore()

    @Published var rememberLastLocation: Bool {
        didSet { defaults.set(rememberLastLocation, forKey: Keys.rememberLocation) }
    }
    @Published var journalEnabled: Bool {
        didSet { defaults.set(journalEnabled, forKey: Keys.journalEnabled) }
    }
    @Published var webhookEnabled: Bool {
        didSet { defaults.set(webhookEnabled, forKey: Keys.webhookEnabled) }
    }
    @Published var webhookURL: String {
        didSet { defaults.set(webhookURL, forKey: Keys.webhookURL) }
    }
    @Published private(set) var lastLocation: FieldLocationSnapshot?
    @Published private(set) var journalEntries: [FieldJournalEntry]

    private enum Keys {
        static let rememberLocation = "fieldServices.rememberLocation.v1"
        static let journalEnabled = "fieldServices.journalEnabled.v1"
        static let webhookEnabled = "fieldServices.webhookEnabled.v1"
        static let webhookURL = "fieldServices.webhookURL.v1"
        static let lastLocation = "fieldServices.lastLocation.v1"
        static let journal = "fieldServices.journal.v1"
        static let webhookToken = "fieldServices.webhookToken.v1"
    }

    private let defaults: UserDefaults
    private let secrets: FieldSecretStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let journalLimit = 200

    init(
        defaults: UserDefaults = .standard,
        secrets: FieldSecretStoring = KeychainFieldSecretStore()
    ) {
        let decoder = JSONDecoder()
        self.defaults = defaults
        self.secrets = secrets
        rememberLastLocation = defaults.bool(forKey: Keys.rememberLocation)
        journalEnabled = defaults.bool(forKey: Keys.journalEnabled)
        webhookEnabled = defaults.bool(forKey: Keys.webhookEnabled)
        webhookURL = defaults.string(forKey: Keys.webhookURL) ?? ""
        lastLocation = defaults.data(forKey: Keys.lastLocation)
            .flatMap { try? decoder.decode(FieldLocationSnapshot.self, from: $0) }
        journalEntries = defaults.data(forKey: Keys.journal)
            .flatMap { try? decoder.decode([FieldJournalEntry].self, from: $0) } ?? []
    }

    var hasWebhookToken: Bool {
        !(secrets.read(account: Keys.webhookToken) ?? "").isEmpty
    }

    func saveWebhookToken(_ value: String) throws {
        guard !value.contains("\r"), !value.contains("\n") else {
            throw DeviceServiceError.invalidPayload
        }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count <= 512 else {
            throw DeviceServiceError.invalidPayload
        }
        try secrets.write(token, account: Keys.webhookToken)
        objectWillChange.send()
    }

    func webhookConfiguration() throws -> FieldWebhookConfiguration {
        guard webhookEnabled else { throw DeviceServiceError.disabled }
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw DeviceServiceError.invalidURL }
        try WebhookURLPolicy.validate(url)
        let token = secrets.read(account: Keys.webhookToken)
        return FieldWebhookConfiguration(
            url: url,
            bearerToken: token?.isEmpty == false ? token : nil
        )
    }

    func record(_ location: CLLocation, reason: FieldLocationReason, deviceName: String) {
        guard rememberLastLocation else { return }
        let snapshot = FieldLocationSnapshot(
            location: location,
            reason: reason,
            deviceName: deviceName
        )
        lastLocation = snapshot
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: Keys.lastLocation)
        }
    }

    func clearLastLocation() {
        lastLocation = nil
        defaults.removeObject(forKey: Keys.lastLocation)
    }

    @discardableResult
    func appendJournal(
        kind: String,
        note: String,
        location: CLLocation,
        deviceName: String
    ) throws -> FieldJournalEntry {
        guard journalEnabled else { throw DeviceServiceError.disabled }
        let safeKind = Self.safeText(kind, maximum: 24, fallback: "field")
        let safeNote = Self.safeText(note, maximum: 96, fallback: "Field event")
        let snapshot = FieldLocationSnapshot(
            location: location,
            reason: .journal,
            deviceName: deviceName
        )
        let entry = FieldJournalEntry(
            id: UUID(),
            kind: safeKind,
            note: safeNote,
            createdAt: Date(),
            location: snapshot,
            delivery: .local
        )
        journalEntries.insert(entry, at: 0)
        if journalEntries.count > journalLimit {
            journalEntries.removeLast(journalEntries.count - journalLimit)
        }
        persistJournal()
        record(location, reason: .journal, deviceName: deviceName)
        return entry
    }

    func markDelivery(id: UUID, as delivery: FieldJournalDelivery) {
        guard let index = journalEntries.firstIndex(where: { $0.id == id }) else { return }
        journalEntries[index].delivery = delivery
        persistJournal()
    }

    func clearJournal() {
        journalEntries = []
        defaults.removeObject(forKey: Keys.journal)
    }

    private func persistJournal() {
        if let data = try? encoder.encode(journalEntries) {
            defaults.set(data, forKey: Keys.journal)
        }
    }

    private static func safeText(_ input: String, maximum: Int, fallback: String) -> String {
        let filtered = input.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20, scalar.value != 0x7F, scalar != ";", scalar != "=" {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(filtered)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String((normalized.isEmpty ? fallback : normalized).prefix(maximum))
    }
}
