import Foundation

protocol ProviderTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionProviderTransport: ProviderTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderClientError.transport
        }
        return (data, response)
    }

    static func live() -> URLSessionProviderTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSessionProviderTransport(session: URLSession(configuration: configuration))
    }
}

enum ProviderHTTP {
    static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Runbar/1", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ProviderClientError.authentication
        case 403:
            throw ProviderClientError.permissionDenied(
                "The token is valid but does not have the required read permission."
            )
        case 429:
            let retryAt = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
                .map { Date().addingTimeInterval($0) }
            throw ProviderClientError.rateLimited(retryAt: retryAt)
        default:
            throw ProviderClientError.invalidResponse
        }
    }

    static func rateLimit(from response: HTTPURLResponse) -> ProviderRateLimit {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetValue = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        let resetAt = resetValue.map { value in
            value > 10_000_000_000
                ? Date(timeIntervalSince1970: value / 1_000)
                : Date(timeIntervalSince1970: value)
        }
        return ProviderRateLimit(remaining: remaining, resetAt: resetAt)
    }
}
