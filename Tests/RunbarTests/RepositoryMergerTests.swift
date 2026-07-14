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
            RemoteRepository(identity: RepoIdentity(owner: "remote", name: "only"), pushedAt: nil)
        ]
        let preferences = [
            "owner/repo": RepositoryPreference(isExcluded: true, isAccessible: false)
        ]

        let merged = RepositoryMerger.merge(local: [local], remote: remote, preferences: preferences)

        XCTAssertEqual(merged.count, 2)
        let both = merged.first { $0.id == "owner/repo" }
        XCTAssertEqual(both?.source, .both)
        XCTAssertEqual(both?.workflows, [workflow])
        XCTAssertEqual(both?.pushedAt, pushedAt)
        XCTAssertEqual(both?.isExcluded, true)
        XCTAssertEqual(both?.isAccessible, false)
        XCTAssertEqual(merged.first { $0.id == "remote/only" }?.source, .remote)
    }
}
