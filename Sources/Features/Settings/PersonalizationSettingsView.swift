import SwiftUI
import UIKit

struct PersonalizationSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var iconError: String?

    var body: some View {
        CardScroll {
            SectionCard(title: "Dolphin", systemImage: "photo.on.rectangle.angled") {
                NavigationLink { DolphinGalleryView() } label: {
                    Label("Dolphin Gallery", systemImage: "rectangle.stack")
                }
            }

            SectionCard(title: "Appearance", systemImage: "paintbrush") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if UIApplication.shared.supportsAlternateIcons {
                SectionCard(title: "App icon", systemImage: "app.badge") {
                    ForEach(AppIconOption.allCases) { option in
                        Button { setIcon(option) } label: {
                            HStack(spacing: 12) {
                                iconPreview(option)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if option == .purple || option == .mono {
                                        Text("Keeps alpha for iOS Clear mode")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                if currentIcon == option.alternateName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if option != AppIconOption.allCases.last { Divider().opacity(0.4) }
                    }
                    Text("iOS controls the final Light, Dark, Tinted and Clear appearance from the Home Screen. TumoCompanion ships alpha-safe Clear assets; changing the app icon here only selects the source asset.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let iconError {
                        Text(iconError)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func iconPreview(_ option: AppIconOption) -> some View {
        if let image = UIImage(named: option.assetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.18)))
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(option.swatch)
                .frame(width: 46, height: 46)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.18)))
        }
    }

    private func setIcon(_ option: AppIconOption) {
        guard currentIcon != option.alternateName else { return }
        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            DispatchQueue.main.async {
                if let error {
                    iconError = error.localizedDescription
                } else {
                    iconError = nil
                    currentIcon = option.alternateName
                }
            }
        }
    }
}
