import Foundation
import XCTest
@testable import Runbar

final class GitWatcherLifecycleTests: XCTestCase {
    func testExcludedRepositoryIsRemovedAndCannotTriggerAnotherPoll() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherLifecycleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(shaA)\n", to: git.appendingPathComponent("refs/heads/main"))
        try write("\(shaA)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))

        let repository = GitWatchRepository(key: "owner/repo", localPath: directory.path)
        let poller = LifecyclePollSpy()
        let watcher = GitWatcher(
            eventSource: LifecycleFinishedEventSource(),
            localPushPoller: poller,
            recorder: LifecycleRecorder()
        )
        await watcher.configure(repositories: [repository])
        let countBeforeExclusion = await watcher.watchedRepositoryCount()
        await watcher.configure(repositories: [])
        let countAfterExclusion = await watcher.watchedRepositoryCount()

        try write("\(shaB)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))
        await watcher.processFileEvents(repositoryKey: repository.key)

        let pollCount = await poller.callCount()
        XCTAssertEqual(countBeforeExclusion, 1)
        XCTAssertEqual(countAfterExclusion, 0)
        XCTAssertEqual(pollCount, 0)
        await watcher.stop()
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct LifecycleFinishedEventSource: GitFileEventSourcing {
    func events(for _: [String]) -> AsyncStream<GitFileEventBatch> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor LifecyclePollSpy: LocalPushPolling {
    private var calls = 0

    func handleLocalPush(repositoryKey _: String) async -> Date? {
        calls += 1
        return Date()
    }

    func callCount() -> Int { calls }
}

private actor LifecycleRecorder: GitWatcherRecording {
    func updateCurrentSHA(_: String?, repositoryKey _: String) async throws {}
    func recordGitWatcherEvent(_: GitWatcherEvent) async throws {}
}
