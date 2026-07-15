import Foundation
import XCTest
@testable import Runbar

final class GitWatcherTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let shaA = String(repeating: "a", count: 40)
    private let shaB = String(repeating: "b", count: 40)
    private let shaC = String(repeating: "c", count: 40)
    private let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testLooseRemoteRefChangeStartsExactlyOnePollAndPersistsNewHeadSHA() async throws {
        let repository = try makeRepository(name: "loose", remoteSHA: shaA, headSHA: shaA)
        let poller = GitWatcherPollSpy(pollStartedAt: detectedAt.addingTimeInterval(0.4))
        let recorder = MemoryGitWatcherRecorder()
        let watcher = GitWatcher(
            eventSource: FinishedGitFileEventSource(),
            localPushPoller: poller,
            recorder: recorder
        )
        await watcher.configure(repositories: [.init(key: "owner/loose", localPath: repository.path)])

        try write("\(shaB)\n", to: repository.appendingPathComponent(".git/refs/remotes/origin/main"))
        try write("\(shaB)\n", to: repository.appendingPathComponent(".git/refs/heads/main"))
        await watcher.processFileEvents(repositoryKey: "owner/loose", detectedAt: detectedAt)
        await watcher.processFileEvents(repositoryKey: "owner/loose", detectedAt: detectedAt)

        let calls = await poller.repositoryKeys()
        let events = await recorder.events()
        let persistedSHA = await recorder.sha(repositoryKey: "owner/loose")
        XCTAssertEqual(calls, ["owner/loose"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].signal, .looseRemoteRef)
        XCTAssertEqual(events[0].referenceStorageBefore, .loose)
        XCTAssertEqual(events[0].latencyMilliseconds, 400)
        XCTAssertEqual(events[0].currentSHA, shaB)
        XCTAssertEqual(persistedSHA, shaB)
    }

    func testPackedRefsChangeStartsOnePollAndIsClassifiedSeparately() async throws {
        let repository = try makeRepository(name: "packed", remoteSHA: nil, headSHA: shaA)
        let packedRefs = repository.appendingPathComponent(".git/packed-refs")
        try write("\(shaA) refs/remotes/origin/main\n", to: packedRefs)
        let poller = GitWatcherPollSpy(pollStartedAt: detectedAt.addingTimeInterval(0.25))
        let recorder = MemoryGitWatcherRecorder()
        let watcher = GitWatcher(
            eventSource: FinishedGitFileEventSource(),
            localPushPoller: poller,
            recorder: recorder
        )
        await watcher.configure(repositories: [.init(key: "owner/packed", localPath: repository.path)])

        try write("\(shaB) refs/remotes/origin/main\n", to: packedRefs)
        await watcher.processFileEvents(repositoryKey: "owner/packed", detectedAt: detectedAt)

        let calls = await poller.repositoryKeys()
        let events = await recorder.events()
        XCTAssertEqual(calls, ["owner/packed"])
        XCTAssertEqual(events.map(\.signal), [.packedRefs])
        XCTAssertEqual(events.first?.referenceStorageBefore, .packed)
        XCTAssertEqual(events.first?.latencyMilliseconds, 250)
    }

    func testLooseAndPackedChangesInSameBurstStillStartOnePoll() async throws {
        let repository = try makeRepository(name: "combined", remoteSHA: shaA, headSHA: shaA)
        let packedRefs = repository.appendingPathComponent(".git/packed-refs")
        try write("\(shaA) refs/remotes/origin/release\n", to: packedRefs)
        let poller = GitWatcherPollSpy(pollStartedAt: detectedAt.addingTimeInterval(0.1))
        let recorder = MemoryGitWatcherRecorder()
        let watcher = GitWatcher(
            eventSource: FinishedGitFileEventSource(),
            localPushPoller: poller,
            recorder: recorder
        )
        await watcher.configure(repositories: [.init(key: "owner/combined", localPath: repository.path)])

        try write("\(shaB)\n", to: repository.appendingPathComponent(".git/refs/remotes/origin/main"))
        try write("\(shaC) refs/remotes/origin/release\n", to: packedRefs)
        await watcher.processFileEvents(repositoryKey: "owner/combined", detectedAt: detectedAt)

        let calls = await poller.repositoryKeys()
        let events = await recorder.events()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(events.map(\.signal), [.looseAndPacked])
        XCTAssertEqual(events.first?.referenceStorageBefore, .loose)
    }

    func testHeadOnlyChangePersistsSHAWithoutPolling() async throws {
        let repository = try makeRepository(name: "head", remoteSHA: shaA, headSHA: shaA)
        let poller = GitWatcherPollSpy(pollStartedAt: detectedAt)
        let recorder = MemoryGitWatcherRecorder()
        let watcher = GitWatcher(
            eventSource: FinishedGitFileEventSource(),
            localPushPoller: poller,
            recorder: recorder
        )
        await watcher.configure(repositories: [.init(key: "owner/head", localPath: repository.path)])

        try write("\(shaB)\n", to: repository.appendingPathComponent(".git/refs/heads/main"))
        await watcher.processFileEvents(repositoryKey: "owner/head", detectedAt: detectedAt)

        let calls = await poller.repositoryKeys()
        let events = await recorder.events()
        let persistedSHA = await recorder.sha(repositoryKey: "owner/head")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(persistedSHA, shaB)
    }

    private func makeRepository(name: String, remoteSHA: String?, headSHA: String) throws -> URL {
        let repository = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(headSHA)\n", to: git.appendingPathComponent("refs/heads/main"))
        if let remoteSHA {
            try write("\(remoteSHA)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))
        }
        return repository
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct FinishedGitFileEventSource: GitFileEventSourcing {
    func events(for _: [String]) -> AsyncStream<GitFileEventBatch> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor GitWatcherPollSpy: LocalPushPolling {
    private let pollStartedAt: Date?
    private var keys: [String] = []

    init(pollStartedAt: Date?) {
        self.pollStartedAt = pollStartedAt
    }

    func handleLocalPush(repositoryKey: String) async -> Date? {
        keys.append(repositoryKey)
        return pollStartedAt
    }

    func repositoryKeys() -> [String] {
        keys
    }
}

private actor MemoryGitWatcherRecorder: GitWatcherRecording {
    private var shas: [String: String] = [:]
    private var recordedEvents: [GitWatcherEvent] = []

    func updateCurrentSHA(_ sha: String?, repositoryKey: String) async throws {
        shas[repositoryKey] = sha
    }

    func recordGitWatcherEvent(_ event: GitWatcherEvent) async throws {
        recordedEvents.append(event)
    }

    func sha(repositoryKey: String) -> String? {
        shas[repositoryKey]
    }

    func events() -> [GitWatcherEvent] {
        recordedEvents
    }
}
