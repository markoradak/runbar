import AppKit
import Foundation
@preconcurrency import UserNotifications

enum RunNotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct RunCompletionNotification: Equatable, Sendable {
    let runID: Int64
    let runAttempt: Int
    let workflowName: String
    let repositoryName: String
    let conclusion: String
    let htmlURL: String

    init?(run: MenuBarRun) {
        guard run.run.status == "completed", let conclusion = run.run.conclusion else { return nil }
        runID = run.id
        runAttempt = run.run.runAttempt
        workflowName = run.run.workflowName
        repositoryName = run.repository.fullName
        self.conclusion = conclusion
        htmlURL = run.run.htmlURL
    }

    var isFailure: Bool {
        WorkflowRunPresentation.isFailure(conclusion)
    }

    var conclusionText: String {
        conclusion.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

protocol RunCompletionNotifying: Sendable {
    func authorizationState() async -> RunNotificationAuthorizationState
    func requestAuthorization() async -> RunNotificationAuthorizationState
    func deliver(_ notification: RunCompletionNotification) async throws
}

protocol NotificationPreferenceStoring: Sendable {
    func failuresOnly() -> Bool
    func setFailuresOnly(_ failuresOnly: Bool)
    func mutedRepositoryKeys() -> Set<String>
    func setMutedRepositoryKeys(_ keys: Set<String>)
}

final class UserDefaultsNotificationPreferenceStore: NotificationPreferenceStoring, @unchecked Sendable {
    private static let failuresOnlyKey = "notifications.failuresOnly"
    private static let mutedRepositoriesKey = "notifications.mutedRepositories"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func failuresOnly() -> Bool {
        defaults.bool(forKey: Self.failuresOnlyKey)
    }

    func setFailuresOnly(_ failuresOnly: Bool) {
        defaults.set(failuresOnly, forKey: Self.failuresOnlyKey)
    }

    func mutedRepositoryKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.mutedRepositoriesKey) ?? [])
    }

    func setMutedRepositoryKeys(_ keys: Set<String>) {
        defaults.set(keys.sorted(), forKey: Self.mutedRepositoriesKey)
    }
}

final class SystemRunCompletionNotifier: NSObject, RunCompletionNotifying, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationState() async -> RunNotificationAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.authorizationState(settings.authorizationStatus)
    }

    func requestAuthorization() async -> RunNotificationAuthorizationState {
        let current = await authorizationState()
        guard current == .notDetermined else { return current }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func deliver(_ notification: RunCompletionNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.workflowName
        content.subtitle = notification.repositoryName
        content.body = "Conclusion: \(notification.conclusionText)"
        content.sound = .default
        content.userInfo = ["html_url": notification.htmlURL]
        let request = UNNotificationRequest(
            identifier: "workflow-run-\(notification.runID)-attempt-\(notification.runAttempt)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    private static func authorizationState(_ status: UNAuthorizationStatus) -> RunNotificationAuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}

extension SystemRunCompletionNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let value = response.notification.request.content.userInfo["html_url"] as? String,
              let url = URL(string: value)
        else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }
}
