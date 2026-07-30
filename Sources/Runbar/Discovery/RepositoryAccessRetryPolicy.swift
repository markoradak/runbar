import Foundation

/// Decides when a repository that GitHub denied (403/404) deserves another
/// access probe without the user pressing Retry.
///
/// Denials escalate through a capped backoff: the first denial re-probes after
/// one hour, the second after six, and every one after that daily. A repository
/// that reappears in the GitHub App installation list bypasses this entirely —
/// discovery restores it immediately, so the schedule only governs repositories
/// the installation feed cannot vouch for.
enum RepositoryAccessRetryPolicy {
    static let retryIntervals: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    static func nextRetryAt(deniedAt: Date, denialCount: Int) -> Date {
        let index = max(0, min(denialCount - 1, retryIntervals.count - 1))
        return deniedAt.addingTimeInterval(retryIntervals[index])
    }

    static func isRetryDue(preference: RepositoryPreference, now: Date) -> Bool {
        guard !preference.isAccessible else { return false }
        // Rows denied before the backoff columns existed have no timestamp;
        // probe those immediately so they enter the schedule.
        guard let deniedAt = preference.accessDeniedAt else { return true }
        return now >= nextRetryAt(deniedAt: deniedAt, denialCount: preference.accessDenialCount)
    }
}
