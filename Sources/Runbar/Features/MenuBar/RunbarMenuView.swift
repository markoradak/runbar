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

/// Small bordered icon button with a hover highlight, used for row actions.
private struct RowActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0.05))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(MenuTheme.border, lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(hovered ? MenuTheme.textPrimary : MenuTheme.textSecondary)
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Workflow-name link that highlights on hover.
private struct RunTitleLink: View {
    let title: String
    let url: URL?
    @State private var hovered = false

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(hovered ? MenuTheme.blue : MenuTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(hovered ? MenuTheme.blue : MenuTheme.textSecondary.opacity(0.8))
                }
            }
            .onHover { hovered = $0 }
        } else {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(MenuTheme.textPrimary)
                .lineLimit(1)
        }
    }
}

/// Chevron that expands/collapses a failed row's log, with hover highlight.
private struct FailureLogToggle: View {
    let expanded: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? MenuTheme.textPrimary : MenuTheme.textSecondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(expanded ? "Hide failure log" : "Show failure log")
        .accessibilityLabel(expanded ? "Hide failure log" : "Show failure log")
    }
}

/// Floating copy-to-clipboard button for the terminal block. Styled for the
/// always-dark terminal background; flashes a green check after copying.
private struct CopyLogButton: View {
    let lines: [String]
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    copied
                        ? Color(red: 0.35, green: 0.85, blue: 0.48)
                        : (hovered ? Color.white : Color(white: 0.72))
                )
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovered ? 0.16 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Copy log")
        .accessibilityLabel("Copy log")
    }
}

/// AppKit-backed log view: wheel scrolling rubber-bands at the edges instead
/// of bubbling to the panel's scroll view, and text is selectable.
private struct TerminalLogView: NSViewRepresentable {
    let lines: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.lines != lines,
              let textView = scroll.documentView as? NSTextView
        else { return }
        // Follow the tail only while the user is already at the bottom; if
        // they scrolled up to read, leave their position alone.
        let wasAtBottom: Bool
        if let documentView = scroll.documentView {
            wasAtBottom = documentView.bounds.height - scroll.contentView.bounds.maxY < 24
        } else {
            wasAtBottom = true
        }
        context.coordinator.lines = lines
        textView.textStorage?.setAttributedString(Self.attributedText(lines))
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        var lines: [String] = []
    }

    private static func attributedText(_ lines: [String]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let color: NSColor = if line.hasPrefix("Error:") {
                NSColor(red: 1.0, green: 0.48, blue: 0.44, alpha: 1)
            } else if line.hasPrefix("Warning:") {
                NSColor(red: 0.95, green: 0.76, blue: 0.36, alpha: 1)
            } else {
                NSColor(white: 0.92, alpha: 1)
            }
            result.append(
                NSAttributedString(
                    string: (index > 0 ? "\n" : "") + (line.isEmpty ? " " : line),
                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                )
            )
        }
        return result
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
    @State private var expandedFailureLogIDs: Set<Int64> = []
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
            RunbarIconTile(tint: statusAccent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                RunbarWordmarkShape()
                    .fill(MenuTheme.textPrimary)
                    .frame(width: 13 * RunbarWordmarkShape.aspectRatio, height: 13)
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
        case .authenticated where model.pollSchedulerSnapshot.isRateLimitDegraded
            || model.providerMonitorSnapshot.isRateLimitDegraded:
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
                if let error = model.menuBarLoadError {
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
                    HStack(spacing: 6) {
                        runLink(item)
                        if item.run.provider == .githubActions {
                            workflowBadge(item.run.workflowName)
                        }
                    }
                    Text(item.repository.fullName)
                        .font(.mono(10.5))
                        .foregroundStyle(MenuTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                elapsedBadge(item)
            }

            HStack(spacing: 6) {
                if let branch = item.run.headBranch, !branch.isEmpty {
                    metaChip(branch, icon: "arrow.triangle.branch")
                }
                metaChip(item.run.event, icon: "bolt.fill")
                Spacer(minLength: 6)
                FailureLogToggle(expanded: model.expandedLiveLogRunIDs.contains(item.id)) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.toggleLiveLog(for: item)
                    }
                }
            }

            progressView(for: item)

            if model.expandedLiveLogRunIDs.contains(item.id) {
                liveLogContent(item)
            }

            if item.run.supportsJobs {
                DisclosureGroup(isExpanded: jobsBinding(for: item)) {
                    jobsContent(for: item)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    private func recentRowTrailing(_ item: MenuBarRun) -> some View {
        let previewLink = item.run.previewURL.flatMap(URL.init(string:))
        let showActions = hoveredRunID == item.id && previewLink != nil

        ZStack(alignment: .trailing) {
            Text(WorkflowRunPresentation.relativeText(date: item.run.createdAt, now: model.menuBarNow))
                .font(.mono(9.5))
                .foregroundStyle(MenuTheme.textSecondary)
                .opacity(showActions ? 0 : 1)
            if let previewLink {
                rowActionButton(icon: "safari", help: "Open deployment") {
                    NSWorkspace.shared.open(previewLink)
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showActions)
    }

    private func rowActionButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        RowActionButton(icon: icon, help: help, action: action)
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
        return VStack(alignment: .leading, spacing: 8) {
            recentRowHeader(item, failed: failed)
            if failed, expandedFailureLogIDs.contains(item.id) {
                failureLogContent(item)
                    .padding(.bottom, 2)
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

    private func recentRowHeader(_ item: MenuBarRun, failed: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
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
                    if item.run.provider == .githubActions {
                        workflowBadge(item.run.workflowName)
                    }
                    if item.matchesLocalHEAD {
                        headBadge
                    }
                    Spacer(minLength: 6)
                    recentRowTrailing(item)
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
                    if failed {
                        Spacer(minLength: 6)
                        failureLogToggle(item)
                    }
                }
                .font(.mono(10))
                .foregroundStyle(MenuTheme.textSecondary)
            }
        }
    }

    // MARK: - Failure log

    private func failureLogToggle(_ item: MenuBarRun) -> some View {
        FailureLogToggle(expanded: expandedFailureLogIDs.contains(item.id)) {
            withAnimation(.easeOut(duration: 0.15)) {
                if expandedFailureLogIDs.contains(item.id) {
                    expandedFailureLogIDs.remove(item.id)
                } else {
                    expandedFailureLogIDs.insert(item.id)
                    model.expandFailureLog(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func failureLogContent(_ item: MenuBarRun) -> some View {
        switch model.failureLogState(for: item.id) {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("fetching logs…")
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.textSecondary)
            }
        case let .failed(message):
            HStack {
                Text(message)
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.red)
                Spacer()
                Button("retry") { model.expandFailureLog(for: item) }
                    .buttonStyle(.link)
                    .font(.mono(10, .semibold))
            }
        case let .loaded(log):
            terminalBlock(log.lines)
        }
    }

    /// Live build output for a running card, streaming while expanded.
    @ViewBuilder
    private func liveLogContent(_ item: MenuBarRun) -> some View {
        switch model.liveLogState(for: item.id) {
        case .idle, .loading, .failed:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("waiting for build output…")
                    .font(.mono(10))
                    .foregroundStyle(MenuTheme.textSecondary)
            }
        case let .loaded(log):
            terminalBlock(log.lines)
        }
    }

    /// Terminal-styled log tail — always dark, regardless of app theme.
    /// AppKit-backed so wheel scrolling stays contained instead of bubbling
    /// to the panel's scroll view.
    private func terminalBlock(_ lines: [String]) -> some View {
        TerminalLogView(lines: lines)
            .frame(height: min(200, CGFloat(lines.count) * 17 + 22))
            .background(
                Color(red: 0.055, green: 0.065, blue: 0.09),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottomTrailing) {
                CopyLogButton(lines: lines)
                    .padding(6)
            }
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

    /// GitHub runs lead with the repository (the project), matching how
    /// deployment providers lead with the project name; the workflow is shown
    /// as a badge next to the title instead.
    private func displayName(_ item: MenuBarRun) -> String {
        item.run.provider == .githubActions ? item.repository.name : item.run.workflowName
    }

    private func runLink(_ item: MenuBarRun) -> some View {
        RunTitleLink(title: displayName(item), url: URL(string: item.run.htmlURL))
    }

    private func workflowBadge(_ name: String) -> some View {
        Text(name)
            .font(.mono(8.5, .semibold))
            .foregroundStyle(MenuTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(MenuTheme.border, lineWidth: 1)
            )
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
