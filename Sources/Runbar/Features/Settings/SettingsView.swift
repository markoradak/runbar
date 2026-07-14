import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("GitHub account") {
                statusView

                SecureField("Fine-grained personal access token", text: $model.tokenInput)
                    .disabled(model.isBusy)

                Text("Required permissions: Actions read, Metadata read, and Contents read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(model.hasStoredCredential ? "Validate and replace" : "Validate and save") {
                        Task { await model.saveEnteredToken() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.hasStoredCredential {
                        Button("Remove credential", role: .destructive) {
                            model.deleteCredential()
                        }
                        .disabled(model.isBusy)
                    }

                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Section("Storage") {
                Label("The token is stored only in macOS Keychain.", systemImage: "key.fill")
                Text("Runbar never stores it in preferences, local files, databases, or logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 340)
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .loading:
            Label("Reading macOS Keychain…", systemImage: "key")
        case .signedOut:
            Label("No GitHub account connected", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        case .validating:
            Label("Validating with GitHub…", systemImage: "network")
        case let .authenticated(login):
            Label("Authenticated as @\(login)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("authenticated-github-login")
        case let .failed(message, hasStoredCredential):
            VStack(alignment: .leading, spacing: 6) {
                Label("Authentication needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                if hasStoredCredential {
                    Button("Retry saved credential") {
                        Task { await model.retryStoredCredential() }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }
}
