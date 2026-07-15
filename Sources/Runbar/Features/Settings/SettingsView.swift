import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            accountSection
            discoverySection
            notificationsSection
            PollSchedulerStatusView(model: model)
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.codeRootPath ?? "No code root selected")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Local checkouts are shown first. Runbar scans four levels deep and also checks your 30 most recently pushed GitHub repositories.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…", action: chooseCodeRoot)
                Button { Task { await model.refreshRepositories() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingRepositories)
            }

            discoveryStatus

            if let notice = model.repositoryAccessNotice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.discoveredRepositories.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.discoveredRepositories) { repository in
                            repositoryRow(repository)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 190, maxHeight: 320)
            }

            if !model.skippedLocalRepositories.isEmpty {
                DisclosureGroup(
                    String(model.skippedLocalRepositories.count) + " local repositories not monitored"
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.skippedLocalRepositories) { skipped in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.tertiary)
                                Text(skipped.relativePath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(skipped.reason.userMessage)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            HStack(spacing: 12) {
                Label(String(model.localRepositoryCount) + " local", systemImage: "laptopcomputer")
                Label(String(model.includedRepositoryCount) + " included", systemImage: "checkmark.circle")
                if model.inaccessibleRepositoryCount > 0 {
                    Label(String(model.inaccessibleRepositoryCount) + " need access", systemImage: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            switch model.notificationAuthorizationState {
            case .authorized:
                Label("Run completion notifications are enabled", systemImage: "bell.badge.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Notifications are disabled in System Settings", systemImage: "bell.slash.fill")
                    .foregroundStyle(.orange)
            case .notDetermined:
                Button("Enable run completion notifications") {
                    Task { await model.requestNotificationAuthorization() }
                }
            }

            Toggle(
                "Failures only",
                isOn: Binding(
                    get: { model.notificationsFailuresOnly },
                    set: { model.setNotificationsFailuresOnly($0) }
                )
            )
            Text("Notifications include the conclusion and open the workflow run on GitHub when clicked.")
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: repository.source.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(repository.isLocalCheckout ? Color.accentColor : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.identity.fullName)
                        .font(.body.weight(.semibold))
                    Text(repository.source.userLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if repository.isLocalCheckout, let activityAt = repository.localActivityAt {
                        Text("Local activity " + WorkflowRunPresentation.relativeText(date: activityAt, now: Date()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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

            if !repository.isAccessible {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("GitHub denied Actions access")
                            .font(.caption.weight(.semibold))
                        Text("Add this repository to the fine-grained token, or ask its resource owner to approve the token, then retry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.isRetryingAccess(for: repository) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking access…")
                            }
                            .font(.caption)
                        } else {
                            Button("Retry access") {
                                Task { await model.retryRepositoryAccess(repository) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(9)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if repository.workflows.isEmpty {
                Text(repository.source == .remote ? "Workflow details load from GitHub as runs are monitored." : "No parsed workflow metadata")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(repository.workflows, id: \WorkflowMetadata.fileName) { workflow in
                    Text(workflow.name + " · on: " + (workflow.events.isEmpty ? "unspecified" : workflow.events.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
