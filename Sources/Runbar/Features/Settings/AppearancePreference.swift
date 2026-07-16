import AppKit

enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance to force app-wide; `nil` follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

protocol AppearancePreferenceStoring: Sendable {
    func appearancePreference() -> AppearancePreference
    func setAppearancePreference(_ preference: AppearancePreference)
}

final class UserDefaultsAppearancePreferenceStore: AppearancePreferenceStoring, @unchecked Sendable {
    private static let preferenceKey = "appearance.preference"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func appearancePreference() -> AppearancePreference {
        defaults.string(forKey: Self.preferenceKey)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    func setAppearancePreference(_ preference: AppearancePreference) {
        defaults.set(preference.rawValue, forKey: Self.preferenceKey)
    }
}
