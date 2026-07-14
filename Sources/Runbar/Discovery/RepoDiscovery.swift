import Foundation

actor RepoDiscovery {
    private let localScanner: LocalRepoScanner
    private let remoteDiscovery: any RemoteRepositoryDiscovering
    private let store: any RepoDiscoveryStoring

    init(
        localScanner: LocalRepoScanner = LocalRepoScanner(),
        remoteDiscovery: any RemoteRepositoryDiscovering = GitHubRemoteRepoDiscovery(),
        store: any RepoDiscoveryStoring
    ) {
        self.localScanner = localScanner
        self.remoteDiscovery = remoteDiscovery
        self.store = store
    }

    func setCodeRoot(_ url: URL) async throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { throw RepoDiscoveryError.invalidCodeRoot }
        do {
            try await store.setCodeRootPath(url.standardizedFileURL.path)
        } catch {
            throw RepoDiscoveryError.persistence(String(describing: error))
        }
    }

    func refresh(token: String?) async throws -> RepoDiscoverySnapshot {
        let rootPath: String?
        let preferences: [String: RepositoryPreference]
        do {
            rootPath = try await store.codeRootPath()
            preferences = try await store.repositoryPreferences()
        } catch {
            throw RepoDiscoveryError.persistence(String(describing: error))
        }

        let localResult: LocalScanResult
        if let rootPath {
            localResult = try localScanner.scan(codeRoot: URL(fileURLWithPath: rootPath, isDirectory: true))
        } else {
            localResult = .empty
        }

        let remoteRepositories: [RemoteRepository]
        if let token, !token.isEmpty {
            remoteRepositories = try await remoteDiscovery.discover(token: token)
        } else {
            remoteRepositories = []
        }

        let repositories = RepositoryMerger.merge(
            local: localResult.repositories,
            remote: remoteRepositories,
            preferences: preferences
        )
        let snapshot = RepoDiscoverySnapshot(
            codeRootPath: rootPath,
            repositories: repositories,
            skippedLocalRepositories: localResult.skippedRepositories
        )
        do {
            try await store.saveDiscoverySnapshot(snapshot)
        } catch {
            throw RepoDiscoveryError.persistence(String(describing: error))
        }
        return snapshot
    }

    func setExcluded(_ isExcluded: Bool, repositoryKey: String) async throws {
        do {
            try await store.setExcluded(isExcluded, repositoryKey: repositoryKey)
        } catch {
            throw RepoDiscoveryError.persistence(String(describing: error))
        }
    }

    func setAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {
        do {
            try await store.setAccessible(isAccessible, repositoryKey: repositoryKey)
        } catch {
            throw RepoDiscoveryError.persistence(String(describing: error))
        }
    }
}
