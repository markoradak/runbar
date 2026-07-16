import XCTest
@testable import Runbar

final class MenuBarPresentationTests: XCTestCase {
    func testElapsedDurationAndRelativeTextUseOnlySuppliedLocalDates() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(WorkflowRunPresentation.elapsedSeconds(startedAt: start, now: start.addingTimeInterval(65)), 65)
        XCTAssertEqual(WorkflowRunPresentation.elapsedText(startedAt: start, now: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(WorkflowRunPresentation.elapsedText(startedAt: nil, now: start), "Queued")
        XCTAssertEqual(
            WorkflowRunPresentation.durationText(startedAt: start, completedAt: start.addingTimeInterval(3_661)),
            "1:01:01"
        )
        XCTAssertEqual(WorkflowRunPresentation.relativeText(date: start, now: start.addingTimeInterval(7_200)), "2h ago")
    }

    func testFiveIconStatesAndPriorityAreDeterministic() {
        let now = Date(timeIntervalSince1970: 100_000)
        let failure = menuRun(conclusion: "failure", updatedAt: now.addingTimeInterval(-60))

        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: false,
                isDegraded: true,
                runningCount: 3,
                recent: [failure]
            ),
            .authenticationRequired
        )
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: true,
                runningCount: 3,
                recent: [failure]
            ),
            .degraded
        )
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 3,
                recent: [failure]
            ),
            .running(count: 3)
        )
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 0,
                recent: [failure]
            ),
            .recentFailure
        )
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 0,
                recent: [menuRun(conclusion: "success", updatedAt: now)]
            ),
            .idle
        )
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 0,
                recent: [
                    menuRun(conclusion: "success", updatedAt: now),
                    menuRun(conclusion: "failure", updatedAt: now.addingTimeInterval(-60))
                ]
            ),
            .idle
        )
    }

    func testAcknowledgedFailureResolvesIdleUntilANewerFailureArrives() {
        let now = Date(timeIntervalSince1970: 100_000)
        let failure = menuRun(conclusion: "failure", updatedAt: now)

        // Acknowledging the newest failed run clears the badge.
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 0,
                recent: [failure],
                acknowledgedFailureRunID: failure.id
            ),
            .idle
        )
        // A different (newer) failed run re-triggers the badge.
        XCTAssertEqual(
            MenuBarIconState.resolve(
                isAuthenticated: true,
                isDegraded: false,
                runningCount: 0,
                recent: [failure],
                acknowledgedFailureRunID: failure.id + 1
            ),
            .recentFailure
        )
    }

    func testModernIconSymbolsAndStatusCopyAreUnambiguous() {
        XCTAssertEqual(MenuBarIconState.idle.systemImage, "circle.dashed")
        XCTAssertEqual(MenuBarIconState.idle.statusText, "All builds clear")
        XCTAssertEqual(MenuBarIconState.recentFailure.systemImage, "exclamationmark.circle.fill")
        XCTAssertEqual(MenuBarIconState.recentFailure.statusText, "Recent failure needs attention")
        XCTAssertEqual(MenuBarIconState.running(count: 1).statusText, "1 build running")
        XCTAssertEqual(MenuBarIconState.running(count: 2).statusText, "2 builds running")
    }

    func testActivityLoaderIsACompactTwoByThreeDotGrid() {
        XCTAssertEqual(MenuBarActivityIndicatorStyle.animationFrameCount, 6)
        XCTAssertLessThan(MenuBarActivityIndicatorStyle.width, MenuBarActivityIndicatorStyle.height)
        XCTAssertGreaterThan(MenuBarActivityIndicatorStyle.dotDiameter, 2)
        XCTAssertLessThan(MenuBarActivityIndicatorStyle.inactiveOpacity, MenuBarActivityIndicatorStyle.idleOpacity)
        XCTAssertLessThan(MenuBarActivityIndicatorStyle.idleOpacity, 1)
        XCTAssertLessThanOrEqual(MenuBarActivityIndicatorStyle.animationFramesPerSecond, 8)
    }

    func testProgressUsesNoHistoryEstimateAndHonestOverrunStates() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            WorkflowRunPresentation.progressState(
                startedAt: start,
                medianDurationSeconds: nil,
                now: start.addingTimeInterval(30)
            ),
            .noHistory
        )

        let estimated = WorkflowRunPresentation.progressState(
            startedAt: start,
            medianDurationSeconds: 100,
            now: start.addingTimeInterval(40)
        )
        XCTAssertEqual(estimated, .estimated(elapsedSeconds: 40, medianDurationSeconds: 100))
        XCTAssertEqual(estimated.fractionCompleted ?? -1, 0.4, accuracy: 0.0001)

        let overrun = WorkflowRunPresentation.progressState(
            startedAt: start,
            medianDurationSeconds: 100,
            now: start.addingTimeInterval(101)
        )
        XCTAssertEqual(overrun, .runningLong(elapsedSeconds: 101, medianDurationSeconds: 100))
        XCTAssertNil(overrun.fractionCompleted)
    }

    private func menuRun(conclusion: String?, updatedAt: Date) -> MenuBarRun {
        MenuBarRun(
            run: WorkflowRun(
                id: 1,
                repositoryKey: "owner/repo",
                workflowID: 2,
                workflowName: "CI",
                status: "completed",
                conclusion: conclusion,
                runStartedAt: updatedAt.addingTimeInterval(-30),
                createdAt: updatedAt.addingTimeInterval(-30),
                updatedAt: updatedAt,
                headBranch: "main",
                headSHA: "abc",
                event: "push",
                displayTitle: "CI",
                htmlURL: "https://github.com/owner/repo/actions/runs/1",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            ),
            repository: RepoIdentity(owner: "owner", name: "repo"),
            matchesLocalHEAD: false
        )
    }
}
