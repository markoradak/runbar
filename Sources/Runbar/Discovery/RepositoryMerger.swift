import Foundation

enum RepositoryMerger {
    static func merge(
        local: [LocalRepository],
        remote: [RemoteRepository],
        preferences: [String: RepositoryPreference]
    ) -> [DiscoveredRepository] {
        var repositories: [String: DiscoveredRepository] = [:]

        for item in local {
            let key = item.identity.normalizedKey
            let preference = preferences[key] ?? .defaults
            repositories[key] = DiscoveredRepository(
                identity: item.identity,
                source: .local,
                localPath: item.localPath,
                pushedAt: nil,
                workflows: item.workflows,
                isExcluded: preference.isExcluded,
                isAccessible: preference.isAccessible
            )
        }

        for item in remote {
            let key = item.identity.normalizedKey
            let preference = preferences[key] ?? .defaults
            if let existing = repositories[key] {
                repositories[key] = DiscoveredRepository(
                    identity: existing.identity,
                    source: .both,
                    localPath: existing.localPath,
                    pushedAt: item.pushedAt,
                    workflows: existing.workflows,
                    isExcluded: preference.isExcluded,
                    isAccessible: preference.isAccessible
                )
            } else {
                repositories[key] = DiscoveredRepository(
                    identity: item.identity,
                    source: .remote,
                    localPath: nil,
                    pushedAt: item.pushedAt,
                    workflows: [],
                    isExcluded: preference.isExcluded,
                    isAccessible: preference.isAccessible
                )
            }
        }

        return repositories.values.sorted {
            $0.identity.normalizedKey < $1.identity.normalizedKey
        }
    }
}
