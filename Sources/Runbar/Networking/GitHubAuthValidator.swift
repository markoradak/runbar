import Foundation

struct URLSessionAuthTransport: AuthTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthValidationError.invalidResponse
        }
        return (data, httpResponse)
    }

    static func live() -> URLSessionAuthTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSessionAuthTransport(session: URLSession(configuration: configuration))
    }
}

struct GitHubAuthValidator: AuthValidating {
    private static let defaultUserURL = URL(string: "https://api.github.com/user")!

    private let transport: any AuthTransport
    private let userURL: URL

    init(transport: any AuthTransport, userURL: URL = GitHubAuthValidator.defaultUserURL) {
        self.transport = transport
        self.userURL = userURL
    }

    static func live() -> GitHubAuthValidator {
        GitHubAuthValidator(transport: URLSessionAuthTransport.live())
    }

    func validate(token: String) async throws -> AuthenticatedUser {
        guard !token.isEmpty else {
            throw AuthValidationError.invalidToken
        }

        var request = URLRequest(
            url: userURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as AuthValidationError {
            throw error
        } catch {
            throw AuthValidationError.transport
        }

        switch response.statusCode {
        case 200:
            break
        case 401:
            throw AuthValidationError.invalidToken
        case 403:
            throw AuthValidationError.insufficientPermissions
        default:
            throw AuthValidationError.unexpectedStatus(response.statusCode)
        }

        guard
            let payload = try? JSONDecoder().decode(GitHubUserResponse.self, from: data),
            !payload.login.isEmpty
        else {
            throw AuthValidationError.invalidPayload
        }
        return AuthenticatedUser(login: payload.login)
    }
}

private struct GitHubUserResponse: Decodable {
    let login: String
}
