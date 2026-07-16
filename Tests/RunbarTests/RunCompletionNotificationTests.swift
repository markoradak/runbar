import XCTest
@testable import Runbar

@MainActor
final class RunCompletionNotificationTests: XCTestCase {
    func testInitialCompletedRunsAreBaselineAndNewCompletionCarriesConclusionAndURL() async throws {
        let old = completedRun(id: 1, conclusion: "success")
        let completed = completedRun(id: 2, conclusion: "success")
        let store = SequenceNotificationMenuStore(
            snapshots: [
                .init(running: [], recent: [old]),
                .init(running: [], recent: [completed, old])
            ]
        )
        let notifier = RecordingRunCompletionNotifier()
        let model = notificationModel(store: store, notifier: notifier, failuresOnly: false)

        await model.refreshMenuBarRuns()
        await model.requestNotificationAuthorization()
        let baselineDeliveries = await notifier.deliveries()
        XCTAssertEqual(baselineDeliveries, [])

        await model.refreshMenuBarRuns()

        let deliveries = await notifier.deliveries()
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.runID, 2)
        XCTAssertEqual(deliveries.first?.conclusion, "success")
        XCTAssertEqual(deliveries.first?.conclusionText, "Success")
        XCTAssertEqual(deliveries.first?.htmlURL, completed.run.htmlURL)
        XCTAssertEqual(model.notificationAuthorizationState, .authorized)
    }

    func testFailuresOnlyFiltersSuccessAndPersistsPreference() async {
        let success = completedRun(id: 3, conclusion: "success")
        let failure = completedRun(id: 4, conclusion: "timed_out")
        let store = SequenceNotificationMenuStore(
            snapshots: [
                .empty,
                .init(running: [], recent: [failure, success])
            ]
        )
        let notifier = RecordingRunCompletionNotifier()
        let preferences = MemoryNotificationPreferenceStore(failuresOnly: true)
        let model = notificationModel(
            store: store,
            notifier: notifier,
            failuresOnly: true,
            preferences: preferences
        )

        await model.refreshMenuBarRuns()
        await model.requestNotificationAuthorization()
        await model.refreshMenuBarRuns()

        let deliveries = await notifier.deliveries()
        XCTAssertEqual(deliveries.map(\.runID), [4])
        XCTAssertTrue(deliveries[0].isFailure)
        model.setNotificationsFailuresOnly(false)
        XCTAssertFalse(model.notificationsFailuresOnly)
        XCTAssertFalse(preferences.failuresOnly())
    }

    func testMutedRepositorySkipsDeliveryAndPersistsPreference() async {
        let completed = completedRun(id: 5, conclusion: "failure")
        let store = SequenceNotificationMenuStore(
            snapshots: [
                .empty,
                .init(running: [], recent: [completed])
            ]
        )
        let notifier = RecordingRunCompletionNotifier()
        let preferences = MemoryNotificationPreferenceStore(failuresOnly: false, muted: ["owner/repo"])
        let model = notificationModel(
            store: store,
            notifier: notifier,
            failuresOnly: false,
            preferences: preferences
        )

        await model.refreshMenuBarRuns()
        await model.requestNotificationAuthorization()
        await model.refreshMenuBarRuns()

        let deliveries = await notifier.deliveries()
        XCTAssertEqual(deliveries, [])
        XCTAssertTrue(model.isNotificationsMuted(forRepositoryKey: "owner/repo"))

        model.setNotificationsMuted(false, forRepositoryKey: "owner/repo")
        XCTAssertFalse(model.isNotificationsMuted(forRepositoryKey: "owner/repo"))
        XCTAssertEqual(preferences.mutedRepositoryKeys(), [])
    }

    private func notificationModel(
        store: SequenceNotificationMenuStore,
        notifier: RecordingRunCompletionNotifier,
        failuresOnly: Bool,
        preferences: MemoryNotificationPreferenceStore? = nil
    ) -> SettingsModel {
        SettingsModel(
            credentialStore: EmptyNotificationCredentialStore(),
            authValidator: NotificationAuthValidator(),
            menuBarStore: store,
            notificationNotifier: notifier,
            notificationPreferenceStore: preferences ?? MemoryNotificationPreferenceStore(failuresOnly: failuresOnly)
        )
    }

    private func completedRun(id: Int64, conclusion: String) -> MenuBarRun {
        let completedAt = Date(timeIntervalSince1970: 10_000 + Double(id))
        return MenuBarRun(
            run: WorkflowRun(
                id: id,
                repositoryKey: "owner/repo",
                workflowID: 77,
                workflowName: "CI",
                status: "completed",
                conclusion: conclusion,
                runStartedAt: completedAt.addingTimeInterval(-60),
                createdAt: completedAt.addingTimeInterval(-60),
                updatedAt: completedAt,
                headBranch: "main",
                headSHA: "sha-\(id)",
                event: "push",
                displayTitle: "CI",
                htmlURL: "https://github.com/owner/repo/actions/runs/\(id)",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            ),
            repository: RepoIdentity(owner: "owner", name: "repo"),
            matchesLocalHEAD: false
        )
    }
}

private actor SequenceNotificationMenuStore: MenuBarDataStoring {
    private var snapshots: [MenuBarRunSnapshot]

    init(snapshots: [MenuBarRunSnapshot]) {
        self.snapshots = snapshots
    }

    func loadMenuBarRuns(recentLimit: Int) async throws -> MenuBarRunSnapshot {
        guard snapshots.count > 1 else { return snapshots.first ?? .empty }
        return snapshots.removeFirst()
    }

    func recordMenuBarTimerTick(_ tick: MenuBarTimerTick) async throws {}
}

private actor RecordingRunCompletionNotifier: RunCompletionNotifying {
    private var delivered: [RunCompletionNotification] = []

    func authorizationState() async -> RunNotificationAuthorizationState { .authorized }
    func requestAuthorization() async -> RunNotificationAuthorizationState { .authorized }
    func deliver(_ notification: RunCompletionNotification) async throws { delivered.append(notification) }
    func deliveries() -> [RunCompletionNotification] { delivered }
}

private final class MemoryNotificationPreferenceStore: NotificationPreferenceStoring, @unchecked Sendable {
    private var value: Bool
    private var muted: Set<String>

    init(failuresOnly: Bool, muted: Set<String> = []) {
        value = failuresOnly
        self.muted = muted
    }

    func failuresOnly() -> Bool { value }
    func setFailuresOnly(_ failuresOnly: Bool) { value = failuresOnly }
    func mutedRepositoryKeys() -> Set<String> { muted }
    func setMutedRepositoryKeys(_ keys: Set<String>) { muted = keys }
}

private final class EmptyNotificationCredentialStore: CredentialStore {
    func readToken() throws -> String? { nil }
    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private actor NotificationAuthValidator: AuthValidating {
    func validate(token: String) async throws -> AuthenticatedUser {
        AuthenticatedUser(login: "unused")
    }
}
