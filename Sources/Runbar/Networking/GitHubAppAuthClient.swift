import Foundation

struct GitHubAppAuthClient: GitHubAppAuthenticating {
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    private let clientID: String
    private let transport: any AuthTransport
    private let now: @Sendable () -> Date

    init(
        clientID: String,
        transport: any AuthTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.now = now
    }

    static func live() -> GitHubAppAuthClient {
        GitHubAppAuthClient(
            clientID: GitHubAppConfiguration.clientID,
            transport: URLSessionAuthTransport.live()
        )
    }

    func requestDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        let response: DeviceCodeResponse = try await post(
            url: Self.deviceCodeURL,
            form: ["client_id": clientID]
        )
        guard
            !response.deviceCode.isEmpty,
            !response.userCode.isEmpty,
            let verificationURL = URL(string: response.verificationURI),
            response.expiresIn > 0,
            response.interval > 0
        else { throw GitHubAppAuthError.invalidResponse }
        return GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: verificationURL,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            pollingInterval: TimeInterval(response.interval)
        )
    }

    func pollForCredential(deviceCode: String) async throws -> GitHubAppCredential {
        try await token(
            form: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
        )
    }

    func refreshCredential(refreshToken: String) async throws -> GitHubAppCredential {
        try await token(
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
    }

    private func token(form: [String: String]) async throws -> GitHubAppCredential {
        let response: AccessTokenResponse = try await post(url: Self.accessTokenURL, form: form)
        if let error = response.error { throw map(error) }
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw GitHubAppAuthError.invalidResponse
        }
        let currentDate = now()
        return GitHubAppCredential(
            accessToken: accessToken,
            accessTokenExpiresAt: response.expiresIn.map { currentDate.addingTimeInterval(TimeInterval($0)) },
            refreshToken: response.refreshToken,
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map {
                currentDate.addingTimeInterval(TimeInterval($0))
            }
        )
    }

    private func post<Response: Decodable>(url: URL, form: [String: String]) async throws -> Response {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                key.formURLEncoded + "=" + value.formURLEncoded
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw GitHubAppAuthError.transport
        }
        guard response.statusCode == 200 else {
            throw GitHubAppAuthError.unexpectedStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubAppAuthError.invalidResponse
        }
    }

    private func map(_ error: String) -> GitHubAppAuthError {
        switch error {
        case "authorization_pending": .authorizationPending
        case "slow_down": .slowDown
        case "access_denied": .accessDenied
        case "expired_token", "token_expired": .expired
        case "incorrect_client_credentials": .invalidClient
        case "device_flow_disabled": .deviceFlowDisabled
        default: .invalidResponse
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? self
    }
}
