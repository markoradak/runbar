import Foundation
import XCTest
@testable import Runbar

final class GitMetadataResolverTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let shaA = String(repeating: "a", count: 40)
    private let shaB = String(repeating: "b", count: 40)

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testOrdinaryRepositoryResolvesBothRemoteRefLocationsAndCurrentSHA() throws {
        let repository = temporaryDirectory.appendingPathComponent("ordinary", isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(shaA)\n", to: git.appendingPathComponent("refs/heads/main"))
        try write("\(shaB)\n", to: git.appendingPathComponent("refs/remotes/origin/main"))
        try write("# pack-refs with: peeled\n", to: git.appendingPathComponent("packed-refs"))

        let resolver = GitMetadataResolver()
        let metadata = try resolver.resolve(repositoryPath: repository.path)
        let snapshot = try resolver.snapshot(metadata: metadata)

        XCTAssertEqual(metadata.gitDirectoryPath, git.path)
        XCTAssertEqual(metadata.commonGitDirectoryPath, git.path)
        XCTAssertEqual(metadata.looseRemoteRefsPath, git.appendingPathComponent("refs/remotes/origin").path)
        XCTAssertEqual(metadata.packedRefsPath, git.appendingPathComponent("packed-refs").path)
        XCTAssertEqual(metadata.headReferencePath, git.appendingPathComponent("refs/heads/main").path)
        XCTAssertTrue(metadata.watchRootPaths.contains(git.path))
        XCTAssertTrue(metadata.watchRootPaths.contains(metadata.looseRemoteRefsPath))
        XCTAssertEqual(snapshot.currentSHA, shaA)
        XCTAssertTrue(snapshot.looseRemoteRefsFingerprint.contains(shaB))
        XCTAssertNotNil(snapshot.packedRefsFingerprint)
    }

    func testWorktreeResolvesPerWorktreeHeadAndCommonRefs() throws {
        let common = temporaryDirectory.appendingPathComponent("common.git", isDirectory: true)
        let worktreeGit = common.appendingPathComponent("worktrees/feature", isDirectory: true)
        try write("../..\n", to: worktreeGit.appendingPathComponent("commondir"))
        try write("ref: refs/heads/feature\n", to: worktreeGit.appendingPathComponent("HEAD"))
        try write("\(shaA)\n", to: common.appendingPathComponent("refs/heads/feature"))
        try write("\(shaB) refs/remotes/origin/feature\n", to: common.appendingPathComponent("packed-refs"))

        let checkout = temporaryDirectory.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)\n".write(
            to: checkout.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = GitMetadataResolver()
        let metadata = try resolver.resolve(repositoryPath: checkout.path)
        let snapshot = try resolver.snapshot(metadata: metadata)

        XCTAssertEqual(metadata.gitDirectoryPath, worktreeGit.path)
        XCTAssertEqual(metadata.commonGitDirectoryPath, common.path)
        XCTAssertEqual(metadata.headPath, worktreeGit.appendingPathComponent("HEAD").path)
        XCTAssertEqual(metadata.headReferencePath, common.appendingPathComponent("refs/heads/feature").path)
        XCTAssertTrue(metadata.watchRootPaths.contains(common.path))
        XCTAssertTrue(metadata.watchRootPaths.contains(worktreeGit.path))
        XCTAssertEqual(snapshot.currentSHA, shaA)
    }

    func testCurrentSHAFallsBackToPackedHeadReference() throws {
        let repository = temporaryDirectory.appendingPathComponent("packed-head", isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
        try write("\(shaB) refs/heads/main\n", to: git.appendingPathComponent("packed-refs"))

        let resolver = GitMetadataResolver()
        let metadata = try resolver.resolve(repositoryPath: repository.path)

        XCTAssertEqual(try resolver.currentSHA(metadata: metadata), shaB)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
