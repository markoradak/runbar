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
                localActivityAt: item.localActivityAt,
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
                    localActivityAt: existing.localActivityAt,
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
                    localActivityAt: nil,
                    isExcluded: preference.isExcluded,
                    isAccessible: preference.isAccessible
                )
            }
        }

        return repositories.values.sorted { lhs, rhs in
            if lhs.isLocalCheckout != rhs.isLocalCheckout {
                return lhs.isLocalCheckout
            }
            let leftDate = lhs.activityAt ?? .distantPast
            let rightDate = rhs.activityAt ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.identity.normalizedKey < rhs.identity.normalizedKey
        }
    }
}
