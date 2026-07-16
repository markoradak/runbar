import AppKit
import SwiftUI

/// Shared styling for the settings window, mirroring the menu panel's
/// devops-console look (mono accents, status pills) on native controls.
enum SettingsUI {
    static let windowSize = NSSize(width: 780, height: 620)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Capsule status pill with a colored dot, matching the menu panel's pills.
struct SettingsStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(SettingsUI.mono(10, .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

/// Bordered content card with an optional tracked-caps header and footer,
/// matching the menu panel's section styling.
struct SettingsCard<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(SettingsUI.mono(9.5, .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Hairline separator between rows inside a `SettingsCard`.
struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case accounts
    case repositories
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .repositories: "Repositories"
        case .advanced: "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .accounts: "key.fill"
        case .repositories: "folder.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var updater = UpdaterService.shared
    @ObservedObject private var loginItems = LoginItemService.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            content
        }
        .frame(width: SettingsUI.windowSize.width)
        .frame(minHeight: SettingsUI.windowSize.height, maxHeight: .infinity)
        .ignoresSafeArea()
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                sidebarLogo
                VStack(alignment: .leading, spacing: 1) {
                    Text("runbar")
                        .font(SettingsUI.mono(13, .bold))
                    Text("v" + appVersion)
                        .font(SettingsUI.mono(9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(SettingsTab.allCases) { tab in
                sidebarItem(tab)
            }

            Spacer()

            sidebarStatus
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .padding(.top, 46)
        .frame(width: 178)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private var sidebarLogo: some View {
        RunbarIconTile(tint: .accentColor, size: 26)
    }

    private func sidebarItem(_ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                selectedTab == tab ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var sidebarStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.authenticatedLogin == nil ? Color.secondary : Color.green)
                .frame(width: 6, height: 6)
            Text(model.authenticatedLogin.map { "@\($0)" } ?? "not connected")
                .font(SettingsUI.mono(9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedTab {
                case .general: generalTab
                case .accounts: accountsTab
                case .repositories: repositoriesTab
                case .advanced: advancedTab
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 42)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        SettingsCard("Startup") {
            HStack {
                Text("Launch at login")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { loginItems.isEnabled },
                        set: { loginItems.setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
        }

        SettingsCard("Appearance") {
            HStack {
                Text("Theme")
                    .font(.system(size: 12.5))
                Spacer()
                Picker(
                    "Theme",
                    selection: Binding(
                        get: { model.appearancePreference },
                        set: { model.setAppearancePreference($0) }
                    )
                ) {
                    ForEach(AppearancePreference.allCases, id: \.self) { preference in
                        Text(preference.displayName)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsCard(
            "Notifications",
            footer: "Notifications include the conclusion and open the build or deployment at its provider when clicked."
        ) {
            switch model.notificationAuthorizationState {
            case .authorized:
                HStack {
                    Text("Run completion notifications")
                        .font(.system(size: 12.5))
                    Spacer()
                    SettingsStatusPill(text: "enabled", color: .green)
                }
            case .denied:
                HStack {
                    Text("Run completion notifications")
                        .font(.system(size: 12.5))
                    Spacer()
                    SettingsStatusPill(text: "disabled in system settings", color: .orange)
                }
            case .notDetermined:
                Button("Enable run completion notifications") {
                    Task { await model.requestNotificationAuthorization() }
                }
            }

            SettingsCardDivider()

            HStack {
                Text("Failures only")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle(
                    "Failures only",
                    isOn: Binding(
                        get: { model.notificationsFailuresOnly },
                        set: { model.setNotificationsFailuresOnly($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
        }

        SettingsCard(
            "Updates",
            footer: "Updates are downloaded from GitHub releases and verified with a signed appcast."
        ) {
            HStack {
                Text("Version")
                    .font(.system(size: 12.5))
                Spacer()
                Text("v" + appVersion)
                    .font(SettingsUI.mono(11))
                    .foregroundStyle(.secondary)
            }

            SettingsCardDivider()

            HStack {
                Text("Automatically check for updates")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            SettingsCardDivider()

            HStack {
                Text("Check for updates now")
                    .font(.system(size: 12.5))
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        SettingsCard(
            "Storage",
            footer: "The non-secret code-root path, repository metadata, provider execution history, and exclusions are stored in local SQLite."
        ) {
            Label(
                "GitHub, Vercel, and Cloudflare credentials are stored only in macOS Keychain.",
                systemImage: "key.fill"
            )
            .font(.system(size: 12.5))
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsTab: some View {
        githubCard
        providerCard(
            .vercel,
            subtitle: "Deployments · scoped API token · read-only",
            tokenURL: URL(string: "https://vercel.com/account/settings/tokens")!,
            permissionText: "Create a token scoped to the personal account or team you want to monitor. Runbar only performs read requests. Tokens are stored only in macOS Keychain."
        )
        providerCard(
            .cloudflarePages,
            subtitle: "Pages deployments · scoped API token · read-only",
            tokenURL: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!,
            permissionText: "Create a custom token with Account · Cloudflare Pages · Read for the accounts you want to monitor. Tokens are stored only in macOS Keychain."
        )
    }

    private var githubCard: some View {
        SettingsCard(
            footer: "Runbar uses GitHub's device sign-in and requests read-only access to Actions, Metadata, and Contents. Repository access is granted separately for every personal account or organization — choose All repositories during installation to monitor everything in that account."
        ) {
            HStack(spacing: 10) {
                ProviderIconTile(provider: .githubActions, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Actions · device sign-in · read-only")
                        .font(SettingsUI.mono(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                githubStatusPill
            }

            deviceSignInView

            if case let .failed(message, hasStoredCredential) = model.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                if hasStoredCredential {
                    Button("Retry saved credential") {
                        Task { await model.retryStoredCredential() }
                    }
                    .disabled(model.isBusy)
                }
            }

            SettingsCardDivider()

            HStack(spacing: 10) {
                if model.authenticatedLogin == nil {
                    Button("Connect GitHub") {
                        Task { await model.beginGitHubAppSignIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                } else {
                    Button("Disconnect GitHub", role: .destructive) {
                        model.deleteCredential()
                    }
                    .disabled(model.isBusy)
                }

                if model.isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Link(destination: GitHubAppConfiguration.installationURL) {
                    Label("Install on an organization", systemImage: "building.2.crop.circle")
                }
                .buttonStyle(.bordered)

                Link("Manage installations", destination: GitHubAppConfiguration.managementURL)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var githubStatusPill: some View {
        switch model.state {
        case .loading:
            SettingsStatusPill(text: "reading keychain", color: .secondary)
        case .validating:
            SettingsStatusPill(text: "validating…", color: .secondary)
        case .signedOut:
            SettingsStatusPill(text: "not connected", color: .secondary)
        case let .authenticated(login):
            SettingsStatusPill(text: "@\(login)", color: .green)
                .accessibilityIdentifier("authenticated-github-login")
        case .failed:
            SettingsStatusPill(text: "needs attention", color: .orange)
        }
    }

    private func providerCard(
        _ provider: ExecutionProvider,
        subtitle: String,
        tokenURL: URL,
        permissionText: String
    ) -> some View {
        SettingsCard(footer: permissionText) {
            HStack(spacing: 10) {
                ProviderIconTile(provider: provider, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.shortName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(SettingsUI.mono(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                providerConnectionPill(provider)
            }

            SettingsCardDivider()

            switch model.providerState(provider) {
            case let .connected(accountLabel, projectCount):
                HStack {
                    Text("\(accountLabel) · \(projectCount) project\(projectCount == 1 ? "" : "s")")
                        .font(SettingsUI.mono(11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        Task { await model.deleteProviderCredential(provider) }
                    }
                }
            case .validating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Validating and discovering projects…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .failed(message, hasStoredCredential):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                if hasStoredCredential {
                    HStack {
                        Button("Retry") { Task { await model.retryProvider(provider) } }
                        Button("Disconnect", role: .destructive) {
                            Task { await model.deleteProviderCredential(provider) }
                        }
                    }
                } else {
                    providerTokenEntry(provider, tokenURL: tokenURL)
                }
            case .disconnected:
                providerTokenEntry(provider, tokenURL: tokenURL)
            }
        }
    }

    private func providerTokenEntry(_ provider: ExecutionProvider, tokenURL: URL) -> some View {
        HStack(spacing: 8) {
            SecureField(
                provider.displayName + " API token",
                text: Binding(
                    get: { model.providerTokenInputs[provider, default: ""] },
                    set: { model.providerTokenInputs[provider] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            Button("Connect") { Task { await model.saveProviderToken(provider) } }
                .buttonStyle(.borderedProminent)
            Link("Create token", destination: tokenURL)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func providerConnectionPill(_ provider: ExecutionProvider) -> some View {
        switch model.providerState(provider) {
        case .connected:
            SettingsStatusPill(text: "connected", color: .green)
        case .validating:
            SettingsStatusPill(text: "connecting…", color: .secondary)
        case .failed:
            SettingsStatusPill(text: "needs attention", color: .orange)
        case .disconnected:
            SettingsStatusPill(text: "not connected", color: .secondary)
        }
    }

    @ViewBuilder
    private var deviceSignInView: some View {
        switch model.deviceSignInState {
        case .idle:
            EmptyView()
        case .requestingCode:
            Label("Requesting a sign-in code from GitHub…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        case let .awaitingAuthorization(userCode, verificationURL):
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code on GitHub:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(userCode)
                    .font(SettingsUI.mono(20, .bold))
                    .textSelection(.enabled)
                Button("Open GitHub device sign-in") {
                    NSWorkspace.shared.open(verificationURL)
                }
                .controlSize(.small)
                Text("After sign-in, install Runbar on each personal account or organization you want it to monitor and choose All repositories or selected repositories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Repositories

    @ViewBuilder
    private var repositoriesTab: some View {
        SettingsCard(
            "Code root",
            footer: "Local checkouts are shown first. Runbar scans four levels deep and also checks the 30 most recently active repositories across your Runbar GitHub App installations."
        ) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.codeRootPath ?? "No code root selected")
                        .font(SettingsUI.mono(11.5, .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Folder scanned for local checkouts")
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
        }

        SettingsCard("Monitored repositories") {
            HStack(spacing: 8) {
                SettingsStatusPill(
                    text: "\(model.localRepositoryCount) local",
                    color: .secondary
                )
                SettingsStatusPill(
                    text: "\(model.includedRepositoryCount) included",
                    color: .green
                )
                if model.inaccessibleRepositoryCount > 0 {
                    SettingsStatusPill(
                        text: "\(model.inaccessibleRepositoryCount) need access",
                        color: .orange
                    )
                }
                Spacer()
            }

            if model.discoveredRepositories.isEmpty {
                Text("No repositories discovered yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.discoveredRepositories) { repository in
                            repositoryRow(repository)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 180, maxHeight: 300)
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
                                    .font(SettingsUI.mono(10.5))
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
                .font(.system(size: 11.5))
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
            .font(.caption)
        case .loaded:
            Label("Discovery is up to date", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func repositoryRow(_ repository: DiscoveredRepository) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: repository.source.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(repository.isLocalCheckout ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.identity.fullName)
                        .font(.system(size: 12.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(repository.source.userLabel)
                        if repository.isLocalCheckout, let activityAt = repository.localActivityAt {
                            Text("·")
                            Text("active " + WorkflowRunPresentation.relativeText(date: activityAt, now: Date()))
                        }
                    }
                    .font(SettingsUI.mono(10))
                    .foregroundStyle(.secondary)
                }

                Spacer()
                muteButton(for: repository)
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
                        Text("Install Runbar for this organization or include this repository in the existing installation, then retry.")
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
                        .font(SettingsUI.mono(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func muteButton(for repository: DiscoveredRepository) -> some View {
        let key = repository.identity.normalizedKey
        let muted = model.isNotificationsMuted(forRepositoryKey: key)
        return Button {
            model.setNotificationsMuted(!muted, forRepositoryKey: key)
        } label: {
            Image(systemName: muted ? "bell.slash.fill" : "bell")
                .font(.system(size: 11))
                .foregroundStyle(muted ? Color.orange : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(muted ? "Notifications muted — click to unmute" : "Mute notifications for this repository")
        .accessibilityLabel(muted ? "Unmute notifications" : "Mute notifications")
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedTab: some View {
        PollSchedulerStatusView(model: model)
        GitHubDebugPane(model: model)
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
