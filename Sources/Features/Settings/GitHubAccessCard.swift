import SwiftUI
import UIKit

struct GitHubAccessCard: View {
    @ObservedObject var auth: GitHubAuthStore
    @Environment(\.openURL) private var openURL
    @State private var codeCopied = false

    var body: some View {
        SectionCard(title: "GitHub access", systemImage: "link.circle") {
            if let account = auth.account {
                connectedContent(account)
            } else if let authorization = auth.pendingAuthorization {
                authorizationContent(authorization)
            } else {
                disconnectedContent
            }

            if let error = auth.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("github-auth-error")
            }
        }
        .task { await auth.restoreSession() }
        .onReceive(NotificationCenter.default.publisher(for: .githubCredentialInvalidated)) { _ in
            auth.credentialWasInvalidated()
        }
    }

    private func connectedContent(_ account: GitHubAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("@\(account.login)", systemImage: "person.crop.circle.badge.checkmark")
                    .fontWeight(.medium)
                Spacer()
                StatusPill(text: "Connected", color: Theme.success, systemImage: "checkmark.circle.fill")
            }
            .accessibilityIdentifier("github-auth-connected")

            if let rate = auth.rateLimit {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(rate.remaining.formatted()) of \(rate.limit.formatted()) GitHub requests left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Resets at \(rate.resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("github-auth-rate-limit")
            }

            Text("Firmware, FW Packages, Community apps and ESP32 catalogs now share your authenticated GitHub allowance. TumoCompanion requests no repository permissions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await auth.restoreSession(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(auth.isWorking)

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func authorizationContent(_ authorization: GitHubDeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ONE-TIME CODE")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(authorization.userCode)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("github-auth-user-code")
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = authorization.userCode
                    codeCopied = true
                } label: {
                    Label(codeCopied ? "Copied" : "Copy", systemImage: codeCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Text("Open GitHub, enter this code and approve TumoCompanion. The code expires at \(authorization.expiresAt.formatted(date: .omitted, time: .shortened)).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PillButton(title: "Open GitHub", systemImage: "safari") {
                UIPasteboard.general.string = authorization.userCode
                codeCopied = true
                openURL(authorization.verificationURL)
            }
            .accessibilityIdentifier("github-auth-open")

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for GitHub approval…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { auth.cancelSignIn() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(
                    auth.hasStoredCredential ? "Checking stored account" : "Anonymous GitHub access",
                    systemImage: auth.hasStoredCredential ? "person.crop.circle.badge.clock" : "person.crop.circle"
                )
                Spacer()
                StatusPill(
                    text: auth.hasStoredCredential ? "Checking" : "60 / hour",
                    color: auth.hasStoredCredential ? Theme.accent : .secondary
                )
            }

            Text("Anonymous GitHub requests share a 60-per-hour IP limit. Connecting your account raises the personal allowance to 5,000 per hour and prevents catalog lockouts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if auth.isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Contacting GitHub…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                PillButton(title: "Sign in with GitHub", systemImage: "person.badge.key") {
                    Task { await auth.startSignIn() }
                }
                .disabled(!auth.isConfigured)
                .accessibilityIdentifier("github-auth-sign-in")
            }

            Text("The OAuth token stays in the iOS Keychain, is never copied to Flipper and is removed locally when you disconnect.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
