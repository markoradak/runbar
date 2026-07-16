import SwiftUI

struct PollSchedulerStatusView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(
            "Polling scheduler",
            footer: "Watching \(model.gitWatchedRepositoryCount) local repositories for loose and packed Git refs. Launch and wake reconciliation poll every included accessible repository through the explicit ETag client. Every regular interval receives independent ±15% jitter."
        ) {
            HStack {
                Text("Scheduler status")
                    .font(.system(size: 12.5))
                Spacer()
                schedulerPill
            }

            HStack(spacing: 8) {
                tierTile(.hot, title: "hot", interval: "8s")
                tierTile(.warm, title: "warm", interval: "60s")
                tierTile(.cold, title: "cold", interval: "10m")
                statTile(
                    value: "\(model.gitWatchedRepositoryCount)",
                    label: "git watched"
                )
            }

            HStack(spacing: 14) {
                Text("attempts \(model.pollSchedulerSnapshot.totalPollAttempts)")
                Text("quota-consuming \(model.pollSchedulerSnapshot.quotaConsumingRequests)")
                Spacer()
                if let remaining = model.pollSchedulerSnapshot.rateLimit.remaining {
                    Text("remaining \(remaining)")
                        .foregroundStyle(
                            model.pollSchedulerSnapshot.isRateLimitDegraded ? .orange : .secondary
                        )
                }
            }
            .font(SettingsUI.mono(10.5))
            .foregroundStyle(.secondary)

            if let resetAt = model.pollSchedulerSnapshot.rateLimit.resetAt {
                Text("Rate limit resets \(resetAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var schedulerPill: some View {
        if model.pollSchedulerSnapshot.isRateLimitDegraded {
            SettingsStatusPill(text: "rate-limit protection · 4× intervals", color: .orange)
        } else if model.pollSchedulerSnapshot.isRunning {
            SettingsStatusPill(text: "running", color: .green)
        } else {
            SettingsStatusPill(text: "waiting for repositories", color: .secondary)
        }
    }

    private func tierTile(_ tier: PollingTier, title: String, interval: String) -> some View {
        statTile(
            value: "\(model.pollSchedulerSnapshot.tierCounts[tier, default: 0])",
            label: "\(title) · \(interval)"
        )
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SettingsUI.mono(15, .bold))
            Text(label)
                .font(SettingsUI.mono(9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
