import Foundation
import XCTest
@testable import Runbar

final class GitReferenceStorageTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let sha = String(repeating: "a", count: 40)

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitReferenceStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSymbolicLooseOriginHeadDoesNotHidePackedBranchStorage() throws {
        let git = try makeRepository()
        try write("ref: refs/remotes/origin/main\n", to: git.appendingPathComponent("refs/remotes/origin/HEAD"))
        try write("\(sha) refs/remotes/origin/main\n", to: git.appendingPathComponent("packed-refs"))

        let snapshot = try snapshot()

        XCTAssertFalse(snapshot.hasLooseRemoteReference)
        XCTAssertEqual(snapshot.referenceStorage, .packed)
    }

    func testDirectLooseRemoteBranchTakesPrecedenceOverPackedStorage() throws {
        let git = try makeRepository()
        try write("ref: refs/remotes/origin/main\n", to: git.appendingPathComponent("refs/remotes/origin/HEAD"))
        try write("\(sha)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))
        try write("\(sha) refs/remotes/origin/main\n", to: git.appendingPathComponent("packed-refs"))

        let snapshot = try snapshot()

        XCTAssertTrue(snapshot.hasLooseRemoteReference)
        XCTAssertEqual(snapshot.referenceStorage, .loose)
    }

    private func makeRepository() throws -> URL {
        let repository = temporaryDirectory.appendingPathComponent("repository", isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(sha)\n", to: git.appendingPathComponent("refs/heads/main"))
        return git
    }

    private func snapshot() throws -> GitWatchSnapshot {
        let resolver = GitMetadataResolver()
        let repository = temporaryDirectory.appendingPathComponent("repository", isDirectory: true)
        return try resolver.snapshot(metadata: resolver.resolve(repositoryPath: repository.path))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
