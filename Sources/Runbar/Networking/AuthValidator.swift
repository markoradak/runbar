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
            "GitHub rejected this token. Check that it is active and copied completely."
        case .insufficientPermissions:
            "GitHub denied access. The token needs Actions, Metadata, and Contents read permission, and may require organization approval."
        case let .unexpectedStatus(status):
            "GitHub returned HTTP \(status) while validating the token."
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
