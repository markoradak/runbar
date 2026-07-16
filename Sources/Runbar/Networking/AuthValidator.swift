import Foundation

struct AuthenticatedUser: Equatable, Sendable {
    let login: String
}

protocol AuthValidating: Sendable {
    func validate(token: String) async throws -> AuthenticatedUser
}

enum AuthValidationError: Error, Equatable, Sendable {
    case invalidToken
    case insufficientPermissions
    case unexpectedStatus(Int)
    case invalidResponse
    case invalidPayload
    case transport

    var userMessage: String {
        switch self {
        case .invalidToken:
            "GitHub rejected the saved credential. Connect the Runbar GitHub App again."
        case .insufficientPermissions:
            "GitHub denied access. The Runbar GitHub App needs read access to Actions, Metadata, and Contents."
        case let .unexpectedStatus(status):
            "GitHub returned HTTP \(status) while validating the credential."
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .invalidPayload:
            "GitHub authenticated the request but did not return a valid login."
        case .transport:
            "GitHub could not be reached. Check the network connection and try again."
        }
    }
}

protocol AuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
