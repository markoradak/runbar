import Foundation

protocol RepoDiscoveryStoring: Sendable {
    func codeRootPath() async throws -> String?
    func setCodeRootPath(_ path: String) async throws
    func repositoryPreferences() async throws -> [String: RepositoryPreference]
    func setExcluded(_ isExcluded: Bool, repositoryKey: String) async throws
    func setAccessible(_ isAccessible: Bool, repositoryKey: String) async throws
    func saveDiscoverySnapshot(_ snapshot: RepoDiscoverySnapshot) async throws
}
