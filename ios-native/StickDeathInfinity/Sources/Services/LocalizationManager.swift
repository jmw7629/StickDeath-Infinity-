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

// MARK: - Free function — no actor isolation, callable from anywhere

/// Resolves the language code from an AppLanguage value.
private func resolvedLangCode(for language: AppLanguage) -> String {
    switch language {
    case .system:
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    case .english:
        return "en"
    case .chinese:
        return "zh-Hans"
    }
}

// MARK: - Localization Manager (SwiftUI observable, MainActor)

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
        let langCode = resolvedLangCode(for: selectedLanguage)
        
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            currentBundle = bundle
        } else {
            currentBundle = .main
        }
        
        objectWillChange.send()
    }
    
    /// Get a localized string using the current language bundle
    func localized(_ key: String) -> String {
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
// Fully self-contained — no reference to LocalizationManager at all.

extension String {
    /// Returns the localized version of this string using the app's selected language.
    var loc: String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language = AppLanguage(rawValue: raw) ?? .system
        let langCode = resolvedLangCode(for: language)
        
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: self, value: nil, table: nil)
        }
        return self
    }
}
