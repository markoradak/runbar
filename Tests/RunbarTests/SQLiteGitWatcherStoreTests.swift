import Foundation
import XCTest
@testable import Runbar

final class SQLiteGitWatcherStoreTests: XCTestCase {
    func testCurrentSHAAndBoundedTimingEvidencePersistAcrossRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path
        let identity = RepoIdentity(owner: "owner", name: "repo")

        let discoveryStore = try SQLiteStore(path: path)
        try await discoveryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(
                codeRootPath: directory.path,
                repositories: [
                    DiscoveredRepository(
                        identity: identity,
                        source: .local,
                        localPath: directory.path,
                        pushedAt: nil,
                        workflows: [],
                        isExcluded: false,
                        isAccessible: true
                    )
                ],
                skippedLocalRepositories: []
            )
        )

        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sha = String(repeating: "a", count: 40)
        let first = try SQLiteGitWatcherStore(path: path)
        try await first.updateCurrentSHA(sha, repositoryKey: identity.normalizedKey)
        try await first.recordGitWatcherEvent(
            GitWatcherEvent(
                repositoryKey: identity.normalizedKey,
                signal: .packedRefs,
                referenceStorageBefore: .packed,
                detectedAt: detectedAt,
                pollStartedAt: detectedAt.addingTimeInterval(0.321),
                currentSHA: sha
            )
        )

        let reopened = try SQLiteGitWatcherStore(path: path)
        let persistedSHA = try await reopened.currentSHA(repositoryKey: identity.normalizedKey)
        let entries = try await reopened.debugEntries()
        XCTAssertEqual(persistedSHA, sha)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].signal, .packedRefs)
        XCTAssertEqual(entries[0].referenceStorageBefore, .packed)
        XCTAssertEqual(entries[0].latencyMilliseconds, 321)
        XCTAssertEqual(entries[0].currentSHA, sha)
    }
}
