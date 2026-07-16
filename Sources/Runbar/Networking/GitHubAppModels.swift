import Foundation

enum GitHubAppConfiguration {
    static let appID = 4_307_573
    static let clientID = "Iv23li2gOIUcTMRUoDpE"
    static let slug = "runbar"
    static let installationURL = URL(string: "https://github.com/apps/\(slug)/installations/new")!
    static let managementURL = URL(string: "https://github.com/settings/installations")!
}

struct GitHubAppCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date?
    let refreshToken: String?
    let refreshTokenExpiresAt: Date?
}

struct GitHubDeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let pollingInterval: TimeInterval
}

enum GitHubAppAuthError: Error, Equatable, Sendable {
    case authorizationPending
    case slowDown
    case accessDenied
    case expired
    case invalidClient
    case deviceFlowDisabled
    case invalidResponse
    case transport
    case unexpectedStatus(Int)

    var userMessage: String {
        switch self {
        case .authorizationPending, .slowDown:
            "Waiting for GitHub authorization."
        case .accessDenied:
            "GitHub authorization was cancelled."
        case .expired:
            "The GitHub sign-in code expired. Start again."
        case .invalidClient:
            "Runbar's GitHub App client ID was rejected."
        case .deviceFlowDisabled:
            "Device flow is not enabled for the Runbar GitHub App."
        case .invalidResponse:
            "GitHub returned an invalid authorization response."
        case .transport:
            "GitHub could not be reached. Check the network connection and try again."
        case let .unexpectedStatus(status):
            "GitHub returned HTTP \(status) during authorization."
        }
    }
}

protocol GitHubAppAuthenticating: Sendable {
    func requestDeviceAuthorization() async throws -> GitHubDeviceAuthorization
    func pollForCredential(deviceCode: String) async throws -> GitHubAppCredential
    func refreshCredential(refreshToken: String) async throws -> GitHubAppCredential
}

protocol GitHubAppCredentialStoring: Sendable {
    func readCredential() throws -> GitHubAppCredential?
    func saveCredential(_ credential: GitHubAppCredential) throws
    func deleteCredential() throws
}

protocol GitHubAppSessionManaging: PollCredentialProviding {
    func saveCredential(_ credential: GitHubAppCredential) async throws
    func deleteCredential() async throws
}
