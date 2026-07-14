import Foundation

protocol CredentialStore {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum CredentialStoreError: Error, Equatable, LocalizedError {
    case invalidToken
    case invalidStoredData
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The token cannot be empty."
        case .invalidStoredData:
            "The saved Keychain credential is unreadable. Remove it and save a new token."
        case let .keychainFailure(status):
            "macOS Keychain returned error \(status)."
        }
    }
}
