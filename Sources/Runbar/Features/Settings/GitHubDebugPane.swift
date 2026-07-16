import SwiftUI

struct GitHubDebugPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(
            "GitHub ETag debug",
            footer: "Runs one warm request plus ten measured requests against one unchanged repository. Only sanitized request metadata is retained; authorization and bodies are never recorded."
        ) {
            HStack(spacing: 10) {
                Picker("Repository", selection: $model.verificationRepositoryKey) {
                    ForEach(model.verificationRepositories) { repository in
                        Text(repository.identity.fullName).tag(repository.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Run 10-poll check") {
                    Task { await model.runETagVerification() }
                }
                .disabled(
                    model.isRunningETagVerification ||
                    model.verificationRepositoryKey.isEmpty ||
                    model.authenticatedLogin == nil
                )
            }

            verificationStatus

            if let notice = model.repositoryAccessNotice {
                Label(notice, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.githubDebugEntries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.githubDebugEntries.enumerated()), id: \.offset) { index, entry in
                            debugRow(index: index, entry: entry)
                        }
                    }
                }
                .frame(minHeight: 130, maxHeight: 210)
            }
        }
    }

    @ViewBuilder
    private var verificationStatus: some View {
        switch model.etagVerificationState {
        case .idle:
            EmptyView()
        case let .running(completedRequests):
            HStack {
                ProgressView().controlSize(.small)
                Text("Completed \(completedRequests) of 11 requests…")
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            HStack {
                Text("Last ten requests were 304 with a non-decreasing remaining limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsStatusPill(text: "verified", color: .green)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func debugRow(index: Int, entry: GitHubDebugEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                Text("HTTP \(entry.statusCode.map(String.init) ?? "transport")")
                Text(entry.cacheOutcome.rawValue)
                Text("remaining \(entry.rateLimit.remaining.map(String.init) ?? "—")")
                if let resetAt = entry.rateLimit.resetAt {
                    Text("reset \(resetAt.formatted(date: .omitted, time: .shortened))")
                }
                if let error = entry.errorCategory {
                    Text(error.rawValue).foregroundStyle(.red)
                }
            }
            .font(.caption.monospaced())
            Text(entry.sanitizedURL)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
