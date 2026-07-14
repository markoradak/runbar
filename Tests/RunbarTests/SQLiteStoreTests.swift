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
}
