import Foundation
import XCTest
@testable import Runbar

final class LocalRepoScannerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarLocalScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDepthFourIncludedAndDepthFiveAndPrunedFoldersIgnored() throws {
        try makeRepository(at: "one/two/three/four", ownerRepo: "depth/four")
        try makeRepository(at: "one/two/three/four/five", ownerRepo: "depth/five")
        for skippedName in LocalRepoScanner.skippedDirectoryNames {
            try makeRepository(at: "\(skippedName)/nested", ownerRepo: "skip/\(skippedName.replacingOccurrences(of: ".", with: "dot"))")
        }

        let result = try LocalRepoScanner().scan(codeRoot: temporaryDirectory)

        XCTAssertEqual(result.repositories.map(\.identity.fullName), ["depth/four"])
    }

    func testIncludesProviderOnlyRepositoriesAndParsesYMLAndYAMLWorkflows() throws {
        try makeRepository(
            at: "qualifying",
            ownerRepo: "owner/qualifying",
            workflows: [
                "ci.yml": "name: CI\non: [push, pull_request]\n",
                "nightly.yaml": "name: Nightly\non:\n  schedule:\n    - cron: '0 0 * * *'\n",
                "notes.txt": "not a workflow"
            ]
        )
        try makeRepository(at: "github-only", ownerRepo: "owner/github-only", workflows: [:])
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("github-only/.github/ISSUE_TEMPLATE", isDirectory: true),
            withIntermediateDirectories: true
        )
        try makeRepository(
            at: "wrong-extension",
            ownerRepo: "owner/wrong-extension",
            workflows: ["README.md": "documentation"]
        )

        let result = try LocalRepoScanner().scan(codeRoot: temporaryDirectory)

        XCTAssertEqual(
            result.repositories.map(\.identity.fullName),
            ["owner/github-only", "owner/qualifying", "owner/wrong-extension"]
        )
        let qualifying = try XCTUnwrap(
            result.repositories.first(where: { $0.identity.fullName == "owner/qualifying" })
        )
        XCTAssertEqual(qualifying.workflows.map(\.fileName), ["ci.yml", "nightly.yaml"])
        XCTAssertEqual(qualifying.workflows[0].events, ["pull_request", "push"])
        XCTAssertNotNil(qualifying.localActivityAt)
        XCTAssertEqual(
            result.repositories.first(where: { $0.identity.fullName == "owner/github-only" })?.workflows,
            []
        )
        XCTAssertEqual(
            result.repositories.first(where: { $0.identity.fullName == "owner/wrong-extension" })?.workflows,
            []
        )
        XCTAssertTrue(result.skippedRepositories.isEmpty)
    }

    func testNonGitHubOriginIsRejected() throws {
        try makeRepository(at: "gitlab", origin: "git@gitlab.com:owner/repo.git")

        let result = try LocalRepoScanner().scan(codeRoot: temporaryDirectory)

        XCTAssertTrue(result.repositories.isEmpty)
        XCTAssertEqual(
            result.skippedRepositories,
            [.init(relativePath: "gitlab", reason: .nonGitHubOrigin)]
        )
        XCTAssertEqual(LocalScanSkipReason.nonGitHubOrigin.userMessage, "Origin is not hosted on GitHub")
        XCTAssertEqual(LocalScanSkipReason.noWorkflowFiles.userMessage, "No GitHub Actions workflow YAML")
        XCTAssertEqual(LocalScanSkipReason.unreadableGitMetadata.userMessage, "Git origin could not be read")
    }

    func testWorktreeGitFileResolvesCommonConfig() throws {
        let commonGit = temporaryDirectory.appendingPathComponent("metadata/common.git", isDirectory: true)
        let worktreeGit = commonGit.appendingPathComponent("worktrees/feature", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n  url = https://github.com/owner/worktree.git\n"
            .write(to: commonGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "../..\n".write(
            to: worktreeGit.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )

        let checkout = temporaryDirectory.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".github/workflows", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "gitdir: \(worktreeGit.path)\n".write(
            to: checkout.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "name: CI\non: push\n".write(
            to: checkout.appendingPathComponent(".github/workflows/ci.yml"),
            atomically: true,
            encoding: .utf8
        )

        let result = try LocalRepoScanner().scan(codeRoot: temporaryDirectory)

        XCTAssertEqual(result.repositories.map(\.identity.fullName), ["owner/worktree"])
    }

    private func makeRepository(
        at relativePath: String,
        ownerRepo: String? = nil,
        origin: String? = nil,
        workflows: [String: String] = ["ci.yml": "name: CI\non: push\n"]
    ) throws {
        let repository = temporaryDirectory.appendingPathComponent(relativePath, isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let remote = origin ?? "git@github.com:\(ownerRepo!).git"
        try "[remote \"origin\"]\n  url = \(remote)\n".write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        if !workflows.isEmpty {
            let workflowDirectory = repository.appendingPathComponent(".github/workflows", isDirectory: true)
            try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
            for (fileName, contents) in workflows {
                try contents.write(
                    to: workflowDirectory.appendingPathComponent(fileName),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }
}
