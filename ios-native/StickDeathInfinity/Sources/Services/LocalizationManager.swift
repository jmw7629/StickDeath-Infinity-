// LocalizationManager.swift
// STICKDEATH ∞
// In-app language switcher supporting English + Simplified Chinese

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system  = "system"
    case english = "en"
    case chinese = "zh-Hans"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system:  return "System Default"
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
    
    var icon: String {
        switch self {
        case .system:  return "gear"
        case .english: return "a.circle"
        case .chinese: return "character.textbox"
        }
    }
    
    var flag: String {
        switch self {
        case .system:  return "🌐"
        case .english: return "🇺🇸"
        case .chinese: return "🇨🇳"
        }
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @AppStorage("appLanguage") var selectedLanguage: AppLanguage = .system {
        didSet { updateBundle() }
    }
    
    @Published private(set) var currentBundle: Bundle = .main
    
    private init() {
        updateBundle()
    }
    
    private func updateBundle() {
        let langCode: String
        
        switch selectedLanguage {
        case .system:
            // Use the device's preferred language, fallback to English
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") {
                langCode = "zh-Hans"
            } else {
                langCode = "en"
            }
        case .english:
            langCode = "en"
        case .chinese:
            langCode = "zh-Hans"
        }
        
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            currentBundle = bundle
        } else {
            currentBundle = .main
        }
        
        // Force SwiftUI views to update
        objectWillChange.send()
    }
    
    /// Get a localized string using the current language bundle
    func localized(_ key: String, comment: String = "") -> String {
        currentBundle.localizedString(forKey: key, value: nil, table: nil)
    }
    
    /// Get the current Locale for `.environment(\.locale, ...)`
    var currentLocale: Locale {
        switch selectedLanguage {
        case .system:  return .current
        case .english: return Locale(identifier: "en")
        case .chinese: return Locale(identifier: "zh-Hans")
        }
    }
}

// MARK: - String extension for easy localization
extension String {
    /// Returns the localized version of this string using the app's selected language
    var loc: String {
        LocalizationManager.shared.localized(self)
    }
}
