import AppKit
import SwiftUI

struct RunbarMenuView: View {
    @ObservedObject var model: SettingsModel
    @State private var expandedRunIDs: Set<Int64> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440)
        .task { await model.loadIfNeeded() }
        .onAppear { model.menuBarDidAppear() }
        .onDisappear { model.menuBarDidDisappear() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Runbar")
                .font(.headline)
            Spacer()
            connectionBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .signedOut, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label("GitHub setup required", systemImage: "key")
                    .font(.headline)
                Text("Add a fine-grained GitHub token in Settings to monitor Actions runs.")
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Label("Open Settings", systemImage: "gear")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        case .loading, .validating:
            if model.menuBarRuns == .empty {
                ProgressView("Loading Runbar…")
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                runList
            }
        case .authenticated:
            runList
        }
    }

    private var runList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = model.menuBarLoadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                runningSection
                recentSection
            }
            .padding(14)
        }
        .frame(minHeight: 320, idealHeight: 500, maxHeight: 620)
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Running now", count: model.menuBarRuns.running.count)
            if model.menuBarRuns.running.isEmpty {
                Label("No active workflow runs", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.menuBarRuns.running) { item in
                    runningCard(item)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent", count: model.menuBarRuns.recent.count)
            if model.menuBarRuns.recent.isEmpty {
                Text("Completed runs will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.menuBarRuns.recent) { item in
                    recentRow(item)
                }
            }
        }
    }

    private func runningCard(_ item: MenuBarRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    runLink(item)
                    Text(item.repository.fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(
                    WorkflowRunPresentation.elapsedText(
                        startedAt: item.run.runStartedAt,
                        now: model.menuBarNow
                    )
                )
                .font(.callout.monospacedDigit().weight(.semibold))
                .accessibilityIdentifier("running-elapsed-\(item.id)")
            }

            HStack(spacing: 10) {
                if let branch = item.run.headBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
                Label(item.run.event, systemImage: "bolt")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Workflow is active")

            DisclosureGroup(isExpanded: jobsBinding(for: item)) {
                jobsContent(for: item)
                    .padding(.top, 6)
            } label: {
                Text("Jobs and current step")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func recentRow(_ item: MenuBarRun) -> some View {
        HStack(alignment: .top, spacing: 9) {
            conclusionIcon(item.run.conclusion)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    runLink(item)
                    if item.matchesLocalHEAD {
                        Label("Local HEAD", systemImage: "location.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                Text(item.repository.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(item.run.conclusion?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Completed")
                    Text(
                        WorkflowRunPresentation.durationText(
                            startedAt: item.run.runStartedAt,
                            completedAt: item.run.completedAt
                        )
                    )
                    Text(WorkflowRunPresentation.relativeText(date: item.run.createdAt, now: model.menuBarNow))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            item.matchesLocalHEAD ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

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
                Text("Loading jobs conditionally…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .failed(message):
            HStack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { model.expandJobs(for: item) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case let .loaded(jobs):
            if jobs.isEmpty {
                Text("No jobs reported by GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(jobs) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: job.status == "in_progress" ? "play.circle.fill" : "circle")
                                .foregroundStyle(job.status == "in_progress" ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                if let htmlURL = job.htmlURL, let url = URL(string: htmlURL) {
                                    Link(job.name, destination: url)
                                } else {
                                    Text(job.name)
                                }
                                if let step = job.executingStep {
                                    Text("Now: \(step.name)")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(job.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let remaining = model.pollSchedulerSnapshot.rateLimit.remaining {
                    Text("Rate limit \(remaining)")
                        .foregroundStyle(model.pollSchedulerSnapshot.isRateLimitDegraded ? .orange : .secondary)
                } else {
                    Text("Rate limit —")
                        .foregroundStyle(.secondary)
                }
                Text(lastSyncText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())

            Spacer()

            Button {
                Task { await model.manualRefresh() }
            } label: {
                if model.isManualRefreshRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh now")
            .disabled(model.isManualRefreshRunning || model.authenticatedLogin == nil)
            .accessibilityLabel("Refresh now")

            SettingsLink {
                Image(systemName: "gear")
            }
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Runbar")
            .accessibilityLabel("Quit Runbar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var lastSyncText: String {
        guard let lastSync = model.pollSchedulerSnapshot.lastSyncAt else { return "Last sync —" }
        return "Last sync \(WorkflowRunPresentation.relativeText(date: lastSync, now: model.menuBarNow))"
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func runLink(_ item: MenuBarRun) -> some View {
        if let url = URL(string: item.run.htmlURL) {
            Link(item.run.workflowName, destination: url)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        } else {
            Text(item.run.workflowName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func conclusionIcon(_ conclusion: String?) -> some View {
        if conclusion == "success" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if WorkflowRunPresentation.isFailure(conclusion) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.state {
        case .authenticated where model.pollSchedulerSnapshot.isRateLimitDegraded:
            Label("Degraded", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case let .authenticated(login):
            Label("@\(login)", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading, .validating:
            ProgressView().controlSize(.small)
        case .signedOut, .failed:
            Label("Setup required", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
