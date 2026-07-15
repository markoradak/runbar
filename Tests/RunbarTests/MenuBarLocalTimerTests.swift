import XCTest
@testable import Runbar

@MainActor
final class MenuBarLocalTimerTests: XCTestCase {
    func testVisibleActiveRunAdvancesFromLocalClockWithoutJobsOrNetwork() async throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let run = MenuBarRun(
            run: WorkflowRun(
                id: 77,
                repositoryKey: "owner/repo",
                workflowID: 88,
                workflowName: "Offline CI",
                status: "in_progress",
                conclusion: nil,
                runStartedAt: start,
                createdAt: start,
                updatedAt: start,
                headBranch: "main",
                headSHA: "abc",
                event: "push",
                displayTitle: "Offline CI",
                htmlURL: "https://github.com/owner/repo/actions/runs/77",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            ),
            repository: RepoIdentity(owner: "owner", name: "repo"),
            matchesLocalHEAD: true
        )
        let store = RecordingMenuBarStore(snapshot: .init(running: [run], recent: []))
        let clock = AdvancingMenuBarClock(now: start.addingTimeInterval(10))
        let credentialStore = EmptyTimerCredentialStore()
        let model = SettingsModel(
            credentialStore: credentialStore,
            authValidator: TimerAuthValidator(),
            menuBarStore: store,
            menuBarClock: clock
        )

        await model.refreshMenuBarRuns()
        model.menuBarDidAppear()
        for _ in 0..<200 {
            if await store.tickCount() >= 3 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        model.menuBarDidDisappear()

        let ticks = await store.recordedTicks()
        XCTAssertGreaterThanOrEqual(ticks.count, 2)
        XCTAssertEqual(Array(ticks.prefix(2).map(\.elapsedSeconds)), [10, 11])
        XCTAssertTrue(ticks.allSatisfy { $0.source == MenuBarTimerTick.localSource })
        XCTAssertEqual(credentialStore.readCount, 0)
    }
}

private actor RecordingMenuBarStore: MenuBarDataStoring {
    let snapshot: MenuBarRunSnapshot
    private var ticks: [MenuBarTimerTick] = []

    init(snapshot: MenuBarRunSnapshot) {
        self.snapshot = snapshot
    }

    func loadMenuBarRuns(recentLimit: Int) async throws -> MenuBarRunSnapshot { snapshot }
    func recordMenuBarTimerTick(_ tick: MenuBarTimerTick) async throws { ticks.append(tick) }
    func tickCount() -> Int { ticks.count }
    func recordedTicks() -> [MenuBarTimerTick] { ticks }
}

private actor AdvancingMenuBarClock: MenuBarClock {
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() async -> Date { current }

    func sleepForTick() async throws {
        try await Task.sleep(for: .milliseconds(2))
        current = current.addingTimeInterval(1)
    }
}

private final class EmptyTimerCredentialStore: CredentialStore {
    private(set) var readCount = 0
    func readToken() throws -> String? { readCount += 1; return nil }
    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private actor TimerAuthValidator: AuthValidating {
    func validate(token: String) async throws -> AuthenticatedUser {
        AuthenticatedUser(login: "unused")
    }
}
