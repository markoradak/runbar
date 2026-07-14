import Foundation
import XCTest
@testable import Runbar

final class RepoDiscoveryIntegrationTests: XCTestCase {
    func testPersistedCodeRootAndRemoteFeedMergeWithoutManualAdditions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarDiscoveryIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".github/workflows", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "[remote \"origin\"]\n  url = git@github.com:Owner/Repo.git\n".write(
            to: repository.appendingPathComponent(".git/config"),
            atomically: true,
            encoding: .utf8
        )
        try "name: CI\non: push\n".write(
            to: repository.appendingPathComponent(".github/workflows/ci.yml"),
            atomically: true,
            encoding: .utf8
        )

        let store = MemoryRepoDiscoveryStore(codeRootPath: root.path)
        let remote = RemoteRepositoryDiscoveryStub(
            repositories: [
                RemoteRepository(identity: RepoIdentity(owner: "owner", name: "repo"), pushedAt: Date()),
                RemoteRepository(identity: RepoIdentity(owner: "remote", name: "only"), pushedAt: nil)
            ]
        )
        let discovery = RepoDiscovery(remoteDiscovery: remote, store: store)

        let snapshot = try await discovery.refresh(token: "m1-integration-marker")
        let receivedToken = await remote.receivedToken()
        let persistedSnapshot = await store.savedSnapshot()

        XCTAssertEqual(receivedToken, "m1-integration-marker")
        XCTAssertEqual(snapshot.repositories.count, 2)
        XCTAssertEqual(snapshot.repositories.first { $0.id == "owner/repo" }?.source, .both)
        XCTAssertEqual(snapshot.repositories.first { $0.id == "owner/repo" }?.workflows.count, 1)
        XCTAssertEqual(snapshot.repositories.first { $0.id == "remote/only" }?.source, .remote)
        XCTAssertEqual(persistedSnapshot, snapshot)
    }
}

private actor RemoteRepositoryDiscoveryStub: RemoteRepositoryDiscovering {
    private let repositories: [RemoteRepository]
    private var token: String?

    init(repositories: [RemoteRepository]) {
        self.repositories = repositories
    }

    func discover(token: String) async throws -> [RemoteRepository] {
        self.token = token
        return repositories
    }

    func receivedToken() -> String? { token }
}

private actor MemoryRepoDiscoveryStore: RepoDiscoveryStoring {
    private var rootPath: String?
    private var preferences: [String: RepositoryPreference] = [:]
    private var snapshot: RepoDiscoverySnapshot?

    init(codeRootPath: String?) {
        rootPath = codeRootPath
    }

    func codeRootPath() async throws -> String? { rootPath }
    func setCodeRootPath(_ path: String) async throws { rootPath = path }
    func repositoryPreferences() async throws -> [String: RepositoryPreference] { preferences }

    func setExcluded(_ isExcluded: Bool, repositoryKey: String) async throws {
        var preference = preferences[repositoryKey] ?? .defaults
        preference.isExcluded = isExcluded
        preferences[repositoryKey] = preference
    }

    func setAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {
        var preference = preferences[repositoryKey] ?? .defaults
        preference.isAccessible = isAccessible
        preferences[repositoryKey] = preference
    }

    func saveDiscoverySnapshot(_ snapshot: RepoDiscoverySnapshot) async throws {
        self.snapshot = snapshot
    }

    func savedSnapshot() -> RepoDiscoverySnapshot? { snapshot }
}
