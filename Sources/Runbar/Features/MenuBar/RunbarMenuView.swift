import AppKit
import SwiftUI

/// Layout constants shared between the panel chrome and the controller that
/// positions the panel. The margins are transparent window area reserved for
/// the card's shadow.
enum RunbarPanelMetrics {
    static let cardWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 20
    static let topMargin: CGFloat = 4
    static let horizontalMargin: CGFloat = 28
    static let bottomMargin: CGFloat = 36
}

/// Root view of the status-item panel: the menu content wrapped in self-drawn
/// chrome — glass background, continuous rounded corners, and shadows. The
/// window is fully transparent; everything visible is drawn here, so the
/// corner radius and shadow can never disagree.
struct RunbarPanelRootView: View {
    @ObservedObject var model: SettingsModel
    let settingsAction: (() -> Void)?

    var body: some View {
        RunbarMenuView(model: model, settingsAction: settingsAction)
            .background(MenuTheme.panelWash)
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(
                        .regular,
                        in: RoundedRectangle(
                            cornerRadius: RunbarPanelMetrics.cornerRadius,
                            style: .continuous
                        )
                    )
                } else {
                    PopoverGlassBackground()
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: RunbarPanelMetrics.cornerRadius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .padding(.top, RunbarPanelMetrics.topMargin)
            .padding(.horizontal, RunbarPanelMetrics.horizontalMargin)
            .padding(.bottom, RunbarPanelMetrics.bottomMargin)
    }
}

/// Appearance-adaptive "devops console" palette used by the status-item panel.
/// Built on semantic system colors so light and dark both look native.
enum MenuTheme {
    /// Semi-opaque wash layered over the panel material so the glass reads as
    /// a surface instead of pure see-through — light: #FAF8F4, dark: #191814.
    static let panelWash = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x19 / 255.0, green: 0x18 / 255.0, blue: 0x14 / 255.0, alpha: 0.3)
                : NSColor(red: 0xFA / 255.0, green: 0xF8 / 255.0, blue: 0xF4 / 255.0, alpha: 0.5)
        }
    ))
    /// Raised card/strip fill — brightens in light mode, deepens in dark mode,
    /// so surfaces never pull the panel toward middle gray.
    static let surface = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0, alpha: 0.22)
                : NSColor(white: 1, alpha: 0.5)
        }
    ))
    static let border = Color.primary.opacity(0.10)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let amber = Color(nsColor: .systemOrange)
    static let blue = Color(nsColor: .systemBlue)
}

private extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Native popover frosted glass — the same material system menus use.
private struct PopoverGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct RunbarMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: SettingsModel
    @State private var expandedRunIDs: Set<Int64> = []
    @State private var hoveredRunID: Int64?
    private let settingsAction: (() -> Void)?

    init(model: SettingsModel, settingsAction: (() -> Void)? = nil) {
        self.model = model
        self.settingsAction = settingsAction
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
            hairline
            footer
        }
        .frame(width: RunbarPanelMetrics.cardWidth)
        .task { await model.loadIfNeeded() }
    }

    private var hairline: some View {
        Rectangle()
            .fill(MenuTheme.border)
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            logoTile
            VStack(alignment: .leading, spacing: 2) {
                Text("runbar")
                    .font(.mono(14, .bold))
                    .foregroundStyle(MenuTheme.textPrimary)
                HStack(spacing: 5) {
                    Text("❯")
                        .font(.mono(10, .bold))
                        .foregroundStyle(statusAccent)
                    Text(model.menuBarIconState.statusText.lowercased())
                        .font(.mono(10))
                        .foregroundStyle(MenuTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            connectionBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MenuTheme.surface)
    }

    private var logoTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(statusAccent.opacity(0.13))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(statusAccent.opacity(0.28), lineWidth: 1)
            HStack(spacing: 2.5) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    VStack(spacing: 2.5) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Circle()
                                .fill(statusAccent)
                                .frame(width: 3, height: 3)
                        }
                    }
                }
            }
        }
        .frame(width: 30, height: 30)
    }

    private var statusAccent: Color {
        switch model.menuBarIconState {
        case .running: MenuTheme.blue
        case .idle: MenuTheme.green
        case .recentFailure: MenuTheme.red
        case .degraded: MenuTheme.amber
        case .authenticationRequired: MenuTheme.textSecondary
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.state {
        case .authenticated where model.pollSchedulerSnapshot.isRateLimitDegraded:
            statusPill(text: "degraded", color: MenuTheme.amber)
        case let .authenticated(login):
            statusPill(text: "@\(login)", color: MenuTheme.green)
        case .loading, .validating:
            ProgressView().controlSize(.small)
        case .signedOut, .failed:
            if model.providerMonitorSnapshot.hasConnectedProvider {
                statusPill(text: "connected", color: MenuTheme.green)
            } else {
                statusPill(text: "setup required", color: MenuTheme.textSecondary)
            }
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.mono(10, .medium))
                .foregroundStyle(MenuTheme.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(MenuTheme.border, lineWidth: 1))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .signedOut where !model.hasAnyConnectedProvider,
             .failed where !model.hasAnyConnectedProvider:
            connectPrompt
        case .loading, .validating:
            if model.menuBarRuns == .empty {
                loadingState
            } else {
                runList
            }
        case .authenticated, .signedOut, .failed:
            runList
        }
    }

    private var connectPrompt: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ProviderIconTile(provider: .githubActions, size: 34)
                ProviderIconTile(provider: .vercel, size: 34)
                ProviderIconTile(provider: .cloudflarePages, size: 34)
            }
            VStack(spacing: 4) {
                Text("Connect a build provider")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MenuTheme.textPrimary)
                Text("Link GitHub Actions, Vercel, or Cloudflare Pages\nto start tracking pipelines.")
                    .font(.mono(10.5))
                    .foregroundStyle(MenuTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: presentSettings) {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("syncing pipelines…")
                .font(.mono(11))
                .foregroundStyle(MenuTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var runList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let error = model.menuBarLoadError ?? model.runActionError {
                    errorBanner(error)
                }
                runningSection
                recentSection
            }
            .padding(14)
        }
        .frame(minHeight: 320, idealHeight: 500, maxHeight: 620)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(MenuTheme.amber)
            Text(message)
                .font(.mono(10.5))
                .foregroundStyle(MenuTheme.amber)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(MenuTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(MenuTheme.amber.opacity(0.25), lineWidth: 1)
        )
    }

    private func sectionHeader(_ title: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.mono(9.5, .semibold))
                .tracking(1.6)
                .foregroundStyle(MenuTheme.textSecondary)
                .fixedSize()
            Rectangle()
                .fill(MenuTheme.border)
                .frame(height: 1)
            Text("\(count)")
                .font(.mono(10, .bold))
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Running

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "running",
                count: model.menuBarRuns.running.count,
                accent: model.menuBarRuns.running.isEmpty ? MenuTheme.textSecondary : MenuTheme.blue
            )
            if model.menuBarRuns.running.isEmpty {
                emptyRunningState
            } else {
                ForEach(model.menuBarRuns.running) { runningCard($0) }
            }
        }
    }

    private var emptyRunningState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(MenuTheme.green.opacity(0.85))
            Text("no active pipelines")
                .font(.mono(11))
                .foregroundStyle(MenuTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(MenuTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func runningCard(_ item: MenuBarRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProviderIconTile(provider: item.run.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    runLink(item)
                    Text(item.repository.fullName)
                        .font(.mono(10.5))
                        .foregroundStyle(MenuTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                elapsedBadge(item)
                if item.run.supportsCancel {
                    rowActionButton(
                        icon: "stop.fill",
                        help: "Cancel this run",
                        busy: model.runActionsInFlight.contains(item.id)
                    ) {
                        Task { await model.cancelRun(item) }
                    }
                }
            }

            HStack(spacing: 6) {
                if let branch = item.run.headBranch, !branch.isEmpty {
                    metaChip(branch, icon: "arrow.triangle.branch")
                }
                metaChip(item.run.event, icon: "bolt.fill")
                Spacer(minLength: 0)
            }

            progressView(for: item)

            if item.run.supportsJobs {
                DisclosureGroup(isExpanded: jobsBinding(for: item)) {
                    jobsContent(for: item)
                        .padding(.top, 8)
                } label: {
                    Text("jobs & current step")
                        .font(.mono(10, .medium))
                        .foregroundStyle(MenuTheme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(MenuTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(MenuTheme.border, lineWidth: 1)
        )
    }

    private func elapsedBadge(_ item: MenuBarRun) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MenuTheme.blue)
                .frame(width: 5, height: 5)
            Text(
                WorkflowRunPresentation.elapsedText(
                    startedAt: item.run.runStartedAt,
                    now: model.menuBarNow
                )
            )
            .font(.mono(11.5, .bold))
            .foregroundStyle(MenuTheme.blue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MenuTheme.blue.opacity(0.12), in: Capsule())
        .accessibilityIdentifier("running-elapsed-\(item.id)")
    }

    /// Trailing slot of a recent row: the timestamp at rest, crossfading to
    /// the row's actions on hover — so every row's right edge stays aligned.
    @ViewBuilder
    private func recentRowTrailing(_ item: MenuBarRun, failed: Bool) -> some View {
        let canRerun = failed && item.run.supportsRerun
        let previewLink = item.run.previewURL.flatMap(URL.init(string:))
        let isBusy = model.runActionsInFlight.contains(item.id)
        let showActions = (hoveredRunID == item.id || isBusy) && (canRerun || previewLink != nil)

        ZStack(alignment: .trailing) {
            Text(WorkflowRunPresentation.relativeText(date: item.run.createdAt, now: model.menuBarNow))
                .font(.mono(9.5))
                .foregroundStyle(MenuTheme.textSecondary)
                .opacity(showActions ? 0 : 1)
            HStack(spacing: 4) {
                if canRerun {
                    rowActionButton(icon: "arrow.clockwise", help: "Re-run this workflow", busy: isBusy) {
                        Task { await model.rerunRun(item) }
                    }
                }
                if let previewLink {
                    rowActionButton(icon: "safari", help: "Open deployment") {
                        NSWorkspace.shared.open(previewLink)
                    }
                }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .animation(.easeOut(duration: 0.12), value: showActions)
    }

    private func rowActionButton(
        icon: String,
        help: String,
        busy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(MenuTheme.border, lineWidth: 1)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.45)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(MenuTheme.textSecondary)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
    }

    private func metaChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(text)
                .font(.mono(9.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(MenuTheme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(MenuTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func progressView(for item: MenuBarRun) -> some View {
        switch WorkflowRunPresentation.progressState(
            startedAt: item.run.runStartedAt,
            medianDurationSeconds: item.medianDurationSeconds,
            now: model.menuBarNow
        ) {
        case .noHistory:
            Text("no duration history")
                .font(.mono(9.5))
                .foregroundStyle(MenuTheme.textSecondary.opacity(0.7))
                .accessibilityIdentifier("progress-no-history-\(item.id)")
        case let .estimated(elapsedSeconds, medianDurationSeconds):
            VStack(alignment: .leading, spacing: 5) {
                progressBar(
                    fraction: Double(elapsedSeconds) / Double(medianDurationSeconds),
                    color: MenuTheme.blue
                )
                HStack {
                    Text("median \(WorkflowRunPresentation.durationText(seconds: medianDurationSeconds))")
                    Spacer()
                    Text("~\(WorkflowRunPresentation.durationText(seconds: max(0, medianDurationSeconds - elapsedSeconds))) left")
                }
                .font(.mono(9.5))
                .foregroundStyle(MenuTheme.textSecondary)
            }
            .accessibilityIdentifier("progress-estimated-\(item.id)")
        case let .runningLong(_, medianDurationSeconds):
            VStack(alignment: .leading, spacing: 5) {
                progressBar(fraction: 1, color: MenuTheme.amber)
                Text("running long · median \(WorkflowRunPresentation.durationText(seconds: medianDurationSeconds))")
                    .font(.mono(9.5, .semibold))
                    .foregroundStyle(MenuTheme.amber)
            }
            .accessibilityIdentifier("progress-running-long-\(item.id)")
        }
    }

    private func progressBar(fraction: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.65), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "recent",
                count: model.menuBarRuns.recent.count,
                accent: MenuTheme.textSecondary
            )
            if model.menuBarRuns.recent.isEmpty {
                Text("completed runs will appear here")
                    .font(.mono(11))
                    .foregroundStyle(MenuTheme.textSecondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.menuBarRuns.recent) { recentRow($0) }
                }
            }
        }
    }

    private func recentRow(_ item: MenuBarRun) -> some View {
        let failed = WorkflowRunPresentation.isFailure(item.run.conclusion)
        return HStack(alignment: .center, spacing: 10) {
            ProviderIconTile(provider: item.run.provider, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(conclusionColor(item.run.conclusion))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    runLink(item)
                    if item.matchesLocalHEAD {
                        headBadge
                    }
                    Spacer(minLength: 6)
                    recentRowTrailing(item, failed: failed)
                }
                HStack(spacing: 6) {
                    Text(item.repository.fullName)
                        .lineLimit(1)
                    Text("·")
                    Text(conclusionText(item.run.conclusion))
                        .foregroundStyle(conclusionColor(item.run.conclusion))
                    Text("·")
                    Text(
                        WorkflowRunPresentation.durationText(
                            startedAt: item.run.runStartedAt,
                            completedAt: item.run.completedAt
                        )
                    )
                }
                .font(.mono(10))
                .foregroundStyle(MenuTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .onHover { hovering in
            if hovering {
                hoveredRunID = item.id
            } else if hoveredRunID == item.id {
                hoveredRunID = nil
            }
        }
        .background(
            failed ? MenuTheme.red.opacity(0.07) : MenuTheme.surface,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    failed
                        ? MenuTheme.red.opacity(0.25)
                        : (item.matchesLocalHEAD ? MenuTheme.blue.opacity(0.35) : MenuTheme.border),
                    lineWidth: 1
                )
        )
    }

    private var headBadge: some View {
        Text("HEAD")
            .font(.mono(8.5, .bold))
            .tracking(0.5)
            .foregroundStyle(MenuTheme.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MenuTheme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func conclusionColor(_ conclusion: String?) -> Color {
        if conclusion == "success" { return MenuTheme.green }
        if WorkflowRunPresentation.isFailure(conclusion) { return MenuTheme.red }
        return MenuTheme.textSecondary
    }

    private func conclusionText(_ conclusion: String?) -> String {
        (conclusion ?? "completed").replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Jobs

    private func jobsBinding(for item: MenuBarRun) -> Binding<Bool> {
        Binding(
            get: { expandedRunIDs.contains(item.id) },
            set: { expanded in
                if expanded {
                    expandedRunIDs.insert(item.id)
                    model.expandJobs(for: item)
                } else {
                    expandedRunIDs.remove(item.id)
                }
            }
        )
    }

    @ViewBuilder
    private func jobsContent(for item: MenuBarRun) -> some View {
        switch model.jobsState(for: item.id) {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("loading jobs…")
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.textSecondary)
            }
        case let .failed(message):
            HStack {
                Text(message)
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.red)
                    .lineLimit(2)
                Spacer()
                Button("retry") { model.expandJobs(for: item) }
                    .buttonStyle(.link)
                    .font(.mono(10, .semibold))
            }
        case let .loaded(jobs):
            if jobs.isEmpty {
                Text("no jobs reported")
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(jobs) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: job.status == "in_progress" ? "play.circle.fill" : "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    job.status == "in_progress" ? MenuTheme.blue : MenuTheme.textSecondary
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                if let htmlURL = job.htmlURL, let url = URL(string: htmlURL) {
                                    Link(job.name, destination: url)
                                        .font(.system(size: 11, weight: .medium))
                                } else {
                                    Text(job.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MenuTheme.textPrimary)
                                }
                                if let step = job.executingStep {
                                    Text("now: \(step.name)")
                                        .font(.mono(9.5))
                                        .foregroundStyle(MenuTheme.textSecondary)
                                } else {
                                    Text(job.status.replacingOccurrences(of: "_", with: " "))
                                        .font(.mono(9.5))
                                        .foregroundStyle(MenuTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lastSyncText.lowercased())
                    .foregroundStyle(MenuTheme.textSecondary)
                Text("v" + appVersion)
                    .foregroundStyle(MenuTheme.textSecondary.opacity(0.6))
            }
            .font(.mono(9.5))

            Spacer()

            footerButton(
                systemImage: "arrow.clockwise",
                help: "Refresh now",
                disabled: model.isManualRefreshRunning || !model.hasAnyConnectedProvider,
                isBusy: model.isManualRefreshRunning
            ) {
                Task { await model.manualRefresh() }
            }
            footerButton(systemImage: "gearshape.fill", help: "Settings") {
                presentSettings()
            }
            footerButton(systemImage: "power", help: "Quit Runbar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MenuTheme.surface)
    }

    private func footerButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(MenuTheme.border, lineWidth: 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MenuTheme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var lastSyncText: String {
        let lastSync = [
            model.pollSchedulerSnapshot.lastSyncAt,
            model.providerMonitorSnapshot.lastSyncAt
        ].compactMap { $0 }.max()
        guard let lastSync else { return "Last sync —" }
        return "Last sync \(WorkflowRunPresentation.relativeText(date: lastSync, now: model.menuBarNow))"
    }

    // MARK: - Shared

    @ViewBuilder
    private func runLink(_ item: MenuBarRun) -> some View {
        if let url = URL(string: item.run.htmlURL) {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Text(item.run.workflowName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(MenuTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(MenuTheme.textSecondary.opacity(0.8))
                }
            }
        } else {
            Text(item.run.workflowName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(MenuTheme.textPrimary)
                .lineLimit(1)
        }
    }

    @MainActor
    private func presentSettings() {
        if let settingsAction {
            settingsAction()
        } else {
            openSettings()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let application = NSApplication.shared
            application.activate(ignoringOtherApps: true)
            if let settingsWindow = application.windows.first(where: { window in
                window.canBecomeKey && window.styleMask.contains(.titled)
            }) {
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.orderFrontRegardless()
            }
        }
    }
}
