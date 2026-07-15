import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Runbar")
                    .font(.headline)
                Spacer()
                connectionBadge
            }

            Divider()

            if let login = model.authenticatedLogin {
                Label("Connected as @\(login)", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("menu-authenticated-github-login")
                schedulerSummary
            } else {
                Text("Add a fine-grained GitHub token in Settings to begin.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if let remaining = model.pollSchedulerSnapshot.rateLimit.remaining {
                    Text("Rate limit: \(remaining)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            model.pollSchedulerSnapshot.isRateLimitDegraded ? Color.orange : Color.secondary
                        )
                }
                Spacer()
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 340)
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var schedulerSummary: some View {
        if model.pollSchedulerSnapshot.isRateLimitDegraded {
            Label("Polling slowed to protect the GitHub rate limit", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if model.pollSchedulerSnapshot.isRunning {
            let counts = model.pollSchedulerSnapshot.tierCounts
            Text(
                "Polling \(model.pollSchedulerSnapshot.repositories.count) repos · " +
                "\(counts[.hot, default: 0]) hot · " +
                "\(counts[.warm, default: 0]) warm · " +
                "\(counts[.cold, default: 0]) cold"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Polling is waiting for repository discovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.state {
        case .authenticated where model.pollSchedulerSnapshot.isRateLimitDegraded:
            Label("Degraded", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .authenticated:
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading, .validating:
            ProgressView()
                .controlSize(.small)
        case .signedOut, .failed:
            Label("Setup required", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
