import Foundation
import XCTest
@testable import Runbar

final class RepositoryMergerTests: XCTestCase {
    func testCaseInsensitiveDeduplicationRetainsSourceAndPreferenceState() {
        let workflow = WorkflowMetadata(fileName: "ci.yml", name: "CI", events: ["push"])
        let local = LocalRepository(
            identity: RepoIdentity(owner: "Owner", name: "Repo"),
            localPath: "/code/repo",
            workflows: [workflow]
        )
        let pushedAt = Date(timeIntervalSince1970: 123)
        let remote = [
            RemoteRepository(identity: RepoIdentity(owner: "owner", name: "repo"), pushedAt: pushedAt),
            RemoteRepository(identity: RepoIdentity(owner: "aaa", name: "remote-only"), pushedAt: Date.distantFuture)
        ]
        let preferences = [
            "owner/repo": RepositoryPreference(isExcluded: true, isAccessible: false)
        ]

        let merged = RepositoryMerger.merge(local: [local], remote: remote, preferences: preferences)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.id), ["owner/repo", "aaa/remote-only"])
        let both = merged.first { $0.id == "owner/repo" }
        XCTAssertEqual(both?.source, .both)
        XCTAssertEqual(both?.workflows, [workflow])
        XCTAssertEqual(both?.pushedAt, pushedAt)
        XCTAssertEqual(both?.isExcluded, true)
        XCTAssertEqual(both?.isAccessible, false)
        XCTAssertEqual(merged.first { repository in repository.id == "aaa/remote-only" }?.source, .remote)
    }

    func testLocalCheckoutsSortByRecentLocalActivityAheadOfRemoteOnlyRepositories() {
        let older = LocalRepository(
            identity: RepoIdentity(owner: "owner", name: "older"),
            localPath: "/code/older",
            workflows: [],
            localActivityAt: Date(timeIntervalSince1970: 100)
        )
        let newer = LocalRepository(
            identity: RepoIdentity(owner: "owner", name: "newer"),
            localPath: "/code/newer",
            workflows: [],
            localActivityAt: Date(timeIntervalSince1970: 200)
        )
        let remote = RemoteRepository(
            identity: RepoIdentity(owner: "owner", name: "remote"),
            pushedAt: Date.distantFuture
        )

        let merged = RepositoryMerger.merge(local: [older, newer], remote: [remote], preferences: [:])

        XCTAssertEqual(merged.map(\.id), ["owner/newer", "owner/older", "owner/remote"])
    }
}
