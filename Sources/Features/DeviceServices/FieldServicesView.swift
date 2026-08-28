import SwiftUI

struct FieldServicesView: View {
    @EnvironmentObject private var deviceServices: DeviceServiceCoordinator
    @EnvironmentObject private var fieldServices: FieldServicesStore
    @State private var webhookToken = ""
    @State private var tokenStatus: String?

    var body: some View {
        CardScroll {
            availabilityCard
            locationCard
            namedServicesCard
            journalCard
            webhookCard
            privacyCard
        }
        .navigationTitle("Field Services")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var availabilityCard: some View {
        SectionCard(title: "Bridge", systemImage: "iphone.and.arrow.forward") {
            HStack {
                serviceState("Location", state: deviceServices.locationState)
                Spacer()
                serviceState("Network", state: deviceServices.networkState)
            }
            Text("Open Flipper Companion on the Flipper to request Weather, Place, Release, file sidecars, or a journal entry. TumoSurvey requests one fix automatically when a survey starts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let result = deviceServices.lastResult {
                Divider().opacity(0.35)
                Text(result)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let error = deviceServices.lastError {
                Text("Last error: \(error)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityIdentifier("field-services-bridge")
    }

    private var locationCard: some View {
        SectionCard(title: "Last known location", systemImage: "location.fill") {
            Toggle("Remember one last location", isOn: $fieldServices.rememberLastLocation)
                .tint(Theme.accent)
                .accessibilityIdentifier("field-services-remember-location")
            Text("Updates on BLE connect/disconnect and successful Flipper requests. Only one record is kept on this iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let location = fieldServices.lastLocation {
                Divider().opacity(0.35)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.coordinateText)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                        Text("±\(Int(location.accuracy.rounded())) m · \(location.reason.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(location.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = mapsURL(location) {
                        Link(destination: url) {
                            Image(systemName: "map.fill")
                                .font(.title3)
                        }
                        .accessibilityLabel("Open last location in Maps")
                    }
                }
                Button(role: .destructive) {
                    fieldServices.clearLastLocation()
                } label: {
                    Label("Clear location", systemImage: "trash")
                }
                .font(.caption)
            } else {
                Text(fieldServices.rememberLastLocation
                     ? "No location has been recorded yet."
                     : "History is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var namedServicesCard: some View {
        SectionCard(title: "Named services", systemImage: "network") {
            namedRow("Weather", icon: "cloud.sun", detail: "Open-Meteo current conditions")
            Divider().opacity(0.35)
            namedRow("Place", icon: "mappin.and.ellipse", detail: "BigDataCloud reverse geocoding")
            Divider().opacity(0.35)
            namedRow("Release", icon: "shippingbox", detail: "Latest Tumoflip stable on GitHub")
            Text("The Flipper chooses only the service name. Hosts, paths, query fields, timeouts, and response limits are fixed inside TumoCompanion.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var journalCard: some View {
        SectionCard(title: "Field journal", systemImage: "book.closed") {
            Toggle("Store journal entries", isOn: $fieldServices.journalEnabled)
                .tint(Theme.accent)
                .accessibilityIdentifier("field-services-journal")
            Text("Entries are created only after an explicit Journal action on the Flipper. Up to 200 entries stay locally on this iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !fieldServices.journalEntries.isEmpty {
                Divider().opacity(0.35)
                ForEach(fieldServices.journalEntries.prefix(8)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.kind.capitalized).font(.caption).fontWeight(.semibold)
                            Spacer()
                            Text(entry.delivery.label)
                                .font(.caption2)
                                .foregroundStyle(entry.delivery == .failed ? Theme.accent : .secondary)
                        }
                        Text(entry.note).font(.caption).lineLimit(2)
                        Text("\(entry.location.coordinateText) · \(entry.createdAt.formatted(date: .numeric, time: .shortened))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.25)
                }
                Button(role: .destructive) {
                    fieldServices.clearJournal()
                } label: {
                    Label("Clear journal", systemImage: "trash")
                }
                .font(.caption)
            }
        }
    }

    private var webhookCard: some View {
        SectionCard(title: "Optional webhook", systemImage: "paperplane") {
            Toggle("Send new journal entries", isOn: $fieldServices.webhookEnabled)
                .tint(Theme.accent)
                .accessibilityIdentifier("field-services-webhook")

            TextField("https://example.com/tumoflip", text: $fieldServices.webhookURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .accessibilityIdentifier("field-services-webhook-url")

            SecureField(fieldServices.hasWebhookToken ? "Token stored — enter to replace" : "Optional bearer token",
                        text: $webhookToken)
                .textContentType(.password)
                .accessibilityIdentifier("field-services-webhook-token")

            HStack {
                Button("Save token") {
                    do {
                        try fieldServices.saveWebhookToken(webhookToken)
                        webhookToken = ""
                        tokenStatus = fieldServices.hasWebhookToken ? "Stored in Keychain" : "Removed"
                    } catch {
                        tokenStatus = "Keychain error"
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                if let tokenStatus {
                    Text(tokenStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("HTTPS only. Local/private hosts, redirects, URL credentials, query strings, and oversized bodies are rejected. The token stays in the iOS Keychain and is never sent to the Flipper.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyCard: some View {
        SectionCard(title: "Privacy", systemImage: "hand.raised.fill") {
            Label("All Field Services options are off by default.", systemImage: "checkmark.shield")
            Label("Location providers receive coordinates only for the action you run.", systemImage: "location.slash")
            Label("Source captures are never uploaded or modified by sidecar tagging.", systemImage: "doc.badge.checkmark")
        }
        .font(.caption)
    }

    private func serviceState(_ title: String, state: DeviceServiceState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            StatusPill(text: state.label, color: stateColor(state))
        }
    }

    private func stateColor(_ state: DeviceServiceState) -> Color {
        switch state {
        case .available: return Theme.success
        case .inUse: return Theme.info
        case .denied, .foregroundOnly: return Theme.accent
        default: return .secondary
        }
    }

    private func namedRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func mapsURL(_ location: FieldLocationSnapshot) -> URL? {
        URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)")
    }
}
