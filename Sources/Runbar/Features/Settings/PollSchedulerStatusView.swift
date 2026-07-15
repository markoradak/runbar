import SwiftUI

struct PollSchedulerStatusView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Polling scheduler") {
            if model.pollSchedulerSnapshot.isRateLimitDegraded {
                Label(
                    "Rate-limit protection is active; every poll interval is widened 4×.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if model.pollSchedulerSnapshot.isRunning {
                Label("Scheduler running", systemImage: "clock.badge.checkmark")
                    .foregroundStyle(.green)
            } else {
                Label("Scheduler waiting for an authenticated repository set", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                tierLabel(.hot, title: "Hot", interval: "8s")
                tierLabel(.warm, title: "Warm", interval: "60s")
                tierLabel(.cold, title: "Cold", interval: "10m")
                Spacer()
            }

            Text("Watching \(model.gitWatchedRepositoryCount) local repositories for loose and packed Git refs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Poll attempts: \(model.pollSchedulerSnapshot.totalPollAttempts)")
                Text("Quota-consuming: \(model.pollSchedulerSnapshot.quotaConsumingRequests)")
                Spacer()
                if let remaining = model.pollSchedulerSnapshot.rateLimit.remaining {
                    Text("Remaining: \(remaining)")
                }
            }
            .font(.caption.monospacedDigit())

            if let resetAt = model.pollSchedulerSnapshot.rateLimit.resetAt {
                Text("Rate limit resets \(resetAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Launch and wake reconciliation poll every included accessible repository through the explicit ETag client. Every regular interval receives independent ±15% jitter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tierLabel(_ tier: PollingTier, title: String, interval: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(model.pollSchedulerSnapshot.tierCounts[tier, default: 0])")
                .fontWeight(.medium)
            Text(interval)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
