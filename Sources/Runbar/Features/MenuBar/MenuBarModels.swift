import Foundation

struct MenuBarRun: Identifiable, Equatable, Sendable {
    let run: WorkflowRun
    let repository: RepoIdentity
    let matchesLocalHEAD: Bool
    let medianDurationSeconds: Int?

    init(
        run: WorkflowRun,
        repository: RepoIdentity,
        matchesLocalHEAD: Bool,
        medianDurationSeconds: Int? = nil
    ) {
        self.run = run
        self.repository = repository
        self.matchesLocalHEAD = matchesLocalHEAD
        self.medianDurationSeconds = medianDurationSeconds
    }

    var id: Int64 { run.id }
}

struct MenuBarRunSnapshot: Equatable, Sendable {
    let running: [MenuBarRun]
    let recent: [MenuBarRun]

    static let empty = MenuBarRunSnapshot(running: [], recent: [])
}

struct MenuBarTimerTick: Equatable, Sendable {
    let timestamp: Date
    let runID: Int64
    let elapsedSeconds: Int
    let source: String

    static let localSource = "local_monotonic_timer"
}

protocol MenuBarDataStoring: Sendable {
    func loadMenuBarRuns(recentLimit: Int) async throws -> MenuBarRunSnapshot
    func recordMenuBarTimerTick(_ tick: MenuBarTimerTick) async throws
}

protocol MenuBarClock: Sendable {
    func now() async -> Date
    func sleepForTick() async throws
}

struct SystemMenuBarClock: MenuBarClock {
    func now() async -> Date { Date() }

    func sleepForTick() async throws {
        try await Task.sleep(for: .seconds(1))
    }
}

enum MenuBarIconState: Equatable, Sendable {
    case running(count: Int)
    case idle
    case recentFailure
    case degraded
    case authenticationRequired

    var systemImage: String {
        switch self {
        case .running: "bolt.circle.fill"
        case .idle: "circle.dashed"
        case .recentFailure: "exclamationmark.circle.fill"
        case .degraded: "wifi.exclamationmark"
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        }
    }

    var statusText: String {
        switch self {
        case let .running(count): String(count) + " build" + (count == 1 ? "" : "s") + " running"
        case .idle: "All builds clear"
        case .recentFailure: "Recent failure needs attention"
        case .degraded: "Polling slowed to protect rate limit"
        case .authenticationRequired: "Provider setup required"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .running(count): "Runbar, \(count) running"
        case .idle: "Runbar, idle"
        case .recentFailure: "Runbar, recent failure"
        case .degraded: "Runbar, polling degraded"
        case .authenticationRequired: "Runbar, authentication required"
        }
    }

    static func resolve(
        isAuthenticated: Bool,
        isDegraded: Bool,
        runningCount: Int,
        recent: [MenuBarRun],
        acknowledgedFailureRunID: Int64? = nil
    ) -> MenuBarIconState {
        guard isAuthenticated else { return .authenticationRequired }
        if isDegraded { return .degraded }
        if runningCount > 0 { return .running(count: runningCount) }

        if let newestCompletedRun = recent.first,
           WorkflowRunPresentation.isFailure(newestCompletedRun.run.conclusion),
           newestCompletedRun.id != acknowledgedFailureRunID {
            return .recentFailure
        }
        return .idle
    }
}

enum WorkflowRunPresentation {
    enum ProgressState: Equatable, Sendable {
        case noHistory
        case estimated(elapsedSeconds: Int, medianDurationSeconds: Int)
        case runningLong(elapsedSeconds: Int, medianDurationSeconds: Int)

        var fractionCompleted: Double? {
            guard case let .estimated(elapsedSeconds, medianDurationSeconds) = self else { return nil }
            return Double(elapsedSeconds) / Double(medianDurationSeconds)
        }
    }
    static func elapsedSeconds(startedAt: Date?, now: Date) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    static func elapsedText(startedAt: Date?, now: Date) -> String {
        guard let seconds = elapsedSeconds(startedAt: startedAt, now: now) else { return "Queued" }
        return durationText(seconds: seconds)
    }

    static func durationText(startedAt: Date?, completedAt: Date?) -> String {
        guard let startedAt, let completedAt else { return "—" }
        return durationText(seconds: max(0, Int(completedAt.timeIntervalSince(startedAt))))
    }

    static func durationText(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func relativeText(date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<60: return "now"
        case 60..<3_600: return "\(seconds / 60)m ago"
        case 3_600..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    static func progressState(
        startedAt: Date?,
        medianDurationSeconds: Int?,
        now: Date
    ) -> ProgressState {
        guard let elapsed = elapsedSeconds(startedAt: startedAt, now: now),
              let medianDurationSeconds,
              medianDurationSeconds > 0
        else { return .noHistory }
        if elapsed > medianDurationSeconds {
            return .runningLong(
                elapsedSeconds: elapsed,
                medianDurationSeconds: medianDurationSeconds
            )
        }
        return .estimated(
            elapsedSeconds: elapsed,
            medianDurationSeconds: medianDurationSeconds
        )
    }

    static func isFailure(_ conclusion: String?) -> Bool {
        guard let conclusion else { return false }
        return ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"]
            .contains(conclusion)
    }
}

enum MenuBarActivityIndicatorStyle {
    static let width: CGFloat = 10
    static let height: CGFloat = 13
    static let dotDiameter: CGFloat = 2.3
    static let columnSpacing: CGFloat = 2.2
    static let rowSpacing: CGFloat = 1.3
    static let idleOpacity: CGFloat = 0.58
    static let inactiveOpacity: CGFloat = 0.18
    static let animationFramesPerSecond: Double = 8
    static let animationFrameCount = 6

    /// Dot indices in the order the highlight travels the 2×3 grid.
    /// Dots are indexed column-major: 0–2 = left column top→bottom, 3–5 = right.
    static let animationOrder = [0, 1, 3, 5, 4, 2]

    /// A comet trail fading back from the leading dot: index 0 is the leader,
    /// each following entry is the dot one step further behind along the travel
    /// order. Dots beyond the trail sit at `inactiveOpacity`.
    private static let trailOpacities: [CGFloat] = [1.0, 0.62, 0.40, 0.26]

    /// Per-dot opacity for a given animation step. `activeStep == nil` means the
    /// indicator is at rest (every dot at `idleOpacity`). The single source of
    /// truth shared by the menu-bar icon and the popover header tile.
    static func dotOpacity(index: Int, activeStep: Int?) -> CGFloat {
        guard let activeStep else { return idleOpacity }
        let count = animationOrder.count
        guard let orderIndex = animationOrder.firstIndex(of: index) else { return inactiveOpacity }
        // How many steps this dot sits behind the leader, wrapping the cycle.
        let distanceBehind = (activeStep - orderIndex + count) % count
        return distanceBehind < trailOpacities.count ? trailOpacities[distanceBehind] : inactiveOpacity
    }
}
