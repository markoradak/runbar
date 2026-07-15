import Foundation
import XCTest
@testable import Runbar

final class GitWatcherReconfigurationTests: XCTestCase {
    func testDiscoveryReconfigurationCannotSwallowPendingPushRefChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherReconfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(shaA)\n", to: git.appendingPathComponent("refs/heads/main"))
        try write("\(shaA)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))

        let repository = GitWatchRepository(key: "owner/repo", localPath: directory.path)
        let poller = ReconfigurationPollSpy()
        let recorder = ReconfigurationRecorder()
        let watcher = GitWatcher(
            eventSource: ReconfigurationFinishedEventSource(),
            localPushPoller: poller,
            recorder: recorder
        )
        await watcher.configure(repositories: [repository])

        try write("\(shaB)\n", to: git.appendingPathComponent("refs/heads/main"))
        try write("\(shaB)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))
        await watcher.configure(repositories: [repository])
        await watcher.processFileEvents(repositoryKey: repository.key)

        let callCount = await poller.callCount()
        XCTAssertEqual(callCount, 1)
        let events = await recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.signal, .looseRemoteRef)
        XCTAssertEqual(events.first?.currentSHA, shaB)
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

private struct ReconfigurationFinishedEventSource: GitFileEventSourcing {
    func events(for _: [String]) -> AsyncStream<GitFileEventBatch> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor ReconfigurationPollSpy: LocalPushPolling {
    private var calls = 0

    func handleLocalPush(repositoryKey _: String) async -> Date? {
        calls += 1
        return Date()
    }

    func callCount() -> Int { calls }
}

private actor ReconfigurationRecorder: GitWatcherRecording {
    private var recordedEvents: [GitWatcherEvent] = []

    func updateCurrentSHA(_: String?, repositoryKey _: String) async throws {}

    func recordGitWatcherEvent(_ event: GitWatcherEvent) async throws {
        recordedEvents.append(event)
    }

    func events() -> [GitWatcherEvent] { recordedEvents }
}
