import Foundation
import XCTest
@testable import Runbar

final class SQLiteStoreTests: XCTestCase {
    func testCodeRootExclusionAndAccessibilityPersistAcrossStoreRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path

        let first = try SQLiteStore(path: path)
        try await first.setCodeRootPath("/real/code")
        try await first.setExcluded(true, repositoryKey: "owner/repo")
        try await first.setAccessible(false, repositoryKey: "owner/repo")

        let reopened = try SQLiteStore(path: path)
        let rootPath = try await reopened.codeRootPath()
        let preferences = try await reopened.repositoryPreferences()

        XCTAssertEqual(rootPath, "/real/code")
        XCTAssertEqual(
            preferences["owner/repo"],
            RepositoryPreference(isExcluded: true, isAccessible: false)
        )
    }

    func testDenialBackoffStateEscalatesAndClearsOnRestore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path

        let githubStore = try SQLiteGitHubStore(path: path)
        let discoveryStore = try SQLiteStore(path: path)
        let firstDenial = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDenial = firstDenial.addingTimeInterval(60 * 60)

        let firstNotice = try await githubStore.markRepositoryInaccessible(
            "owner/repo", deniedAt: firstDenial
        )
        let repeatNotice = try await githubStore.markRepositoryInaccessible(
            "owner/repo", deniedAt: secondDenial
        )
        XCTAssertTrue(firstNotice)
        XCTAssertFalse(repeatNotice, "A repeat denial must not re-trigger the first-notice message")

        let denied = try await discoveryStore.repositoryPreferences()["owner/repo"]
        XCTAssertEqual(
            denied,
            RepositoryPreference(
                isExcluded: false,
                isAccessible: false,
                accessDeniedAt: secondDenial,
                accessDenialCount: 2
            ),
            "Repeat denials re-stamp the timestamp and grow the counter"
        )

        try await githubStore.setRepositoryAccessible(true, repositoryKey: "owner/repo")
        let restored = try await discoveryStore.repositoryPreferences()["owner/repo"]
        XCTAssertEqual(
            restored,
            RepositoryPreference(isExcluded: false, isAccessible: true),
            "Restoring access clears the backoff state"
        )
    }

    func testDiscoveryStoreSetAccessibleClearsBackoffState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path

        let githubStore = try SQLiteGitHubStore(path: path)
        let discoveryStore = try SQLiteStore(path: path)
        _ = try await githubStore.markRepositoryInaccessible(
            "owner/repo", deniedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await discoveryStore.setAccessible(true, repositoryKey: "owner/repo")

        let restored = try await discoveryStore.repositoryPreferences()["owner/repo"]
        XCTAssertEqual(restored, RepositoryPreference(isExcluded: false, isAccessible: true))
        let accessible = try await githubStore.isRepositoryAccessible("owner/repo")
        XCTAssertTrue(accessible)
    }
}
