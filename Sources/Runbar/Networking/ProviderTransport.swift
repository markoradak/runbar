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

/// A decoded provider response plus the rate-limit headers that came with it.
struct ProviderHTTPResult<Value: Sendable>: Sendable {
    let value: Value
    let rateLimit: ProviderRateLimit
}

enum ProviderHTTP {
    /// The single GET path for every provider client: build the URL, send it
    /// through the shared transport, validate the status, decode, and carry the
    /// rate-limit headers back out.
    static func get<T: Decodable & Sendable>(
        baseURL: URL,
        path: String,
        query: [URLQueryItem] = [],
        token: String,
        transport: any ProviderTransport
    ) async throws -> ProviderHTTPResult<T> {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw ProviderClientError.invalidResponse }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderClientError.invalidResponse }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request(url: url, token: token)) }
        catch let error as ProviderClientError { throw error }
        catch { throw ProviderClientError.transport }
        try validate(response)
        do {
            return ProviderHTTPResult(
                value: try JSONDecoder().decode(T.self, from: data),
                rateLimit: rateLimit(from: response)
            )
        } catch {
            throw ProviderClientError.invalidResponse
        }
    }

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
