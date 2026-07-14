import Foundation

enum GitHubOriginNormalizer {
    static func normalize(_ rawOrigin: String) -> RepoIdentity? {
        let origin = rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty else { return nil }

        if origin.lowercased().hasPrefix("git@github.com:") {
            let index = origin.index(origin.startIndex, offsetBy: "git@github.com:".count)
            return identity(fromPath: String(origin[index...]))
        }

        guard let components = URLComponents(string: origin) else { return nil }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "ssh" else { return nil }
        guard components.host?.lowercased() == "github.com" else { return nil }
        guard components.port == nil, components.query == nil, components.fragment == nil else { return nil }

        if scheme == "ssh", components.user?.lowercased() != "git" {
            return nil
        }
        if scheme == "https", components.user != nil || components.password != nil {
            return nil
        }

        return identity(fromPath: components.percentEncodedPath)
    }

    private static func identity(fromPath rawPath: String) -> RepoIdentity? {
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedParts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard encodedParts.count == 2 else { return nil }
        guard
            let owner = String(encodedParts[0]).removingPercentEncoding,
            var name = String(encodedParts[1]).removingPercentEncoding
        else {
            return nil
        }

        if name.lowercased().hasSuffix(".git") {
            name.removeLast(4)
        }

        let invalid = CharacterSet(charactersIn: "/\\\0")
        guard
            !owner.isEmpty,
            !name.isEmpty,
            owner.rangeOfCharacter(from: invalid) == nil,
            name.rangeOfCharacter(from: invalid) == nil,
            owner != ".",
            owner != "..",
            name != ".",
            name != ".."
        else {
            return nil
        }

        return RepoIdentity(owner: owner, name: name)
    }
}
