import Foundation

protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol GitHubRetrySleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct URLSessionGitHubTransport: GitHubTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubClientError.transport
        }
        return (data, response)
    }

    static func live() -> URLSessionGitHubTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSessionGitHubTransport(session: URLSession(configuration: configuration))
    }
}

struct TaskGitHubRetrySleeper: GitHubRetrySleeping {
    func sleep(seconds: TimeInterval) async throws {
        let milliseconds = Int64(max(0, seconds) * 1_000)
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

protocol GitHubClientStoring: Sendable {
    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse?
    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws
    func isRepositoryAccessible(_ repositoryKey: String) async throws -> Bool
    func markRepositoryInaccessible(_ repositoryKey: String) async throws -> Bool
    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws
    func clearDebugEntries() async throws
}
