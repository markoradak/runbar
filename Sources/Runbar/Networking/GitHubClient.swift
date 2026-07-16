import Foundation

actor GitHubClient {
    private static let acceptHeader = "application/vnd.github+json"
    private static let apiVersion = "2022-11-28"

    private let store: any GitHubClientStoring
    private let transport: any GitHubTransport
    private let sleeper: any GitHubRetrySleeping
    private let baseURL: URL
    private let maximumRetryCount: Int
    private let maximumBackoff: TimeInterval
    private let now: @Sendable () -> Date
    private var debugLog: [GitHubDebugEntry] = []
    private let maximumDebugEntries = 100

    init(
        store: any GitHubClientStoring,
        transport: any GitHubTransport = URLSessionGitHubTransport.live(),
        sleeper: any GitHubRetrySleeping = TaskGitHubRetrySleeper(),
        baseURL: URL = URL(string: "https://api.github.com")!,
        maximumRetryCount: Int = 2,
        maximumBackoff: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.sleeper = sleeper
        self.baseURL = baseURL
        self.maximumRetryCount = maximumRetryCount
        self.maximumBackoff = maximumBackoff
        self.now = now
    }

    /// Fire-and-forget workflow-run actions (re-run, cancel). These bypass
    /// the ETag cache entirely — they are writes, not polls.
    func performRunAction(
        _ action: GitHubRunAction,
        repository: RepoIdentity,
        runID: Int64,
        token: String
    ) async throws {
        guard !token.isEmpty else { throw GitHubClientError.authentication }
        let path = "repos/\(repository.owner)/\(repository.name)/actions/runs/\(runID)/\(action.rawValue)"
        var request = URLRequest(
            url: baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")

        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
        } catch {
            throw (error as? GitHubClientError) ?? .transport
        }
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw GitHubClientError.authentication
        default:
            throw GitHubClientError.unexpectedStatus(response.statusCode)
        }
    }

    func resetRepositoryAccess(_ repositoryKey: String) async throws {
        do {
            try await store.setRepositoryAccessible(true, repositoryKey: repositoryKey)
        } catch {
            throw GitHubClientError.persistence
        }
    }

    func get<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        endpoint: GitHubEndpoint,
        token: String,
        repositoryKey: String? = nil
    ) async throws -> GitHubResponse<Response> {
        guard !token.isEmpty else { throw GitHubClientError.authentication }
        if let repositoryKey {
            do {
                guard try await store.isRepositoryAccessible(repositoryKey) else {
                    throw GitHubClientError.accessDenied(repositoryKey: repositoryKey, firstNotice: false)
                }
            } catch let error as GitHubClientError {
                throw error
            } catch {
                throw GitHubClientError.persistence
            }
        }

        let canonicalURL = try GitHubURLCanonicalizer.canonicalURL(baseURL: baseURL, endpoint: endpoint)
        let canonicalKey = canonicalURL.absoluteString
        let sanitizedURL = GitHubURLCanonicalizer.sanitizedURL(canonicalURL)
        let cached: GitHubCachedResponse?
        do {
            cached = try await store.cachedResponse(for: canonicalKey)
        } catch {
            throw GitHubClientError.persistence
        }

        for attempt in 0...maximumRetryCount {
            var request = URLRequest(
                url: canonicalURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
            request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
            if let etag = cached?.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                let clientError = (error as? GitHubClientError) ?? .transport
                await record(
                    url: sanitizedURL,
                    statusCode: nil,
                    cacheOutcome: .none,
                    rateLimit: .init(remaining: nil, resetAt: nil),
                    error: clientError.category
                )
                throw clientError
            }

            let rateLimit = Self.rateLimit(from: response)
            switch response.statusCode {
            case 200:
                let decoded: Response
                do {
                    decoded = try JSONDecoder().decode(Response.self, from: data)
                } catch {
                    await record(
                        url: sanitizedURL,
                        statusCode: 200,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: .decoding
                    )
                    throw GitHubClientError.decoding
                }
                guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                    await record(
                        url: sanitizedURL,
                        statusCode: 200,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: .cache
                    )
                    throw GitHubClientError.missingETag
                }
                do {
                    try await store.saveCachedResponse(.init(etag: etag, body: data), for: canonicalKey)
                } catch {
                    await record(
                        url: sanitizedURL,
                        statusCode: 200,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: .cache
                    )
                    throw GitHubClientError.persistence
                }
                await record(
                    url: sanitizedURL,
                    statusCode: 200,
                    cacheOutcome: .stored200,
                    rateLimit: rateLimit,
                    error: nil
                )
                return GitHubResponse(
                    value: decoded,
                    statusCode: 200,
                    cacheOutcome: .stored200,
                    rateLimit: rateLimit
                )

            case 304:
                guard let body = cached?.body else {
                    await record(
                        url: sanitizedURL,
                        statusCode: 304,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: .cache
                    )
                    throw GitHubClientError.missingCachedBody
                }
                let decoded: Response
                do {
                    decoded = try JSONDecoder().decode(Response.self, from: body)
                } catch {
                    await record(
                        url: sanitizedURL,
                        statusCode: 304,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: .decoding
                    )
                    throw GitHubClientError.decoding
                }
                await record(
                    url: sanitizedURL,
                    statusCode: 304,
                    cacheOutcome: .revalidated304,
                    rateLimit: rateLimit,
                    error: nil
                )
                return GitHubResponse(
                    value: decoded,
                    statusCode: 304,
                    cacheOutcome: .revalidated304,
                    rateLimit: rateLimit
                )

            case 401:
                await record(
                    url: sanitizedURL,
                    statusCode: 401,
                    cacheOutcome: .none,
                    rateLimit: rateLimit,
                    error: .authentication
                )
                throw GitHubClientError.authentication

            case 403, 429:
                if rateLimit.remaining == 0 {
                    let error = GitHubClientError.primaryRateLimit(retryAt: rateLimit.resetAt)
                    await record(
                        url: sanitizedURL,
                        statusCode: response.statusCode,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: error.category
                    )
                    if attempt < maximumRetryCount {
                        try await sleeper.sleep(seconds: retryDelay(response: response, rateLimit: rateLimit, attempt: attempt))
                        continue
                    }
                    throw error
                }

                let retryAfter = Self.retryAfter(from: response)
                if response.statusCode == 429 || retryAfter != nil || Self.isSecondaryLimitBody(data) {
                    let error = GitHubClientError.secondaryRateLimit(retryAfter: retryAfter)
                    await record(
                        url: sanitizedURL,
                        statusCode: response.statusCode,
                        cacheOutcome: .none,
                        rateLimit: rateLimit,
                        error: error.category
                    )
                    if attempt < maximumRetryCount {
                        try await sleeper.sleep(seconds: retryDelay(response: response, rateLimit: rateLimit, attempt: attempt))
                        continue
                    }
                    throw error
                }

                if let repositoryKey {
                    throw await markAccessDenied(
                        repositoryKey: repositoryKey,
                        url: sanitizedURL,
                        statusCode: response.statusCode,
                        rateLimit: rateLimit
                    )
                }
                await record(
                    url: sanitizedURL,
                    statusCode: response.statusCode,
                    cacheOutcome: .none,
                    rateLimit: rateLimit,
                    error: .unexpectedStatus
                )
                throw GitHubClientError.unexpectedStatus(response.statusCode)

            case 404:
                if let repositoryKey {
                    throw await markAccessDenied(
                        repositoryKey: repositoryKey,
                        url: sanitizedURL,
                        statusCode: 404,
                        rateLimit: rateLimit
                    )
                }
                await record(
                    url: sanitizedURL,
                    statusCode: 404,
                    cacheOutcome: .none,
                    rateLimit: rateLimit,
                    error: .unexpectedStatus
                )
                throw GitHubClientError.unexpectedStatus(404)

            default:
                await record(
                    url: sanitizedURL,
                    statusCode: response.statusCode,
                    cacheOutcome: .none,
                    rateLimit: rateLimit,
                    error: .unexpectedStatus
                )
                throw GitHubClientError.unexpectedStatus(response.statusCode)
            }
        }
        throw GitHubClientError.transport
    }

    func debugEntries() -> [GitHubDebugEntry] {
        debugLog
    }

    func clearDebugEntries() async {
        debugLog.removeAll(keepingCapacity: true)
        try? await store.clearDebugEntries()
    }

    private func markAccessDenied(
        repositoryKey: String,
        url: String,
        statusCode: Int,
        rateLimit: GitHubRateLimit
    ) async -> GitHubClientError {
        let firstNotice: Bool
        do {
            firstNotice = try await store.markRepositoryInaccessible(repositoryKey)
        } catch {
            await record(
                url: url,
                statusCode: statusCode,
                cacheOutcome: .none,
                rateLimit: rateLimit,
                error: .cache
            )
            return .persistence
        }
        await record(
            url: url,
            statusCode: statusCode,
            cacheOutcome: .none,
            rateLimit: rateLimit,
            error: .accessDenied
        )
        return .accessDenied(repositoryKey: repositoryKey, firstNotice: firstNotice)
    }

    private func retryDelay(
        response: HTTPURLResponse,
        rateLimit: GitHubRateLimit,
        attempt: Int
    ) -> TimeInterval {
        let exponential = min(pow(2, Double(attempt)), maximumBackoff)
        let retryAfter = Self.retryAfter(from: response) ?? 0
        let resetDelay = max(0, rateLimit.resetAt?.timeIntervalSince(now()) ?? 0)
        return min(max(exponential, max(retryAfter, resetDelay)), maximumBackoff)
    }

    private func record(
        url: String,
        statusCode: Int?,
        cacheOutcome: GitHubCacheOutcome,
        rateLimit: GitHubRateLimit,
        error: GitHubErrorCategory?
    ) async {
        let entry = GitHubDebugEntry(
            timestamp: now(),
            sanitizedURL: url,
            statusCode: statusCode,
            cacheOutcome: cacheOutcome,
            rateLimit: rateLimit,
            errorCategory: error
        )
        debugLog.append(entry)
        if debugLog.count > maximumDebugEntries {
            debugLog.removeFirst(debugLog.count - maximumDebugEntries)
        }
        try? await store.appendDebugEntry(entry)
    }

    private static func rateLimit(from response: HTTPURLResponse) -> GitHubRateLimit {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let resetAt = response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return GitHubRateLimit(remaining: remaining, resetAt: resetAt)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    private static func isSecondaryLimitBody(_ data: Data) -> Bool {
        let body = String(decoding: data, as: UTF8.self).lowercased()
        return body.contains("secondary rate limit") || body.contains("abuse detection")
    }
}
