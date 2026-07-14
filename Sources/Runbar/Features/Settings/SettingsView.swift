import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            accountSection
            discoverySection
            GitHubDebugPane(model: model)
            storageSection
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 760, height: 850)
        .task { await model.loadIfNeeded() }
    }

    private var accountSection: some View {
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
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var discoverySection: some View {
        Section("Repository discovery") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.codeRootPath ?? "No code root selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Local repositories are scanned four levels deep; remote discovery uses your 30 most recently pushed repositories.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose code root…", action: chooseCodeRoot)
                Button("Refresh") { Task { await model.refreshRepositories() } }
                    .disabled(model.isRefreshingRepositories)
            }

            discoveryStatus

            if !model.discoveredRepositories.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.discoveredRepositories) { repository in
                            repositoryRow(repository)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 170, maxHeight: 260)
            }

            Text("\(model.includedRepositoryCount) included; \(model.discoveredRepositories.count - model.includedRepositoryCount) excluded by deny-list")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            Label("The token is stored only in macOS Keychain.", systemImage: "key.fill")
            Text("The non-secret code-root path, repository metadata, and exclusions are stored in local SQLite.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                Text(message).font(.caption)
                if hasStoredCredential {
                    Button("Retry saved credential") {
                        Task { await model.retryStoredCredential() }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch model.discoveryState {
        case .idle:
            EmptyView()
        case .refreshing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Discovering repositories…").foregroundStyle(.secondary)
            }
        case .loaded:
            Label("Discovery is up to date", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func repositoryRow(_ repository: DiscoveredRepository) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(repository.identity.fullName).fontWeight(.medium)
                Text(repository.source.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if !repository.isAccessible {
                    Label("Inaccessible", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle(
                    "Exclude",
                    isOn: Binding(
                        get: { repository.isExcluded },
                        set: { value in Task { await model.setExcluded(value, for: repository) } }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if repository.workflows.isEmpty {
                Text(repository.source == .remote ? "Workflow metadata loads from the API in M2." : "No parsed workflow metadata")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(repository.workflows, id: \WorkflowMetadata.fileName) { workflow in
                    Text("\(workflow.name) · on: \(workflow.events.isEmpty ? "unspecified" : workflow.events.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseCodeRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder containing your code repositories"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseCodeRoot(url) }
    }
}
